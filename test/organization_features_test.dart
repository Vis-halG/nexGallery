import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/services/files/storage_insights.dart';
import 'package:nex_gallery/services/organization/memories.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late Directory root;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_organize_');
    root = await Directory(p.join(workspace.path, 'pictures')).create();
    for (final (name, size) in [
      ('a-beach.jpg', 30),
      ('b-city.jpg', 10),
      ('c-forest.jpg', 20),
    ]) {
      await File(p.join(root.path, name)).writeAsBytes(List.filled(size, 7));
    }
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  Future<NexGalleryRuntime> open(String state) async {
    final directory = await Directory(p.join(workspace.path, state))
        .create(recursive: true);
    final preferences = GalleryPreferencesStore(directory.path);
    await preferences.save(GalleryPreferences(roots: [root.path]));
    await preferences.close();
    final runtime = NexGalleryRuntime(
      platform: TargetPlatform.windows,
      dataDirectory: directory.path,
    );
    await runtime.initialize();
    expect(runtime.loadState, GalleryLoadState.ready);
    return runtime;
  }

  MediaItem named(NexGalleryRuntime runtime, String name) =>
      runtime.localItems.firstWhere((item) => item.name == name);

  test('batch actions, album management and sorting', () async {
    final runtime = await open('state');
    try {
      final all = runtime.items;
      await runtime.setFavorites(all.take(2), true);
      expect(runtime.localItems.where((item) => item.isFavorite), hasLength(2));

      await runtime.createAlbum('Trips');
      final album = runtime.albums.single;
      await runtime.addAllToAlbum(all, album.id);
      expect(runtime.albums.single.itemIds, hasLength(3));
      await runtime.setAlbumCover(album.id, named(runtime, 'b-city.jpg'));
      expect(
        runtime.albums.single.coverItemId,
        named(runtime, 'b-city.jpg').id,
      );
      await runtime.removeFromAlbum(album.id, [named(runtime, 'b-city.jpg')]);
      expect(runtime.albums.single.itemIds, hasLength(2));
      expect(runtime.albums.single.coverItemId, isNull);
      await runtime.renameAlbum(album.id, 'Holidays');
      expect(runtime.albums.single.name, 'Holidays');

      runtime.showAlbum(album.id);
      expect(runtime.activeAlbumId, album.id);
      await runtime.deleteAlbum(album.id);
      expect(runtime.albums, isEmpty);
      expect(runtime.activeAlbumId, isNull);

      runtime.setSort(CatalogSortField.name, CatalogSortDirection.ascending);
      expect(runtime.items.map((item) => item.name), [
        'a-beach.jpg',
        'b-city.jpg',
        'c-forest.jpg',
      ]);
      runtime.setSort(CatalogSortField.size, CatalogSortDirection.descending);
      expect(runtime.items.first.name, 'a-beach.jpg');
      expect(runtime.items.last.name, 'b-city.jpg');

      await runtime.archiveAll([named(runtime, 'c-forest.jpg')]);
      expect(runtime.items, hasLength(2));
      runtime.showCollection(GalleryCollection.archive);
      expect(runtime.items.single.name, 'c-forest.jpg');
    } finally {
      runtime.dispose();
    }
  });

  test('trash many items, restore one and empty the rest', () async {
    final runtime = await open('state');
    try {
      final moved = await runtime.moveAllToTrash(runtime.items);
      expect(moved, 3);
      expect(runtime.items, isEmpty);
      expect(File(p.join(root.path, 'a-beach.jpg')).existsSync(), isFalse);

      runtime.showCollection(GalleryCollection.trash);
      expect(runtime.items, hasLength(3));
      final beach = runtime.items.firstWhere((v) => v.name == 'a-beach.jpg');
      expect(await runtime.restore(beach), isTrue);
      expect(File(p.join(root.path, 'a-beach.jpg')).existsSync(), isTrue);

      expect(await runtime.emptyTrash(), 2);
      expect(runtime.items, isEmpty);
      expect(File(p.join(root.path, 'b-city.jpg')).existsSync(), isFalse);
      final leftovers = Directory(p.join(root.path, '.nexgallery-trash'))
          .listSync()
          .whereType<File>();
      expect(leftovers, isEmpty);
    } finally {
      runtime.dispose();
    }
  });

  test('date and location corrections survive a rescan', () async {
    final runtime = await open('state');
    try {
      final item = named(runtime, 'b-city.jpg');
      final corrected = DateTime.utc(2019, 4, 3, 10, 30);
      await runtime.correctMetadata(
        item,
        takenAt: corrected,
        location: (48.8566, 2.3522),
      );
      await runtime.refresh();
      var current = named(runtime, 'b-city.jpg');
      expect(current.metadata.takenAt, corrected);
      expect(current.metadata.latitude, 48.8566);
      expect(current.metadata.longitude, 2.3522);

      await runtime.correctMetadata(current, clearLocation: true);
      await runtime.refresh();
      current = named(runtime, 'b-city.jpg');
      expect(current.metadata.latitude, isNull);
      expect(current.metadata.takenAt, corrected);
      await expectLater(
        runtime.correctMetadata(current, location: (91, 0)),
        throwsFormatException,
      );
    } finally {
      runtime.dispose();
    }
  });

  test('encrypted organization backup restores on a fresh install', () async {
    final first = await open('first');
    late final List<int> backup;
    try {
      await first.setFavorites([named(first, 'a-beach.jpg')], true);
      await first.archiveAll([named(first, 'c-forest.jpg')]);
      await first.createAlbum('Best');
      await first.addAllToAlbum([
        named(first, 'b-city.jpg'),
      ], first.albums.single.id);
      await first.correctMetadata(
        named(first, 'b-city.jpg'),
        takenAt: DateTime.utc(2001, 2, 3),
      );
      await expectLater(
        first.exportOrganization('short'),
        throwsFormatException,
      );
      backup = await first.exportOrganization('correct horse battery');
      expect(String.fromCharCodes(backup), isNot(contains('Best')));
    } finally {
      first.dispose();
    }

    final second = await open('second');
    try {
      await expectLater(
        second.importOrganization(
          Uint8List.fromList(backup),
          'wrong password!!',
        ),
        throwsFormatException,
      );
      final restored = await second.importOrganization(
        Uint8List.fromList(backup),
        'correct horse battery',
      );
      expect(restored, 3);
      expect(named(second, 'a-beach.jpg').isFavorite, isTrue);
      expect(named(second, 'c-forest.jpg').section, MediaSection.archive);
      expect(second.albums.single.name, 'Best');
      expect(second.albums.single.itemIds, [named(second, 'b-city.jpg').id]);
      expect(
        named(second, 'b-city.jpg').metadata.takenAt,
        DateTime.utc(2001, 2, 3),
      );
    } finally {
      second.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('new preferences persist and older files load defaults', () async {
    final directory = await Directory(p.join(workspace.path, 'prefs')).create();
    final store = GalleryPreferencesStore(directory.path);
    await store.save(
      GalleryPreferences(
        settings: const GallerySettings(
          analyzeOnlyWhileCharging: true,
          transfersOnWifiOnly: false,
          cameraBackup: true,
        ),
      ),
    );
    final loaded = await store.load();
    await store.close();
    expect(loaded.settings.analyzeOnlyWhileCharging, isTrue);
    expect(loaded.settings.transfersOnWifiOnly, isFalse);
    expect(loaded.settings.cameraBackup, isTrue);
    expect(
      GallerySettings.fromJson(const {'appearance': 'dark'})
          .transfersOnWifiOnly,
      isTrue,
    );
  });

  group('memories', () {
    final now = DateTime(2026, 10, 17, 12);
    MediaItem photo(
      String id,
      DateTime date, {
      bool favorite = false,
      Map<String, String> attributes = const {},
      MediaSection section = MediaSection.library,
    }) => MediaItem(
      id: id,
      name: '$id.jpg',
      uri: 'file:///$id.jpg',
      relativePath: 'Camera',
      kind: MediaKind.image,
      source: MediaSource.phone,
      isFavorite: favorite,
      section: section,
      metadata: MediaMetadata(
        sizeBytes: 1,
        modifiedAt: date.toUtc(),
        takenAt: date.toUtc(),
        attributes: attributes,
      ),
      indexedAt: now,
    );

    test('on this day, month recap, trips, people and favorites', () {
      final items = [
        for (var i = 0; i < 4; i++)
          photo('anniv$i', DateTime(2023, 10, 16, 9 + i)),
        photo(
          'anniv-trash',
          DateTime(2023, 10, 17),
          section: MediaSection.trash,
        ),
        for (var i = 0; i < 9; i++) photo('sep$i', DateTime(2026, 9, 2 + i)),
        for (var i = 0; i < 20; i++)
          photo(
            'home$i',
            DateTime(2025, 1, 1 + i),
            attributes: {'analysis.place': 'Pune, India'},
          ),
        for (var i = 0; i < 6; i++)
          photo(
            'goa$i',
            DateTime(2025, 3, 10 + i),
            attributes: {'analysis.place': 'Panaji, India'},
          ),
        for (var i = 0; i < 7; i++)
          photo(
            'asha$i',
            DateTime(2024, 6, 1 + i),
            favorite: true,
            attributes: {'analysis.people': 'Asha, Ravi'},
          ),
      ];
      final memories = buildMemories(items, now: now);
      final byId = {for (final memory in memories) memory.id: memory};

      final anniversary = byId['on-this-day-2023']!;
      expect(anniversary.title, '3 years ago');
      expect(anniversary.items, hasLength(4));
      expect(
        anniversary.items.map((v) => v.id),
        isNot(contains('anniv-trash')),
      );

      expect(byId['month-2026-9']!.title, 'September 2026');
      final trip = memories.singleWhere((m) => m.kind == MemoryKind.trip);
      expect(trip.title, 'Trip to Panaji');
      expect(trip.items, hasLength(6));
      expect(
        memories.where((m) => m.kind == MemoryKind.person).map((m) => m.title),
        containsAll(['With Asha', 'With Ravi']),
      );
      expect(byId['favorites-2024']!.items, hasLength(7));
      expect(byId['favorites-2024']!.cover.isFavorite, isTrue);
      expect(memories.first.kind, MemoryKind.onThisDay);
    });

    test('small or empty libraries produce no memories', () {
      expect(buildMemories(const [], now: now), isEmpty);
      expect(
        buildMemories([photo('one', DateTime(2025, 10, 17))], now: now),
        isEmpty,
      );
    });
  });

  test('storage insights group folders and suggest review-only cleanup', () {
    final now = DateTime.utc(2026, 10, 17);
    MediaItem file(
      String name,
      String path,
      int size, {
      MediaKind kind = MediaKind.other,
      int ageDays = 0,
    }) => MediaItem(
      id: name,
      name: name,
      uri: 'file:///$name',
      relativePath: path,
      kind: kind,
      source: MediaSource.pc,
      metadata: MediaMetadata(
        sizeBytes: size,
        modifiedAt: now.subtract(Duration(days: ageDays)),
      ),
      indexedAt: now,
    );
    final insights = analyzeStorage([
      file(
        'movie.mp4',
        'Videos/Trips/movie.mp4',
        300 << 20,
        kind: MediaKind.video,
      ),
      file(
        'setup.apk',
        'Download/',
        20 << 20,
        kind: MediaKind.apk,
        ageDays: 200,
      ),
      file('old.pdf', 'Downloads/old.pdf', 5 << 20, ageDays: 120),
      file('new.pdf', 'Download/', 5 << 20, ageDays: 2),
      file(
        'Screenshot_1.png',
        'Pictures/Screenshots/',
        1 << 20,
        kind: MediaKind.image,
        ageDays: 45,
      ),
    ], now: now);
    expect(insights.folders.first.folder, 'Videos/Trips');
    expect(insights.folders.first.bytes, 300 << 20);
    final byId = {for (final s in insights.suggestions) s.id: s};
    expect(byId['large']!.items.single.name, 'movie.mp4');
    expect(byId['old-downloads']!.items.map((v) => v.name), [
      'setup.apk',
      'old.pdf',
    ]);
    expect(byId['old-screenshots']!.items.single.name, 'Screenshot_1.png');
    expect(byId['installers']!.items.single.name, 'setup.apk');
    expect(byId['installers']!.bytes, 20 << 20);
  });
}
