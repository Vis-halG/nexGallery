@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/device/device_bridge.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/pairing_payload.dart';
import 'package:nex_gallery/services/remote/remote_session.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:nex_gallery/services/remote/transfer_queue.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_tools.dart';
import 'package:path/path.dart' as p;

final class _MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Only the members a remote session uses are implemented.
final class _Gallery extends ChangeNotifier
    implements GalleryModel, GalleryTools {
  _Gallery(this.cache, this.localItems);

  final Directory cache;
  @override
  final List<MediaItem> localItems;
  @override
  GallerySettings settings = const GallerySettings(cameraBackup: true);

  @override
  Future<File> materialize(MediaItem item) async =>
      File(p.join(cache.path, '${item.id}.tmp'))
          .writeAsString('bytes of ${item.name}');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaItem _photo(String id, String folder) => MediaItem(
  id: id,
  name: '$id.jpg',
  uri: 'content://media/$id',
  relativePath: folder,
  kind: MediaKind.image,
  source: MediaSource.phone,
  metadata: MediaMetadata(
    sizeBytes: 10,
    modifiedAt: DateTime.utc(2026, 10, 5),
    takenAt: DateTime.utc(2026, 10, 5),
  ),
  indexedAt: DateTime.utc(2026, 10, 5),
);

void main() {
  test('pairs from a QR link, backs up the camera and reconnects', () async {
    final workspace = await Directory.systemTemp.createTemp('nex_session_');
    final shared = await Directory(p.join(workspace.path, 'pc')).create();
    await File(p.join(shared.path, 'movie-notes.txt')).writeAsString('notes');
    final identity = await TlsIdentity.loadOrCreate(
      Directory(p.join(workspace.path, 'tls')),
    );
    final server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'shared_1': shared.path},
        dataDirectory: Directory(p.join(workspace.path, 'state')),
        port: 0,
        allowWrites: true,
        securityContext: identity.context,
        serverName: 'Study PC',
      ),
    );
    await server.start();
    final cache = await Directory(p.join(workspace.path, 'cache')).create();
    final gallery = _Gallery(cache, [
      _photo('IMG_1', 'DCIM/Camera/'),
      _photo('IMG_2', 'DCIM/Camera/'),
      _photo('SHOT_1', 'Pictures/Screenshots/'),
    ]);
    final secrets = _MemorySecrets();
    final phoneData = Directory(p.join(workspace.path, 'phone'));
    RemoteSession open() => RemoteSession(
      secrets: secrets,
      dataDirectory: phoneData,
      model: gallery,
      device: DeviceBridge(isAndroid: false),
    );
    final session = open();
    try {
      await session.initialize();
      expect(session.isConnected, isFalse);
      final link = PairingPayload(
        name: 'Study PC',
        addresses: [
          Uri.parse('https://127.0.0.2:1'), // unreachable, then the real one
          Uri.parse('https://127.0.0.1:${server.boundPort}'),
        ],
        code: server.createPairingCode().code,
        fingerprint: identity.fingerprint,
      ).encode();
      final pairing = session.pairWithLink(link, deviceName: 'Pixel 9');
      while (server.pendingPairings.isEmpty || !session.isWaitingForApproval) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await server.approvePairing(
        server.pendingPairings.single.requestId,
        scopes: DeviceScope.all,
      );
      await pairing;
      expect(session.error, isNull);
      expect(session.isConnected, isTrue);
      expect(session.info!.name, 'Study PC');
      expect(session.allows(DeviceScope.upload), isTrue);
      final saved = jsonDecode(secrets.values['remote.connection']!) as Map;
      expect(saved['keySeed'], isNotNull);
      expect(saved['tokenId'], server.devices.single.tokenId);

      // Camera backup runs on connect; screenshots are not camera items.
      for (var i = 0; i < 300; i++) {
        if (session.queue.jobs.length == 2 &&
            session.queue.jobs.every((job) => job.isFinished)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final backup = Directory(
        p.join(shared.path, cameraBackupFolder, '2026-10'),
      );
      expect(backup.listSync().map((e) => p.basename(e.path)).toSet(), {
        'IMG_1.jpg',
        'IMG_2.jpg',
      });
      expect(
        await File(p.join(backup.path, 'IMG_1.jpg')).readAsString(),
        'bytes of IMG_1.jpg',
      );
      expect(cache.listSync(), isEmpty, reason: 'temporary copies removed');
      await session.queue.clearFinished();
      expect(await session.backUpCamera(), 0, reason: 'already backed up');

      final entry = (await session.client!.list(root: 'shared_1'))
          .firstWhere((entry) => entry.name == 'movie-notes.txt');
      final job = await session.keepOffline(entry);
      for (var i = 0; i < 200 && !job.isFinished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(job.status, TransferStatus.done);
      expect((await session.offlineFiles()).single.readAsStringSync(), 'notes');
      expect(await session.offlineBytes(), 5);
      await session.clearOffline();
      expect(await session.offlineFiles(), isEmpty);
    } finally {
      await session.disconnect();
      session.dispose();
    }

    final restored = open();
    try {
      await restored.initialize();
      expect(restored.isConnected, isTrue, reason: restored.error);
      expect(restored.saved!.pcName, 'Study PC');
      await restored.disconnect(forget: true);
      expect(secrets.values, isEmpty);
      expect(server.devices, isEmpty, reason: 'the PC forgets the phone');
    } finally {
      restored.dispose();
      await server.stop(force: true);
      await workspace.delete(recursive: true);
    }
  });

  test('camera items are detected from folder or bucket', () {
    expect(RemoteSession.isCameraItem(_photo('a', 'DCIM/Camera/')), isTrue);
    expect(
      RemoteSession.isCameraItem(_photo('b', 'Pictures/Screenshots/')),
      isFalse,
    );
    final bucket = _photo('c', '').copyWith(
      metadata: _photo(
        'c',
        '',
      ).metadata.copyWith(attributes: {'bucket': 'Camera'}),
    );
    expect(RemoteSession.isCameraItem(bucket), isTrue);
    expect(
      RemoteSession.isCameraItem(
        _photo('d', 'DCIM/Camera/').copyWith(section: MediaSection.trash),
      ),
      isFalse,
    );
  });
}
