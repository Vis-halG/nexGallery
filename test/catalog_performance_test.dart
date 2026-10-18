@Tags(['performance'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';

/// The 100,000-item release budget. Limits are several times the times
/// measured on a development PC (first sync 4.8 s, unchanged rescan 1 s,
/// one favorite 0.09 s, first page 0.06 s, search 0.1 s, reopen 2.5 s) so
/// slower CI machines pass while a return to full rewrites fails.
void main() {
  test('a 100,000-item library stays responsive', () async {
    final directory = await Directory.systemTemp.createTemp('nex_perf_');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
    final items = [
      for (var i = 0; i < 100000; i++)
        MediaItem(
          id: 'pc_$i',
          name: 'IMG_$i.jpg',
          uri: 'file:///D:/Photos/${i ~/ 500}/IMG_$i.jpg',
          relativePath: '${i ~/ 500}/IMG_$i.jpg',
          kind: MediaKind.image,
          source: MediaSource.pc,
          metadata: MediaMetadata(
            sizeBytes: 1000 + i,
            modifiedAt: DateTime.utc(2020).add(Duration(minutes: i)),
            attributes: {'rootPath': r'D:\Photos', 'fileIdentity': 'f_$i'},
          ),
          indexedAt: DateTime.utc(2026),
        ),
    ];
    final timings = <String, Duration>{};
    Future<T> time<T>(String label, Future<T> Function() work) async {
      final watch = Stopwatch()..start();
      final result = await work();
      timings[label] = watch.elapsed;
      return result;
    }

    var repository = await MediaCatalogRepository.open(
      persistence: SqliteCatalogPersistence(path),
    );
    await time(
      'first sync',
      () => repository.synchronizeSource(MediaSource.pc, items),
    );
    await time(
      'unchanged rescan',
      () => repository.synchronizeSource(MediaSource.pc, items),
    );
    await time('one favorite', () => repository.setFavorite('pc_500', true));
    final album = await repository.createAlbum('Big');
    await time(
      'add 10,000 to an album',
      () => repository.addToAlbum(album.id, [
        for (var i = 0; i < 10000; i++) 'pc_$i',
      ]),
    );
    final page = await time(
      'first page',
      () async => repository.query(CatalogQuery(limit: 120)),
    );
    final hits = await time(
      'search',
      () async =>
          repository.query(CatalogQuery(searchText: 'IMG_99999', limit: 120)),
    );
    await repository.dispose();
    repository = await time(
      'reopen',
      () => MediaCatalogRepository.open(
        persistence: SqliteCatalogPersistence(path),
      ),
    );
    addTearDown(repository.dispose);

    // ignore: avoid_print
    print({
      for (final entry in timings.entries)
        entry.key: '${entry.value.inMilliseconds} ms',
    });
    expect(page.items, hasLength(120));
    expect(page.totalCount, 100000);
    expect(hits.items.single.id, 'pc_99999');
    expect(repository.itemById('pc_500')!.isFavorite, isTrue);
    expect(repository.albums().items.single.itemIds, hasLength(10000));

    const budgets = <String, Duration>{
      'first sync': Duration(seconds: 40),
      'unchanged rescan': Duration(seconds: 8),
      'one favorite': Duration(seconds: 2),
      'add 10,000 to an album': Duration(seconds: 5),
      'first page': Duration(seconds: 1),
      'search': Duration(seconds: 2),
      'reopen': Duration(seconds: 20),
    };
    for (final entry in budgets.entries) {
      expect(
        timings[entry.key]! <= entry.value,
        isTrue,
        reason: '${entry.key} took ${timings[entry.key]}',
      );
    }
  });
}
