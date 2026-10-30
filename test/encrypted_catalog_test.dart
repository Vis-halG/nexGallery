import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/catalog_key.dart';
import 'package:nex_gallery/data/encrypted_catalog_persistence.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';

void main() {
  late Directory directory;
  late SecretKey key;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nex_encrypted_');
    key = await AesGcm.with256bits().newSecretKey();
  });
  tearDown(() => directory.delete(recursive: true));
  MediaItem photo() => MediaItem(
    id: 'private-id',
    name: 'secret-family-name.jpg',
    uri: 'file:///D:/Private/secret-family-name.jpg',
    relativePath: 'Private',
    kind: MediaKind.image,
    source: MediaSource.pc,
    indexedAt: DateTime.utc(2026),
    metadata: MediaMetadata(sizeBytes: 123, modifiedAt: DateTime.utc(2026)),
  );

  test('migration preserves organization and all disk snapshots are authenticated ciphertext', () async {
    final repository = await MediaCatalogRepository.open(
      databaseFilePath: '${directory.path}/catalog.sqlite',
    );
    await repository.upsert(photo());
    final album = await repository.createAlbum('Private family album');
    await repository.addToAlbum(album.id, ['private-id']);
    await repository.migratePersistence(
      EncryptedCatalogPersistence('${directory.path}/catalog.enc', key),
    );
    await repository.setFavorite('private-id', true);
    await repository.dispose();
    final reopened = await MediaCatalogRepository.open(
      persistence: EncryptedCatalogPersistence(
        '${directory.path}/catalog.enc',
        key,
      ),
    );
    expect(reopened.itemById('private-id')!.isFavorite, isTrue);
    expect(reopened.albumById(album.id)!.itemIds, ['private-id']);
    await reopened.dispose();
    for (final name in ['catalog.enc', 'catalog.enc.previous']) {
      final bytes = await File('${directory.path}/$name').readAsBytes();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('secret-family-name')),
      );
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('Private family album')),
      );
    }
    // The source SQLite remains valid until its owner commits cleanup.
    expect(
      (await SqliteCatalogPersistence.readOnlySnapshot(
        '${directory.path}/catalog.sqlite',
      )).items.single.id,
      'private-id',
    );
  });

  test('wrong key and tampering fail closed and never overwrite a damaged catalogue', () async {
    final path = '${directory.path}/catalog.enc';
    final store = EncryptedCatalogPersistence(path, key);
    await store.save(
      CatalogSnapshot(
        items: [photo()],
        albums: [],
        savedAt: DateTime.utc(2026),
      ),
    );
    await store.close();
    final original = await File(path).readAsBytes();
    final wrong = EncryptedCatalogPersistence(
      path,
      await AesGcm.with256bits().newSecretKey(),
    );
    await expectLater(
      wrong.load(),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await expectLater(wrong.save(CatalogSnapshot.empty()), throwsStateError);
    await wrong.close();
    expect(await File(path).readAsBytes(), original);
    original[original.length - 5] ^= 0x80;
    await File(path).writeAsBytes(original);
    final damaged = EncryptedCatalogPersistence(path, key);
    await expectLater(
      damaged.load(),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
    await damaged.close();
  });

  test(
    'crash after rotating primary recovers the encrypted previous file',
    () async {
      final path = '${directory.path}/catalog.enc';
      final store = EncryptedCatalogPersistence(path, key);
      await store.save(
        CatalogSnapshot(
          items: [photo()],
          albums: [],
          savedAt: DateTime.utc(2026),
        ),
      );
      await store.close();
      await File(path).rename('$path.previous');
      final recovered = EncryptedCatalogPersistence(path, key);
      expect((await recovered.load()).items.single.name, photo().name);
      await recovered.close();
    },
  );

  test('lost OS key is never silently replaced', () async {
    await expectLater(
      CatalogKey.load(directory, create: false, readSecret: () async => null),
      throwsStateError,
    );
    String? wrapped;
    final first = await CatalogKey.load(
      directory,
      create: true,
      readSecret: () async => wrapped,
      writeSecret: (v) async {
        wrapped = v;
      },
    );
    final second = await CatalogKey.load(
      directory,
      create: false,
      readSecret: () async => wrapped,
    );
    expect(await first.extractBytes(), await second.extractBytes());
  });

  test('Windows runtime toggles encryption, cleans recovery files, and reopens with the protected OS key', () async {
    final root = await Directory('${directory.path}/photos').create();
    final state = await Directory('${directory.path}/state').create();
    await File('${root.path}/photo.jpg').writeAsString('original');
    final preferences = GalleryPreferencesStore(state.path);
    await preferences.save(
      GalleryPreferences(
        roots: [root.path],
        settings: const GallerySettings(autoRefresh: false),
      ),
    );
    await preferences.close();
    final runtime = NexGalleryRuntime(
      platform: TargetPlatform.windows,
      dataDirectory: state.path,
    );
    await runtime.initialize();
    final photo = runtime.items.single;
    await runtime.toggleFavorite(photo);
    await File('${state.path}/catalog.sqlite.bak.previous')
        .writeAsString('obsolete cleartext backup');
    await Future.wait([
      runtime.setCatalogueEncryption(true),
      runtime.setCatalogueEncryption(true),
    ]);
    expect(runtime.catalogueEncrypted, isTrue);
    expect(await File('${state.path}/catalog.sqlite').exists(), isFalse);
    expect(
      await File('${state.path}/catalog.sqlite.bak.previous').exists(),
      isFalse,
    );
    runtime.dispose();
    final reopened = NexGalleryRuntime(
      platform: TargetPlatform.windows,
      dataDirectory: state.path,
    );
    await reopened.initialize();
    try {
      expect(reopened.errorMessage, isNull);
      expect(reopened.items.single.isFavorite, isTrue);
      expect(reopened.catalogueEncrypted, isTrue);
      await reopened.setCatalogueEncryption(false);
      expect(await File('${state.path}/catalog.enc').exists(), isFalse);
      expect(
        (await SqliteCatalogPersistence.readOnlySnapshot(
          '${state.path}/catalog.sqlite',
        )).items.single.isFavorite,
        isTrue,
      );
      expect(await File('${root.path}/photo.jpg').readAsString(), 'original');
    } finally {
      reopened.dispose();
    }
  }, skip: !Platform.isWindows);
}
