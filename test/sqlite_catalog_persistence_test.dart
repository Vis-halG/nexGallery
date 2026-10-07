import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/catalog_persistence.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory directory;
  late String path;
  late SqliteCatalogPersistence persistence;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nexgallery_sqlite_');
    path = '${directory.path}${Platform.pathSeparator}catalog.sqlite';
    persistence = SqliteCatalogPersistence(path);
  });

  tearDown(() async {
    await persistence.close();
    await directory.delete(recursive: true);
  });

  test('factory selects SQLite and fresh schema uses WAL', () async {
    final selected = createCatalogPersistence(databaseFilePath: path);
    expect(selected, isA<SqliteCatalogPersistence>());
    final empty = await selected.load();
    expect(empty.items, isEmpty);
    expect(empty.albums, isEmpty);
    final db = sqlite3.open(path);
    try {
      expect(db.userVersion, SqliteCatalogPersistence.currentSchemaVersion);
      expect(db.select('PRAGMA journal_mode').single.values.first, 'wal');
      expect(db.select('PRAGMA quick_check').single.values.first, 'ok');
    } finally {
      db.close();
      await (selected as CloseableCatalogPersistence).close();
    }
  });

  test('all metadata and ordered album membership survive reopening', () async {
    final original = _snapshot();
    await persistence.save(original);
    await persistence.close();
    final reopened = SqliteCatalogPersistence(path);
    try {
      expect((await reopened.load()).toJson(), original.toJson());
      expect(reopened.backupError, isNull);
      expect(File('$path.bak').existsSync(), isTrue);
    } finally {
      await reopened.close();
    }
  });

  test('save queue preserves order and close drains queued writes', () async {
    final first = persistence.save(_snapshot(name: 'First.jpg'));
    final second = persistence.save(_snapshot(name: 'Second.jpg'));
    final closing = persistence.close();
    await Future.wait(<Future<void>>[first, second, closing]);
    final reopened = SqliteCatalogPersistence(path);
    try {
      expect((await reopened.load()).items.first.name, 'Second.jpg');
      await expectLater(persistence.load(), throwsStateError);
    } finally {
      await reopened.close();
    }
  });

  test('SQL failure rolls the entire snapshot transaction back', () async {
    final original = _snapshot();
    await persistence.save(original);
    final db = sqlite3.open(path);
    db.execute('''
      CREATE TRIGGER reject_item BEFORE INSERT ON media_items
      WHEN new.name = 'Rejected.jpg' BEGIN
        SELECT RAISE(ABORT, 'injected write failure');
      END;
    ''');
    db.close();
    await expectLater(
      persistence.save(_snapshot(name: 'Rejected.jpg')),
      throwsA(isA<SqliteException>()),
    );
    expect((await persistence.load()).toJson(), original.toJson());
  });

  test('legacy JSON imports once and retains the source file', () async {
    final legacy = File(
      '${directory.path}${Platform.pathSeparator}catalog.json',
    );
    final original = _snapshot();
    final sourceBytes = jsonEncode(original.toJson());
    await legacy.writeAsString(sourceBytes);
    expect((await persistence.load()).toJson(), original.toJson());
    expect(await legacy.readAsString(), sourceBytes);
    await legacy.writeAsString('{corrupt after successful migration');
    expect((await persistence.load()).toJson(), original.toJson());
  });

  test(
    'interrupted first migration retries a validated legacy import',
    () async {
      final legacy = File(
        '${directory.path}${Platform.pathSeparator}catalog.json',
      );
      await legacy.writeAsString(jsonEncode(_snapshot().toJson()));
      final db = sqlite3.open(path);
      db.execute('BEGIN; CREATE TABLE partial(id TEXT); ROLLBACK;');
      db.close();
      expect((await persistence.load()).toJson(), _snapshot().toJson());
    },
  );

  test(
    'legacy writer interruption imports .json.bak when primary is missing',
    () async {
      final legacy = File(
        '${directory.path}${Platform.pathSeparator}catalog.json.bak',
      );
      await legacy.writeAsString(jsonEncode(_snapshot().toJson()));
      expect((await persistence.load()).toJson(), _snapshot().toJson());
      expect(await legacy.exists(), isTrue);
    },
  );

  test(
    'newer legacy schema is preserved and blocks subsequent saves',
    () async {
      final legacy = File(
        '${directory.path}${Platform.pathSeparator}catalog.json',
      );
      final object = _snapshot().toJson()..['schemaVersion'] = 999;
      final sourceBytes = jsonEncode(object);
      await legacy.writeAsString(sourceBytes);
      await expectLater(persistence.load(), throwsUnsupportedError);
      await expectLater(persistence.save(_snapshot()), throwsStateError);
      expect(await legacy.readAsString(), sourceBytes);
      expect(await File(path).exists(), isFalse);
    },
  );

  test('invalid legacy arrays are not silently imported as empty', () async {
    final legacy = File(
      '${directory.path}${Platform.pathSeparator}catalog.json',
    );
    await legacy.writeAsString('''
      {"schemaVersion":1,"items":["bad entry"],"albums":[]}
    ''');
    await expectLater(persistence.load(), throwsFormatException);
    expect(await File(path).exists(), isFalse);
    expect(await legacy.exists(), isTrue);
  });

  test(
    'version one migration rebuilds searchable metadata and preserves state',
    () async {
      final original = _snapshot();
      await persistence.save(original);
      final db = sqlite3.open(path);
      db.execute('''
      DROP TRIGGER media_search_insert;
      DROP TRIGGER media_search_delete;
      DROP TRIGGER media_search_update;
      DROP TABLE media_search;
      DROP INDEX media_items_section_indexed;
      DROP INDEX media_items_source_kind;
      DROP INDEX album_items_item;
    ''');
      db.userVersion = 1;
      db.close();
      expect((await persistence.load()).toJson(), original.toJson());
      final migrated = sqlite3.open(path);
      try {
        expect(
          migrated.userVersion,
          SqliteCatalogPersistence.currentSchemaVersion,
        );
        expect(_search(migrated, 'holiday'), <String>['photo']);
        expect(_search(migrated, 'Mumbai'), <String>['photo']);
      } finally {
        migrated.close();
      }
    },
  );

  test('FTS index follows snapshot replacement and deletion', () async {
    await persistence.save(_snapshot(name: 'Holiday.jpg'));
    var db = sqlite3.open(path);
    expect(_search(db, 'Holiday'), <String>['photo']);
    db.close();
    await persistence.save(_snapshot(name: 'Sunset.jpg', tags: <String>[]));
    db = sqlite3.open(path);
    expect(_search(db, 'Holiday'), isEmpty);
    expect(_search(db, 'Sunset'), <String>['photo']);
    db.close();
    await persistence.save(CatalogSnapshot.empty());
    db = sqlite3.open(path);
    expect(_search(db, 'Sunset'), isEmpty);
    db.close();
  });

  test(
    'unsupported primary schema cannot be replaced by an older backup',
    () async {
      await persistence.save(_snapshot());
      final db = sqlite3.open(path);
      db.userVersion = 999;
      db.close();
      final before = await File(path).readAsBytes();
      await expectLater(persistence.load(), throwsUnsupportedError);
      await expectLater(
        persistence.save(_snapshot(name: 'New.jpg')),
        throwsStateError,
      );
      expect(await File(path).readAsBytes(), before);
    },
  );

  test('unrecognized SQLite database is not overwritten', () async {
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES (\'keep\')',
    );
    db.close();
    final before = await File(path).readAsBytes();
    await expectLater(persistence.load(), throwsUnsupportedError);
    expect(await File(path).readAsBytes(), before);
  });

  test(
    'damaged primary recovers from backup and preserves damaged bytes',
    () async {
      final original = _snapshot();
      await persistence.save(original);
      final damaged = utf8.encode('damaged database bytes');
      await File(path).writeAsBytes(damaged, flush: true);
      expect((await persistence.load()).toJson(), original.toJson());
      final preserved = persistence.recoveredDatabasePath;
      expect(preserved, isNotNull);
      expect(await File(preserved!).readAsBytes(), damaged);
      expect(await File('$path.bak').exists(), isTrue);
    },
  );

  test(
    'damaged catalogue with no valid backup fails without replacing files',
    () async {
      final damaged = utf8.encode('damaged catalogue');
      await File(path).writeAsBytes(damaged, flush: true);
      await File('$path.bak').writeAsString('also damaged');
      await expectLater(persistence.load(), throwsFormatException);
      await expectLater(persistence.save(_snapshot()), throwsStateError);
      expect(await File(path).readAsBytes(), damaged);
      expect(await File('$path.bak').readAsString(), 'also damaged');
    },
  );

  test(
    'daily backup refresh retains previous backup and latest committed state',
    () async {
      final original = _snapshot();
      await persistence.save(original);
      await File('$path.bak')
          .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
      final updated = _snapshot(name: 'Updated.jpg');
      await persistence.save(updated);
      expect(persistence.backupError, isNull);
      final latest = sqlite3.open('$path.bak', mode: OpenMode.readOnly);
      final previous = sqlite3.open(
        '$path.bak.previous',
        mode: OpenMode.readOnly,
      );
      try {
        expect(
          latest.select('SELECT name FROM media_items WHERE id = ?', <Object?>[
            'photo',
          ]).single['name'],
          'Updated.jpg',
        );
        expect(
          previous.select(
            'SELECT name FROM media_items WHERE id = ?',
            <Object?>['photo'],
          ).single['name'],
          original.items.first.name,
        );
      } finally {
        latest.close();
        previous.close();
      }
    },
  );

  test(
    'backup failure is surfaced without losing a committed primary save',
    () async {
      await Directory('$path.bak').create();
      final original = _snapshot();
      await persistence.save(original);
      expect(persistence.backupError, isNotNull);
      expect((await persistence.load()).toJson(), original.toJson());
    },
  );
}

List<String> _search(Database db, String term) => db
    .select(
      '''
  SELECT i.id FROM media_search f JOIN media_items i ON i.rowid = f.rowid
  WHERE media_search MATCH ?
''',
      <Object?>[term],
    )
    .map((row) => row['id'] as String)
    .toList();

CatalogSnapshot _snapshot({
  String name = 'Photo.jpg',
  List<String> tags = const <String>['holiday'],
}) {
  final now = DateTime.utc(2026, 10, 2, 12, 1, 2, 3, 4);
  final photo = MediaItem(
    id: 'photo',
    name: name,
    uri: 'file:///Pictures/$name',
    relativePath: 'Pictures/$name',
    kind: MediaKind.image,
    source: MediaSource.pc,
    section: MediaSection.archive,
    isFavorite: true,
    isAvailable: false,
    indexedAt: now,
    thumbnailUri: 'file:///cache/photo.webp',
    deletedAt: now,
    metadata: MediaMetadata(
      sizeBytes: 1234,
      modifiedAt: now,
      createdAt: now,
      takenAt: now,
      duration: const Duration(milliseconds: 4321),
      width: 1920,
      height: 1080,
      mimeType: 'image/jpeg',
      extension: 'jpg',
      checksum: 'sha256:abc',
      latitude: 19.076,
      longitude: 72.8777,
      tags: tags,
      attributes: const <String, String>{'place': 'Mumbai', 'camera': 'Phone'},
    ),
  );
  final video = photo.copyWith(
    id: 'video',
    name: 'Clip.mp4',
    uri: 'file:///Pictures/Clip.mp4',
    relativePath: 'Pictures/Clip.mp4',
    kind: MediaKind.video,
    isFavorite: false,
    isAvailable: true,
    source: MediaSource.phone,
    section: MediaSection.trash,
    metadata: MediaMetadata(sizeBytes: 5678, modifiedAt: now),
  );
  return CatalogSnapshot(
    items: <MediaItem>[photo, video],
    savedAt: now,
    albums: <MediaAlbum>[
      MediaAlbum(
        id: 'family',
        name: 'Family',
        kind: AlbumKind.manual,
        createdAt: now,
        updatedAt: now,
        isReadOnly: true,
        coverItemId: 'video',
        itemIds: <String>['video', 'photo'],
      ),
    ],
  );
}
