import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/encrypted_offline_store.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';

void main() {
  late Directory directory, shared, cache;
  late SecretKey key;
  late EncryptedOfflineStore store;
  late NexGalleryServer server;
  late NexGalleryRemoteClient client;
  late RemoteEntry entry;
  late Uint8List bytes;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nex_offline_crypto_');
    shared = await Directory('${directory.path}/shared').create();
    cache = await Directory('${directory.path}/cache').create();
    final pattern = utf8.encode(
      'secret offline media content, never store me as plaintext.',
    );
    bytes = Uint8List.fromList(
      List.generate((3 << 20) + 123, (i) => pattern[i % pattern.length]),
    );
    await File('${shared.path}/private-family.mp4').writeAsBytes(bytes);
    key = await AesGcm.with256bits().newSecretKey();
    store = EncryptedOfflineStore(cache, () async => key);
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'pc': shared.path},
        dataDirectory: Directory('${directory.path}/state'),
        port: 0,
        discoveryPort: 0,
        requireApproval: false,
      ),
    );
    await server.start();
    client = NexGalleryRemoteClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
    );
    await client.pair(
      code: server.createPairingCode().code,
      deviceName: 'offline test',
    );
    entry = (await client.list(root: 'pc')).single;
  });
  tearDown(() async {
    client.close();
    await server.stop(force: true);
    await directory.delete(recursive: true);
  });

  test('partial ciphertext resumes after a torn frame and exports exactly the original bytes', () async {
    final target = File('${cache.path}/anonymous.nexoffline');
    await expectLater(
      store.download(client, entry, target, (done, total) {
        if (done >= 1 << 20 && done < total!) throw const _Pause();
      }),
      throwsA(isA<_Pause>()),
    );
    expect(await target.exists(), isFalse);
    final part = File('${target.path}.part');
    final encrypted = await part.readAsBytes();
    expect(
      utf8.decode(encrypted, allowMalformed: true),
      isNot(contains('secret offline media content')),
    );
    expect(
      utf8.decode(encrypted, allowMalformed: true),
      isNot(contains('private-family')),
    );
    await part.writeAsBytes([0, 1, 2], mode: FileMode.append);
    await store.download(client, entry, target, (_, _) {});
    expect(await part.exists(), isFalse);
    final entries = await store.files();
    expect(entries.single.name, 'private-family.mp4');
    final exported = await store.materialize(
      entries.single,
      Directory('${directory.path}/view'),
    );
    expect(await exported.readAsBytes(), bytes);
  });

  test(
    'tampered chunks and wrong OS keys never produce a usable plaintext file',
    () async {
      final target = File('${cache.path}/anonymous.nexoffline');
      await store.download(client, entry, target, (_, _) {});
      final media = (await store.files()).single;
      final wrong = EncryptedOfflineStore(
        cache,
        () => AesGcm.with256bits().newSecretKey(),
      );
      await expectLater(
        wrong.materialize(media, Directory('${directory.path}/wrong')),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      final ciphertext = await target.readAsBytes();
      ciphertext[ciphertext.length - 1] ^= 1;
      await target.writeAsBytes(ciphertext);
      await expectLater(
        store.materialize(media, Directory('${directory.path}/tampered')),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
      expect(
        await File('${directory.path}/tampered/private-family.mp4').exists(),
        isFalse,
      );
      expect(
        await File('${directory.path}/tampered/private-family.mp4.part')
            .exists(),
        isFalse,
      );
    },
  );

  test('legacy plaintext offline files are migrated without losing their name or contents', () async {
    await File('${cache.path}/old-copy.mp4').writeAsBytes(bytes);
    final entries = await store.files();
    expect(entries.single.name, 'old-copy.mp4');
    expect(await File('${cache.path}/old-copy.mp4').exists(), isFalse);
    expect(entries.single.file.path, endsWith('.nexoffline'));
    final exported = await store.materialize(
      entries.single,
      Directory('${directory.path}/view'),
    );
    expect(await exported.readAsBytes(), bytes);
  });

  test(
    'a PC file changed during an interrupted encrypted download is refused',
    () async {
      final target = File('${cache.path}/anonymous.nexoffline');
      await expectLater(
        store.download(client, entry, target, (done, total) {
          if (done >= 1 << 20 && done < total!) throw const _Pause();
        }),
        throwsA(isA<_Pause>()),
      );
      await File('${shared.path}/private-family.mp4')
          .writeAsString('new version');
      await expectLater(
        store.download(client, entry, target, (_, _) {}),
        throwsA(
          isA<RemoteApiException>().having((v) => v.statusCode, 'status', 412),
        ),
      );
      expect(await target.exists(), isFalse);
    },
  );
}

class _Pause implements Exception {
  const _Pause();
}
