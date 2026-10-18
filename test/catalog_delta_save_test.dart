import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';
import 'package:sqlite3/sqlite3.dart';

MediaItem _item(String id, String name, {int size = 1}) => MediaItem(
  id: id,
  name: name,
  uri: 'file:///D:/Photos/$name',
  relativePath: name,
  kind: MediaKind.image,
  source: MediaSource.pc,
  metadata: MediaMetadata(
    sizeBytes: size,
    modifiedAt: DateTime.utc(2026, 1, 1),
    tags: const ['trip'],
  ),
  indexedAt: DateTime.now().toUtc(),
);

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nex_delta_save_');
    path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
  });
  tearDown(() => directory.delete(recursive: true));

  Future<MediaCatalogRepository> open() =>
      MediaCatalogRepository.open(persistence: SqliteCatalogPersistence(path));

  List<String> search(String text) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return db
          .select(
            'SELECT media_items.id FROM media_search JOIN media_items '
            'ON media_items.rowid = media_search.rowid '
            'WHERE media_search MATCH ? ORDER BY media_items.id',
            [text],
          )
          .map((row) => row['id'] as String)
          .toList();
    } finally {
      db.close();
    }
  }

  test('only-changed saves reopen exactly as the app last saw them', () async {
    var repository = await open();
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg'),
      _item('b', 'City.jpg'),
      _item('c', 'Forest.jpg'),
    ]);
    await repository.setFavorite('a', true);
    final family = await repository.createAlbum('Family');
    final trip = await repository.createAlbum('Trip');
    await repository.addToAlbum(family.id, ['a', 'b', 'c']);
    await repository.addToAlbum(trip.id, ['c']);
    await repository.setAlbumCover(family.id, 'b');
    // City.jpg is renamed in place, Forest.jpg disappears.
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg'),
      _item('b', 'Skyline.jpg', size: 2),
    ]);
    await repository.deleteAlbum(trip.id);
    await repository.moveToTrash('a');
    final expected = repository.snapshot;
    await repository.dispose();

    repository = await open();
    addTearDown(repository.dispose);
    final reopened = repository.snapshot;
    expect(
      [for (final item in reopened.items) item.toJson()],
      [for (final item in expected.items) item.toJson()],
    );
    expect(
      [for (final album in reopened.albums) album.toJson()],
      [for (final album in expected.albums) album.toJson()],
    );
    expect(reopened.albums.single.itemIds, ['a', 'b']);
    expect(reopened.albums.single.coverItemId, 'b');
    expect(search('Skyline'), ['b']);
    expect(search('City'), isEmpty);
    expect(search('Forest'), isEmpty);
    expect(search('trip'), ['a', 'b']);
  });

  test('a rescan of unchanged files keeps the same objects', () async {
    final repository = await open();
    addTearDown(repository.dispose);
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg'),
    ]);
    final before = repository.itemById('a')!;
    // A new scan reports a new indexing time for the same file.
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg'),
    ]);
    expect(identical(repository.itemById('a'), before), isTrue);
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg', size: 9),
    ]);
    final changed = repository.itemById('a')!;
    expect(changed.metadata.sizeBytes, 9);
    expect(changed.indexedAt, before.indexedAt, reason: 'first indexed time');
  });

  test('a database deleted while open is rewritten in full', () async {
    final repository = await open();
    addTearDown(repository.dispose);
    await repository.synchronizeSource(MediaSource.pc, [
      _item('a', 'Beach.jpg'),
      _item('b', 'City.jpg'),
    ]);
    for (final suffix in ['', '-wal', '-shm', '.bak', '.bak.previous']) {
      final file = File('$path$suffix');
      if (file.existsSync()) file.deleteSync();
    }
    await repository.setFavorite('b', true);
    final reopened = await SqliteCatalogPersistence(path).load();
    expect(reopened.items.map((item) => item.id), ['a', 'b']);
    expect(reopened.items.last.isFavorite, isTrue);
  });
}
