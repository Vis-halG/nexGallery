import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'upload persists progress and resumes with the same server part',
    () async {
      final directory = await Directory.systemTemp.createTemp('nex_resume_');
      final root = await Directory(p.join(directory.path, 'shared')).create();
      final server = await NexGalleryServer.create(
        RemoteServerConfig(
          allowedRoots: {'media': root.path},
          dataDirectory: Directory(p.join(directory.path, 'state')),
          port: 0,
          allowWrites: true,
          requireApproval: false,
        ),
      );
      await server.start();
      final client = NexGalleryRemoteClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
      );
      try {
        await client.pair(
          code: server.createPairingCode().code,
          deviceName: 'Test phone',
        );
        final source = await File(p.join(directory.path, 'source'))
            .writeAsString('abcdefghij');
        final state = File(p.join(directory.path, 'resume.json'));
        await expectLater(
          client.upload(
            root: 'media',
            remotePath: 'uploaded.txt',
            source: source,
            resumeState: state,
            chunkBytes: 3,
            onProgress: (done, _) {
              if (done == 3) throw StateError('Simulated interruption');
            },
          ),
          throwsStateError,
        );
        expect(await state.exists(), isTrue);
        expect(await File(p.join(root.path, 'uploaded.txt')).exists(), isFalse);
        expect(
          (await root.list().toList())
              .where((v) => v.path.endsWith('.part'))
              .length,
          1,
        );
        final progress = <int>[];
        await client.upload(
          root: 'media',
          remotePath: 'uploaded.txt',
          source: source,
          resumeState: state,
          chunkBytes: 3,
          onProgress: (done, _) => progress.add(done),
        );
        expect(progress.first, 6);
        expect(
          await File(p.join(root.path, 'uploaded.txt')).readAsString(),
          'abcdefghij',
        );
        expect(await state.exists(), isFalse);
        expect(
          (await root.list().toList()).where((v) => v.path.endsWith('.part')),
          isEmpty,
        );
      } finally {
        client.close();
        await server.stop();
        await directory.delete(recursive: true);
      }
    },
  );
  test('HTTPS identity persists, pinned client pairs, wrong pin fails and default rejects writes', () async {
    final directory = await Directory.systemTemp.createTemp('nex_tls_');
    final root = await Directory(p.join(directory.path, 'shared')).create();
    await File(p.join(root.path, 'hello.txt')).writeAsString('hello');
    final identity = await TlsIdentity.loadOrCreate(
      Directory(p.join(directory.path, 'tls')),
    );
    expect(
      (await TlsIdentity.loadOrCreate(Directory(p.join(directory.path, 'tls'))))
          .fingerprint,
      identity.fingerprint,
    );
    final server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'media': root.path},
        dataDirectory: Directory(p.join(directory.path, 'state')),
        port: 0,
        securityContext: identity.context,
      ),
    );
    await server.start();
    final uri = Uri.parse('https://127.0.0.1:${server.boundPort}');
    final client = NexGalleryRemoteClient(
      baseUri: uri,
      certificateFingerprint: identity.fingerprint,
    );
    final wrong = NexGalleryRemoteClient(
      baseUri: uri,
      certificateFingerprint: List.filled(64, '0').join(),
    );
    try {
      await client.health();
      expect(client.allowWrites, isFalse);
      await _pairWithApproval(server, client, DeviceScope.all);
      expect((await client.list(root: 'media')).single.name, 'hello.txt');
      await expectLater(
        client.createFolder(root: 'media', path: 'new-folder'),
        throwsA(
          isA<RemoteApiException>().having((v) => v.code, 'code', 'read_only'),
        ),
      );
      await expectLater(wrong.health(), throwsA(isA<HandshakeException>()));
      expect(
        () => NexGalleryRemoteClient(
          baseUri: Uri.parse('http://127.0.0.1'),
          certificateFingerprint: identity.fingerprint,
        ),
        throwsFormatException,
      );
    } finally {
      client.close();
      wrong.close();
      await server.stop();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// Pairs like a phone while the test approves the request like the PC owner.
Future<void> _pairWithApproval(
  NexGalleryServer server,
  NexGalleryRemoteClient client,
  Set<String> scopes,
) async {
  final pairing = client.pair(
    code: server.createPairingCode().code,
    deviceName: 'Test phone',
    pollInterval: const Duration(milliseconds: 50),
  );
  while (server.pendingPairings.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await server.approvePairing(
    server.pendingPairings.single.requestId,
    scopes: scopes,
  );
  await pairing;
}
