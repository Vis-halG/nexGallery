import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import '../../data/device/device_bridge.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';
import 'lan_tools.dart';
import 'nex_gallery_client.dart';
import 'pairing_payload.dart';
import 'request_signing.dart';
import 'security.dart';
import 'sha256.dart';
import 'tailscale.dart';
import 'transfer_queue.dart';
import 'encrypted_offline_store.dart';
import 'backup_source.dart';
import '../../core/gallery_settings.dart';
export 'encrypted_offline_store.dart' show OfflineMedia;

/// Keystore-backed storage for the pairing secret.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class SavedConnection {
  const SavedConnection({
    required this.address,
    required this.fingerprint,
    required this.token,
    this.tokenId,
    this.keySeed,
    this.pcName,
    this.macAddresses = const [],
  });

  factory SavedConnection.fromJson(Map<String, dynamic> json) =>
      SavedConnection(
        address: json['address'] as String,
        fingerprint: json['fingerprint'] as String,
        token: json['token'] as String,
        tokenId: json['tokenId'] as String?,
        keySeed: json['keySeed'] as String?,
        pcName: json['pcName'] as String?,
        macAddresses: (json['macAddresses'] as List? ?? const [])
            .whereType<String>()
            .toList(),
      );

  final String address;
  final String fingerprint;
  final String token;
  final String? tokenId;
  final String? keySeed;
  final String? pcName;
  final List<String> macAddresses;

  Map<String, Object?> toJson() => {
    'address': address,
    'fingerprint': fingerprint,
    'token': token,
    'tokenId': ?tokenId,
    'keySeed': ?keySeed,
    'pcName': ?pcName,
    'macAddresses': macAddresses,
  };
}

const _secretKey = 'remote.connection';
const cameraBackupFolder = 'nexGallery Camera Backup';

/// The phone's connection to its paired PC: pairing, transfers, camera
/// backup and offline copies.
final class RemoteSession extends ChangeNotifier {
  RemoteSession({
    required this.secrets,
    required this.dataDirectory,
    this.model,
    this.backupSource,
    this.background = false,
    DeviceBridge? device,
  }) : _device = device ?? DeviceBridge.instance {
    queue = TransferQueue(
      Directory(p.join(dataDirectory.path, 'transfers')),
      networkGate: _networkGate,
      resolveSource: _materialize,
      onFinished: _finished,
      allowedJob: (job) =>
          !background ||
          (job.origin?.startsWith('camera:') == true
              ? _settings.backgroundBackup && _settings.cameraBackup
              : _settings.backgroundTransfers),
      download: (client, entry, destination, progress) =>
          _offline.download(client, entry, destination, progress),
    );
    model?.addListener(_modelChanged);
  }

  final SecretStore secrets;
  final Directory dataDirectory;
  final GalleryModel? model;
  final BackupSource? backupSource;
  final bool background;
  final _owner = 'session-$pid-${DateTime.now().microsecondsSinceEpoch}';
  bool _ownsSession = false, _disposed = false, _notifierDisposed = false;
  Future<void>? _closing;
  Future<void>? _deactivating;
  Future<int>? _backingUp;
  Future<void> _backupSaving = Future.value();
  Completer<void>? _operationDone;
  int _epoch = 0;
  bool get ownsSession => _ownsSession;
  GallerySettings get _settings =>
      backupSource?.settings ?? model?.settings ?? const GallerySettings();
  List<MediaItem>? get _sourceItems =>
      backupSource?.items ?? _tools?.localItems;
  final DeviceBridge _device;
  late final TransferQueue queue;
  late final _offline = EncryptedOfflineStore(downloads, _offlineKey);
  Future<SecretKey>? _offlineKeyFuture;
  Future<SecretKey> _offlineKey() => _offlineKeyFuture ??= _loadOfflineKey();

  Future<SecretKey> _loadOfflineKey() async {
    await dataDirectory.create(recursive: true);
    final lock = await File(p.join(dataDirectory.path, 'offline-key.lock'))
        .open(mode: FileMode.append);
    await lock.lock(FileLock.blockingExclusive);
    try {
      final existing = await secrets.read('remote.offline.aes256.v1');
      if (existing != null) {
        final bytes = base64Decode(existing);
        if (bytes.length != 32) {
          throw const FormatException('Invalid offline encryption key.');
        }
        return SecretKey(bytes);
      }
      if (await downloads.exists() &&
          await downloads
              .list(recursive: true)
              .any((v) => v.path.contains('.nexoffline'))) {
        throw StateError(
          'The OS offline key is unavailable. Cached copies cannot be opened.',
        );
      }
      final key = await AesGcm.with256bits().newSecretKey();
      await secrets.write(
        'remote.offline.aes256.v1',
        base64Encode(await key.extractBytes()),
      );
      return key;
    } finally {
      await lock.unlock();
      await lock.close();
    }
  }

  NexGalleryRemoteClient? _client;
  RemoteInfo? _info;
  SavedConnection? _saved;
  PairingTicket? _ticket;
  bool _busy = false;
  bool _cancelPairing = false;
  String? _error;
  String? _connection;
  Set<String> _backedUp = <String>{};

  NexGalleryRemoteClient? get client => _client;
  RemoteInfo? get info => _info;
  SavedConnection? get saved => _saved;
  bool get isConnected => _client != null;
  bool get isBusy => _busy;
  bool get isWaitingForApproval => _ticket != null;
  String? get error => _error;

  /// For example "via Tailscale" or "on Wi-Fi".
  String? get connectionLabel => _connection;
  bool get canWake => _saved?.macAddresses.isNotEmpty == true;

  /// Whether the PC owner allows [scope]; changes also need the PC-wide
  /// write switch.
  bool allows(String scope) {
    final info = _info;
    if (info == null || !info.allows(scope)) return false;
    return DeviceScope.readOnly.contains(scope) || info.allowWrites;
  }

  Directory get downloads => Directory(p.join(dataDirectory.path, 'downloads'));
  File get _backupState =>
      File(p.join(dataDirectory.path, 'camera-backup.json'));

  Future<void> initialize() async {
    await _deactivating;
    if (_disposed) return;
    if (!_ownsSession) {
      for (var attempt = 0; attempt < (background ? 1 : 60); attempt++) {
        if (await _device.claimTransferSession(_owner)) {
          _ownsSession = true;
          break;
        }
        if (background || _disposed) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    if (!_ownsSession) {
      _error = 'Background transfers are finishing. Try reconnecting shortly.';
      notifyListeners();
      return;
    }
    await dataDirectory.create(recursive: true);
    await _pruneOfflineViews();
    try {
      await _offline.migrateLegacy();
    } catch (error) {
      _error = 'Could not secure offline copies: $error';
      notifyListeners();
      return;
    }
    try {
      await queue.load();
    } on FormatException {
      _error = 'The transfer journal could not be read. Existing files were preserved.';
      notifyListeners();
      return;
    }
    try {
      final previous = File('${_backupState.path}.previous');
      if (!await _backupState.exists() && await previous.exists()) {
        await previous.rename(_backupState.path);
      }
      if (await _backupState.exists()) {
        _backedUp = {
          ...(jsonDecode(await _backupState.readAsString()) as List)
              .whereType<String>(),
        };
      }
    } on FormatException {
      _backedUp = <String>{};
    }
    final stored = await secrets.read(_secretKey);
    if (stored == null) {
      notifyListeners();
      return;
    }
    try {
      _saved = SavedConnection.fromJson(
        jsonDecode(stored) as Map<String, dynamic>,
      );
    } on Object {
      await secrets.delete(_secretKey);
    }
    notifyListeners();
    if (_saved != null) await reconnect();
  }

  void _modelChanged() {
    if (!_disposed && _ownsSession && isConnected && !background) {
      unawaited(backUpCamera().catchError((Object _) => 0));
    }
  }

  Future<void> deactivate() {
    if (_deactivating case final running?) return running;
    final result = _deactivate();
    _deactivating = result;
    return result.whenComplete(() => _deactivating = null);
  }

  Future<void> _deactivate() async {
    final held = _ownsSession;
    _ownsSession = false;
    _epoch++;
    _cancelPairing = true;
    queue.beginHandoff();
    _client?.close();
    _client = null;
    _info = null;
    try {
      await _operationDone?.future;
      try {
        await _backingUp;
      } catch (_) {}
      await queue.flush();
      await _backupSaving;
    } finally {
      if (held) {
        await _device.releaseTransferSession(_owner);
      }
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<T?> _run<T>(Future<T> Function() action) async {
    if (_busy || _disposed) return null;
    _operationDone = Completer<void>();
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      return await action();
    } on RemoteApiException catch (error) {
      _error = error.message;
    } on SocketException {
      _error = canWake
          ? 'The PC is not reachable. It may be asleep; try Wake PC.'
          : 'The PC is not reachable. Check that it is on and connected.';
    } on TimeoutException {
      _error = 'The PC did not respond in time.';
    } on HandshakeException {
      _error =
          'The PC certificate does not match. Pair again with the QR code.';
    } on FormatException catch (error) {
      _error = error.message;
    } finally {
      _busy = false;
      _operationDone?.complete();
      _operationDone = null;
      notifyListeners();
    }
    return null;
  }

  Future<void> reconnect() async {
    if (!_ownsSession) {
      await initialize();
      return;
    }
    await _reconnectOwned();
  }

  Future<void> _reconnectOwned() => _run(() async {
    final saved = _saved;
    if (saved == null) return;
    final client = NexGalleryRemoteClient(
      baseUri: Uri.parse(saved.address),
      token: saved.token,
      certificateFingerprint: saved.fingerprint,
      deviceKey: saved.keySeed == null
          ? null
          : await DeviceKey.fromSeed(saved.keySeed!),
      tokenId: saved.tokenId,
    );
    try {
      await client.health();
      await _attach(client);
    } catch (_) {
      client.close();
      rethrow;
    }
  });

  /// Pairs from a scanned QR code, trying each PC address in turn.
  Future<void> pairWithLink(String link, {required String deviceName}) async {
    final PairingPayload payload;
    try {
      payload = PairingPayload.parse(link);
    } on FormatException catch (error) {
      _error = error.message;
      notifyListeners();
      return;
    }
    await _run(() async {
      Object? lastError;
      for (final address in payload.addresses) {
        try {
          await _pair(address, payload.fingerprint, payload.code, deviceName);
          return;
        } on SocketException catch (error) {
          lastError = error;
        } on TimeoutException catch (error) {
          lastError = error;
        }
      }
      throw lastError ?? const SocketException('No PC address answered.');
    });
  }

  Future<void> pairManually({
    required String address,
    required String fingerprint,
    required String code,
    required String deviceName,
  }) => _run(() async {
    final uri = Uri.parse(address.trim());
    if (uri.scheme != 'https' || fingerprint.trim().isEmpty) {
      throw const FormatException(
        'Use the HTTPS address and fingerprint shown on your PC.',
      );
    }
    await _pair(uri, fingerprint.trim(), code.trim(), deviceName.trim());
  });

  Future<void> _pair(
    Uri address,
    String fingerprint,
    String code,
    String deviceName,
  ) async {
    if (!_ownsSession) {
      throw const FormatException(
        'Wait for background transfers to finish before pairing.',
      );
    }
    final client = NexGalleryRemoteClient(
      baseUri: address,
      certificateFingerprint: fingerprint,
    );
    _cancelPairing = false;
    try {
      await client.health().timeout(const Duration(seconds: 8));
      final ticket = await client.startPairing(
        code: code,
        deviceName: deviceName.isEmpty ? 'Phone' : deviceName,
      );
      if (ticket != null) {
        _ticket = ticket;
        notifyListeners();
        while (!await client.checkPairing(ticket)) {
          if (_cancelPairing) {
            throw const RemoteApiException(
              499,
              'cancelled',
              'Pairing cancelled.',
            );
          }
          if (DateTime.now().isAfter(ticket.expiresAt)) {
            throw const RemoteApiException(
              408,
              'pairing_expired',
              'The PC owner did not approve in time. Pair again.',
            );
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
      if (_cancelPairing || !_ownsSession) {
        throw const FormatException('Pairing cancelled.');
      }
      final saved = SavedConnection(
        address: client.baseUri.toString(),
        fingerprint: client.certificateFingerprint!,
        token: client.token!,
        tokenId: client.tokenId,
        keySeed: await client.deviceKey?.seed(),
      );
      await secrets.write(_secretKey, jsonEncode(saved.toJson()));
      _saved = saved;
      await _attach(client);
    } catch (_) {
      client.close();
      rethrow;
    } finally {
      _ticket = null;
    }
  }

  void cancelPairing() => _cancelPairing = true;

  Future<void> _attach(NexGalleryRemoteClient client) async {
    final epoch = _epoch;
    final info = await client.info();
    if (!_ownsSession || epoch != _epoch || _disposed) {
      client.close();
      return;
    }
    _client?.close();
    _client = client;
    _info = info;
    _uploadRoot = null;
    client.allowWrites = info.allowWrites;
    final saved = _saved;
    if (saved != null &&
        (saved.pcName != info.name ||
            !listEquals(saved.macAddresses, info.macAddresses))) {
      _saved = SavedConnection(
        address: saved.address,
        fingerprint: saved.fingerprint,
        token: saved.token,
        tokenId: saved.tokenId,
        keySeed: saved.keySeed,
        pcName: info.name,
        macAddresses: info.macAddresses,
      );
      await secrets.write(_secretKey, jsonEncode(_saved!.toJson()));
    }
    await _updateConnectionLabel();
    if (!_ownsSession || epoch != _epoch || _disposed) {
      client.close();
      return;
    }
    queue.client = client;
    notifyListeners();
    unawaited(backUpCamera());
  }

  Future<void> _updateConnectionLabel() async {
    final host = _client?.baseUri.host ?? '';
    try {
      final network = await _device.network();
      _connection = isTailnetAddress(host)
          ? 'via Tailscale'
          : network.wifi
          ? 'on Wi-Fi'
          : network.cellular
          ? 'on mobile data'
          : null;
    } on Object {
      _connection = null;
    }
  }

  Future<void> disconnect({bool forget = false}) async {
    queue.client = null;
    _client?.close();
    _client = null;
    _info = null;
    if (forget) {
      try {
        // Ask the PC to forget this phone; ignore failures when offline.
        await NexGalleryRemoteClient(
          baseUri: Uri.parse(_saved!.address),
          token: _saved!.token,
          certificateFingerprint: _saved!.fingerprint,
          deviceKey: _saved!.keySeed == null
              ? null
              : await DeviceKey.fromSeed(_saved!.keySeed!),
          tokenId: _saved!.tokenId,
        ).revokeSelf().timeout(const Duration(seconds: 5));
      } on Object {
        // The owner can still remove the phone on the PC.
      }
      await secrets.delete(_secretKey);
      _saved = null;
    }
    notifyListeners();
  }

  /// Sends a Wake-on-LAN packet for the paired PC, then tries to reconnect.
  Future<void> wake() => _run(() async {
    final macs = _saved?.macAddresses ?? const <String>[];
    for (final mac in macs) {
      await wakeOnLan(mac);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  });

  /// The smaller copy to stream for [entry] on this network, or null for the
  /// original: Wi-Fi, an unsupported PC or the "Original" setting.
  Future<int?> streamQualityFor(RemoteEntry entry) async {
    final quality = _settings.mobileVideoQuality;
    if (quality == 0 || _info?.videoProxy != true) return null;
    final network = await _device.network();
    return network.cellular || network.metered ? quality : null;
  }

  Future<String?> _networkGate() async {
    if (!_settings.transfersOnWifiOnly) return null;
    final network = await _device.network();
    if (!network.connected) return 'Waiting for a network connection.';
    if (network.cellular || network.metered) {
      return 'Waiting for Wi-Fi. Change this in Settings to use mobile data.';
    }
    return null;
  }

  GalleryTools? get _tools =>
      model is GalleryTools ? model as GalleryTools : null;

  Future<File> _materialize(TransferJob job) async {
    if (backupSource case final source?) {
      final item = source.items
          .where((v) => v.id == job.sourceItemId)
          .firstOrNull;
      if (item == null) {
        throw const FileSystemException(
          'The selected media is no longer available.',
        );
      }
      return source.materialize(item);
    }
    final tools = _tools;
    if (tools == null) {
      throw const FileSystemException('Gallery is unavailable.');
    }
    final item = tools.localItems.where((item) => item.id == job.sourceItemId);
    if (item.isEmpty) {
      throw const FileSystemException('The photo is no longer in the gallery.');
    }
    return tools.materialize(item.first);
  }

  void _finished(TransferJob job) {
    final origin = job.origin;
    if (origin == null || !origin.startsWith('camera:')) return;
    _backedUp.add(origin.substring('camera:'.length));
    unawaited(
      _saveBackupState()
          .then((_) async {
            if (queue.jobs.length > 600) await queue.pruneFinished();
            if (!_disposed && _ownsSession && !background) await backUpCamera();
          })
          .catchError((Object _) {
            _error = 'Camera backup history could not be saved.';
            notifyListeners();
          }),
    );
  }

  Future<void> _saveBackupState() {
    final result = _backupSaving
        .catchError((Object _) {})
        .then((_) => _writeBackupState());
    _backupSaving = result;
    return result;
  }

  Future<void> _writeBackupState() async {
    final temporary = File('${_backupState.path}.tmp');
    await temporary.writeAsString(jsonEncode(_backedUp.toList()), flush: true);
    final previous = File('${_backupState.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await _backupState.exists()) await _backupState.rename(previous.path);
    try {
      await temporary.rename(_backupState.path);
    } catch (_) {
      if (!await _backupState.exists() && await previous.exists()) {
        await previous.rename(_backupState.path);
      }
      rethrow;
    }
  }

  static bool isCameraItem(MediaItem item) {
    if (item.source != MediaSource.phone ||
        item.section != MediaSection.library ||
        (item.kind != MediaKind.image && item.kind != MediaKind.video)) {
      return false;
    }
    final path = item.relativePath.toLowerCase();
    return path.contains('dcim/camera') ||
        item.metadata.attributes['bucket']?.toLowerCase() == 'camera';
  }

  static String backupSignature(MediaItem item) =>
      '${item.id}:${item.metadata.sizeBytes}:'
      '${item.metadata.modifiedAt.toUtc().microsecondsSinceEpoch}';

  /// Shared folder used for uploads and camera backup: the first folder the
  /// phone may use.
  String? get uploadRoot => _uploadRoot;
  String? _uploadRoot;

  Future<void> _ensureRoot() async {
    final client = _client;
    if (client == null || _uploadRoot != null) return;
    final roots = await client.roots();
    _uploadRoot = roots.isEmpty ? null : roots.first.id;
  }

  /// Queues camera photos and videos that were not backed up yet. They are
  /// copied from the gallery only when their upload starts.
  Future<int> backUpCamera({int limit = 200}) {
    if (_backingUp case final running?) return running;
    final result = _backUpCamera(limit);
    _backingUp = result;
    return result.whenComplete(() => _backingUp = null);
  }

  Future<int> _backUpCamera(int limit) async {
    final items = _sourceItems;
    if (items == null ||
        (background && !_settings.backgroundBackup) ||
        !_settings.cameraBackup ||
        !isConnected ||
        !(_info?.allowWrites ?? false) ||
        !(_info?.allows(DeviceScope.upload) ?? false)) {
      return 0;
    }
    await _ensureRoot();
    final root = _uploadRoot;
    if (root == null) return 0;
    var added = 0;
    final capacity =
        (200 - queue.jobs.where((v) => !v.isFinished && queue.canRun(v)).length)
            .clamp(0, limit);
    for (final item in items.where(isCameraItem)) {
      if (added >= capacity || !_ownsSession || !_settings.cameraBackup) break;
      final signature = backupSignature(item);
      if (_backedUp.contains(signature) ||
          queue.hasJobFor('camera:$signature')) {
        continue;
      }
      final date = (item.metadata.takenAt ?? item.metadata.modifiedAt)
          .toLocal();
      final month = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      await queue.enqueueUpload(
        name: item.name,
        root: root,
        remotePath: '$cameraBackupFolder/$month/${item.name}',
        sourceItemId: item.id,
        policy: ConflictPolicy.keepBoth,
        origin: 'camera:$signature',
      );
      added++;
    }
    return added;
  }

  /// Queues gallery items to upload into [folder] on the PC.
  Future<int> sendToPc(
    Iterable<MediaItem> items, {
    String folder = 'From phone',
  }) async {
    await _ensureRoot();
    final root = _uploadRoot;
    if (root == null) throw StateError('Connect to your PC first.');
    var added = 0;
    for (final item in items) {
      await queue.enqueueUpload(
        name: item.name,
        root: root,
        remotePath: '$folder/${item.name}',
        sourceItemId: item.id,
        policy: ConflictPolicy.keepBoth,
      );
      added++;
    }
    return added;
  }

  Future<TransferJob> uploadFile(
    File file,
    String name, {
    required String root,
    required String folder,
  }) => queue.enqueueUpload(
    name: name,
    root: root,
    remotePath: folder.isEmpty ? name : '$folder/$name',
    source: file,
    moveSource: true,
  );

  /// Where an offline copy of [entry] is kept.
  File offlineFile(RemoteEntry entry) {
    final id = sha256Hex(
      utf8.encode(
        '${_saved?.address}:${entry.root}:${entry.path}:${entry.version ?? entry.modifiedAt}:${entry.size}',
      ),
    ).substring(0, 24);
    return File(p.join(downloads.path, '$id.nexoffline'));
  }

  Future<TransferJob> keepOffline(RemoteEntry entry) =>
      queue.enqueueDownload(entry: entry, destination: offlineFile(entry));

  Future<List<OfflineMedia>> offlineFiles() => _offline.files();

  Directory get _offlineViews => Directory(
    p.join(
      Directory.systemTemp.path,
      'nexgallery-offline-view',
      sha256Hex(utf8.encode(dataDirectory.absolute.path)).substring(0, 24),
    ),
  );

  Future<void> _pruneOfflineViews() async {
    final directory = _offlineViews;
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 30));
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is Directory &&
          (await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete(recursive: true);
      }
    }
  }

  Future<File> materializeOffline(OfflineMedia media) => _offline.materialize(
    media,
    Directory(
      p.join(_offlineViews.path, p.basenameWithoutExtension(media.file.path)),
    ),
  );

  Future<int> offlineBytes() async {
    var total = 0;
    for (final file in await offlineFiles()) {
      total += await file.file.length();
    }
    return total;
  }

  Future<void> clearOffline() async {
    if (queue.jobs.any(
      (v) => v.kind == TransferKind.download && !v.isFinished,
    )) {
      throw StateError(
        'Cancel unfinished downloads before clearing offline copies.',
      );
    }
    if (await downloads.exists()) await downloads.delete(recursive: true);
    if (await _offlineViews.exists()) {
      await _offlineViews.delete(recursive: true);
    }
    await secrets.delete('remote.offline.aes256.v1');
    _offlineKeyFuture = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    _disposed = true;
    model?.removeListener(_modelChanged);
    super.dispose();
    unawaited(close().catchError((Object _) {}));
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _disposed = true;
    model?.removeListener(_modelChanged);
    try {
      await deactivate();
    } finally {
      queue.dispose();
      if (!_notifierDisposed) dispose();
    }
  }
}
