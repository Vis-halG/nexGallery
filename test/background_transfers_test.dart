import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/device/device_bridge.dart';
import 'package:nex_gallery/services/remote/backup_source.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/remote_session.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:nex_gallery/services/remote/transfer_queue.dart';

class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Lease extends DeviceBridge {
  String? owner;
  @override
  Future<bool> claimTransferSession(String value) async {
    if (owner != null && owner != value) return false;
    owner = value;
    return true;
  }

  @override
  Future<void> releaseTransferSession(String value) async {
    if (owner == value) owner = null;
  }
}

class _Source implements BackupSource {
  _Source(this.settings, this.original, this.cache);
  @override
  final GallerySettings settings;
  final File original;
  final Directory cache;
  @override
  List<MediaItem> get items => [
    MediaItem(
      id: 'camera-photo',
      name: 'camera.jpg',
      uri: original.uri.toString(),
      relativePath: 'DCIM/Camera/',
      kind: MediaKind.image,
      source: MediaSource.phone,
      indexedAt: DateTime.utc(2026),
      metadata: MediaMetadata(
        sizeBytes: original.lengthSync(),
        modifiedAt: DateTime.utc(2026, 10, 29),
      ),
    ),
  ];
  @override
  Future<File> materialize(MediaItem item) async {
    await cache.create(recursive: true);
    return original.copy('${cache.path}/upload.tmp');
  }
}

void main() {
  late Directory directory, shared;
  late NexGalleryServer server;
  late _Secrets secrets;
  late _Lease lease;
  final sessions = <RemoteSession>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'nex_background_handoff_',
    );
    shared = await Directory('${directory.path}/pc').create();
    final identity = await TlsIdentity.loadOrCreate(
      Directory('${directory.path}/tls'),
    );
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'pc': shared.path},
        dataDirectory: Directory('${directory.path}/state'),
        port: 0,
        discoveryPort: 0,
        allowWrites: true,
        requireApproval: false,
        securityContext: identity.context,
      ),
    );
    await server.start();
    final client = NexGalleryRemoteClient(
      baseUri: Uri.parse('https://127.0.0.1:${server.boundPort}'),
      certificateFingerprint: identity.fingerprint,
    );
    await client.pair(
      code: server.createPairingCode().code,
      deviceName: 'background fixture',
    );
    secrets = _Secrets();
    lease = _Lease();
    await secrets.write(
      'remote.connection',
      jsonEncode(
        SavedConnection(
          address: client.baseUri.toString(),
          fingerprint: identity.fingerprint,
          token: client.token!,
          tokenId: client.tokenId,
          keySeed: await client.deviceKey!.seed(),
        ).toJson(),
      ),
    );
    client.close();
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    await server.stop(force: true);
    await directory.delete(recursive: true);
  });
  RemoteSession open({BackupSource? source, bool background = false}) {
    final session = RemoteSession(
      secrets: secrets,
      dataDirectory: Directory('${directory.path}/phone'),
      device: lease,
      backupSource: source,
      background: background,
    );
    sessions.add(session);
    return session;
  }

  Future<void> settle(RemoteSession session) async {
    for (var i = 0; i < 400; i++) {
      if (!session.queue.isBusy &&
          session.queue.jobs.isNotEmpty &&
          session.queue.jobs.every((v) => v.isFinished)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail(
      'Background transfer did not complete: ${session.error}, ${session.queue.waitingReason}',
    );
  }

  test('background cannot touch the foreground journal until ownership is handed over, and foreground reloads completed work', () async {
    final original = await File('${directory.path}/camera.jpg')
        .writeAsString('owner camera media');
    final source = _Source(
      const GallerySettings(cameraBackup: true, backgroundBackup: true),
      original,
      Directory('${directory.path}/cache'),
    );
    final foreground = open();
    await foreground.initialize();
    final background = open(source: source, background: true);
    await background.initialize();
    expect(background.ownsSession, isFalse);
    expect(shared.listSync(), isEmpty);
    await foreground.deactivate();
    await background.initialize();
    expect(background.ownsSession, isTrue);
    await settle(background);
    expect(
      await File('${shared.path}/$cameraBackupFolder/2026-10/camera.jpg')
          .readAsString(),
      'owner camera media',
    );
    expect(await original.readAsString(), 'owner camera media');
    await background.deactivate();
    await foreground.initialize();
    expect(foreground.ownsSession, isTrue);
    expect(foreground.queue.jobs.single.status, TransferStatus.done);
  });

  test('background camera opt-in leaves ordinary transfers queued', () async {
    final original = await File('${directory.path}/camera.jpg')
        .writeAsString('camera backup');
    final source = _Source(
      const GallerySettings(cameraBackup: true, backgroundBackup: true),
      original,
      Directory('${directory.path}/cache'),
    );
    final background = open(source: source, background: true);
    await background.initialize();
    await settle(background);
    final file = await File('${directory.path}/manual.txt')
        .writeAsString('manual');
    final job = await background.queue.enqueueUpload(
      name: 'manual.txt',
      root: 'pc',
      remotePath: 'manual.txt',
      source: file,
    );
    await background.queue.flush();
    expect(job.status, TransferStatus.queued);
    expect(await File('${shared.path}/manual.txt').exists(), isFalse);
    expect(background.queue.canRun(job), isFalse);
  });

  test('background transfers do not enable background camera backup without its separate opt-in', () async {
    final original = await File('${directory.path}/camera.jpg')
        .writeAsString('not authorized for automatic background backup');
    final source = _Source(
      const GallerySettings(
        cameraBackup: true,
        backgroundTransfers: true,
        backgroundBackup: false,
      ),
      original,
      Directory('${directory.path}/cache'),
    );
    final background = open(source: source, background: true);
    await background.initialize();
    expect(await background.backUpCamera(), 0);
    final file = await File('${directory.path}/selected.txt')
        .writeAsString('explicit transfer');
    await background.queue.enqueueUpload(
      name: 'selected.txt',
      root: 'pc',
      remotePath: 'selected.txt',
      source: file,
    );
    await settle(background);
    expect(
      await File('${shared.path}/selected.txt').readAsString(),
      'explicit transfer',
    );
    expect(
      await Directory('${shared.path}/$cameraBackupFolder').exists(),
      isFalse,
    );
  });
}
