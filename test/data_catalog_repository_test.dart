import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/catalog_persistence.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';

void main() {
  group('MediaCatalogRepository', () {
    test('filters, sorts and pages local items', () async {
      final repository = await MediaCatalogRepository.open(
        persistence: InMemoryCatalogPersistence(),
      );
      addTearDown(repository.dispose);
      await repository.upsertAll(<MediaItem>[
        _item('1', 'Beach.jpg', MediaKind.image, 300),
        _item('2', 'Notes.pdf', MediaKind.document, 200),
        _item('3', 'Song.mp3', MediaKind.audio, 100),
      ]);

      final images = repository.query(
        CatalogQuery(
          kinds: const <MediaKind>[MediaKind.image],
          searchText: 'beach jpg',
        ),
      );
      expect(images.totalCount, 1);
      expect(images.items.single.id, '1');

      final firstPage = repository.query(
        CatalogQuery(
          sortField: CatalogSortField.size,
          sortDirection: CatalogSortDirection.ascending,
          limit: 2,
        ),
      );
      expect(firstPage.items.map((item) => item.id), <String>['3', '2']);
      expect(firstPage.hasNext, isTrue);
      expect(firstPage.nextOffset, 2);
    });

    test('persists favorite, trash and album state', () async {
      final persistence = InMemoryCatalogPersistence();
      final repository = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      await repository.upsert(_item('photo', 'Family.jpg', MediaKind.image, 5));
      await repository.setFavorite('photo', true);
      final album = await repository.createAlbum('Family');
      await repository.addToAlbum(album.id, const <String>['photo']);
      await repository.moveToTrash('photo');
      await repository.dispose();

      final reopened = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      addTearDown(reopened.dispose);
      final item = reopened.itemById('photo');
      expect(item?.isFavorite, isTrue);
      expect(item?.section, MediaSection.trash);
      expect(item?.deletedAt, isNotNull);
      expect(reopened.albumById(album.id)?.itemIds, <String>['photo']);
      expect(
        reopened.query(CatalogQuery(section: MediaSection.trash)).totalCount,
        1,
      );
    });

    test('preserves user state when a scanner refreshes metadata', () async {
      final repository = await MediaCatalogRepository.open(
        persistence: InMemoryCatalogPersistence(),
      );
      addTearDown(repository.dispose);
      await repository.upsert(_item('same', 'Old.jpg', MediaKind.image, 1));
      await repository.setFavorite('same', true);
      await repository.moveToArchive('same');

      await repository.upsert(_item('same', 'New.jpg', MediaKind.image, 99));

      final refreshed = repository.itemById('same');
      expect(refreshed?.name, 'New.jpg');
      expect(refreshed?.metadata.sizeBytes, 99);
      expect(refreshed?.isFavorite, isTrue);
      expect(refreshed?.section, MediaSection.archive);
    });

    test(
      'only complete snapshots remove stale items and album membership',
      () async {
        final repository = await MediaCatalogRepository.open(
          persistence: InMemoryCatalogPersistence(),
        );
        addTearDown(repository.dispose);
        final first = _item('first', 'First.jpg', MediaKind.image, 1);
        final missing = _item('missing', 'Missing.jpg', MediaKind.image, 2);
        await repository.upsertAll(<MediaItem>[first, missing]);
        await repository.setFavorite(missing.id, true);
        final album = await repository.createAlbum('Family');
        await repository.addToAlbum(album.id, <String>[missing.id]);

        await repository.synchronizeSource(MediaSource.phone, <MediaItem>[
          first,
        ], removeMissing: false);
        expect(repository.itemCount, 2);
        expect(repository.itemById(missing.id)?.isFavorite, isTrue);
        expect(repository.albumById(album.id)?.itemIds, <String>[missing.id]);

        await repository.synchronizeSource(MediaSource.phone, <MediaItem>[
          first,
        ]);
        expect(repository.itemCount, 1);
        expect(repository.itemById(missing.id), isNull);
        expect(repository.albumById(album.id)?.itemIds, isEmpty);
      },
    );

    test(
      'availability is persistent and older catalogues default to available',
      () {
        final original = _item('id', 'Photo.jpg', MediaKind.image, 1);
        final unavailable = original.copyWith(isAvailable: false);
        expect(MediaItem.fromJson(unavailable.toJson()).isAvailable, isFalse);
        final legacy = original.toJson()..remove('isAvailable');
        expect(MediaItem.fromJson(legacy).isAvailable, isTrue);
      },
    );
  });

  test('media models round-trip optional metadata through JSON', () {
    final original = _item('id', 'clip.mp4', MediaKind.video, 42).copyWith(
      metadata: MediaMetadata(
        sizeBytes: 42,
        modifiedAt: DateTime.utc(2026, 1, 2),
        createdAt: DateTime.utc(2025, 1, 2),
        duration: const Duration(seconds: 4),
        width: 1920,
        height: 1080,
        tags: const <String>['holiday'],
        attributes: const <String, String>{'camera': 'phone'},
      ),
    );

    final decoded = MediaItem.fromJson(original.toJson());
    expect(decoded.metadata.duration, const Duration(seconds: 4));
    expect(decoded.metadata.width, 1920);
    expect(decoded.metadata.tags, <String>['holiday']);
    expect(decoded.metadata.attributes['camera'], 'phone');
  });
}

MediaItem _item(String id, String name, MediaKind kind, int sizeBytes) =>
    MediaItem(
      id: id,
      name: name,
      uri: 'file:///$name',
      relativePath: name,
      kind: kind,
      source: MediaSource.phone,
      metadata: MediaMetadata(
        sizeBytes: sizeBytes,
        modifiedAt: DateTime.utc(2026, 1, 1),
        extension: name.split('.').last.toLowerCase(),
      ),
      indexedAt: DateTime.utc(2026, 1, 1),
    );
