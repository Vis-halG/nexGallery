import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import 'catalog_persistence_base.dart';

/// A transactional, versioned catalogue. Each operation owns a connection in a
/// worker isolate; native handles never outlive that operation. The repository
/// still loads a whole snapshot, so this alone is not large-library paging.
final class SqliteCatalogPersistence implements CloseableCatalogPersistence {
  SqliteCatalogPersistence(
    this.filePath, {
    String? legacyJsonFilePath,
    this.maximumLegacyBytes = 128 << 20,
  }) : legacyJsonFilePath =
           legacyJsonFilePath ??
           '${File(filePath).parent.path}${Platform.pathSeparator}catalog.json';

  static const int currentSchemaVersion = 2;

  /// A consistent read for the background agent; never migrates, recovers or
  /// writes the desktop app's database while that app owns it.
  static Future<CatalogSnapshot> readOnlySnapshot(String path) =>
      Isolate.run(() {
        final db = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          if (db.userVersion != currentSchemaVersion) {
            throw const FormatException(
              'Unsupported catalogue database version.',
            );
          }
          db.execute('BEGIN');
          final snapshot = _SqliteStore(path, '', 0)._read(db);
          db.execute('COMMIT');
          return snapshot;
        } finally {
          db.close();
        }
      });
  final String filePath;
  final String legacyJsonFilePath;
  final int maximumLegacyBytes;
  Future<void> _pending = Future<void>.value();
  bool _closed = false;
  Object? _blockedError;
  String? _recoveredDatabasePath;
  String? _backupError;

  // The last committed state. Later saves write only what changed against it;
  // the repository keeps unchanged items as the same objects.
  Map<String, MediaItem>? _savedItems;
  Map<String, MediaAlbum>? _savedAlbums;

  void _remember(CatalogSnapshot snapshot) {
    _savedItems = {for (final item in snapshot.items) item.id: item};
    _savedAlbums = {for (final album in snapshot.albums) album.id: album};
  }

  /// If recovery was needed, the original remains here for manual inspection.
  String? get recoveredDatabasePath => _recoveredDatabasePath;

  /// Backups are auxiliary: failure is surfaced without claiming that an
  /// already committed primary transaction failed.
  String? get backupError => _backupError;

  @override
  Future<CatalogSnapshot> load() => _enqueue(() async {
    final path = filePath;
    final legacy = legacyJsonFilePath;
    final limit = maximumLegacyBytes;
    try {
      final result = await _loadInWorker(path, legacy, limit);
      _recoveredDatabasePath = result.$2 ?? _recoveredDatabasePath;
      _backupError = result.$3;
      _blockedError = null;
      _remember(result.$1);
      return result.$1;
    } catch (error) {
      _blockedError = error;
      rethrow;
    }
  });

  @override
  Future<void> save(CatalogSnapshot snapshot) => _enqueue(() async {
    if (_blockedError != null) {
      throw StateError(
        'Catalogue loading failed; disk writes are blocked to preserve data. '
        '$_blockedError',
      );
    }
    final path = filePath;
    final legacy = legacyJsonFilePath;
    final limit = maximumLegacyBytes;
    _validateSnapshot(snapshot);
    final delta = _CatalogDelta.between(_savedItems, _savedAlbums, snapshot);
    var result = delta == null
        ? await _saveInWorker(path, legacy, limit, snapshot)
        : await _saveDeltaInWorker(path, legacy, limit, delta);
    // A database restored from backup no longer matches the last save.
    if (result.$3) result = await _saveInWorker(path, legacy, limit, snapshot);
    _recoveredDatabasePath = result.$1 ?? _recoveredDatabasePath;
    _backupError = result.$2;
    _remember(snapshot);
  });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(StateError('Catalogue persistence is closed.'));
    }
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _pending;
  }
}

// Keep isolate closures outside the instance-method context. Otherwise Dart
// may capture the persistence instance and its unsendable Future queue.
Future<(CatalogSnapshot, String?, String?)> _loadInWorker(
  String path,
  String legacy,
  int limit,
) => Isolate.run(() => _SqliteStore(path, legacy, limit).load());

Future<(String?, String?, bool)> _saveInWorker(
  String path,
  String legacy,
  int limit,
  CatalogSnapshot snapshot,
) => Isolate.run(() => _SqliteStore(path, legacy, limit).save(snapshot));

Future<(String?, String?, bool)> _saveDeltaInWorker(
  String path,
  String legacy,
  int limit,
  _CatalogDelta delta,
) => Isolate.run(() => _SqliteStore(path, legacy, limit).saveDelta(delta));

/// What changed since the last committed save. Only this crosses to the
/// worker isolate.
final class _CatalogDelta {
  _CatalogDelta({
    required this.items,
    required this.removedItemIds,
    required this.albums,
    required this.removedAlbumIds,
    required this.schemaVersion,
    required this.savedAt,
  });

  static _CatalogDelta? between(
    Map<String, MediaItem>? savedItems,
    Map<String, MediaAlbum>? savedAlbums,
    CatalogSnapshot snapshot,
  ) {
    if (savedItems == null || savedAlbums == null) return null;
    final items = <MediaItem>[];
    final present = <String>{};
    for (final item in snapshot.items) {
      present.add(item.id);
      if (!identical(savedItems[item.id], item)) items.add(item);
    }
    final albums = <MediaAlbum>[];
    final presentAlbums = <String>{};
    for (final album in snapshot.albums) {
      presentAlbums.add(album.id);
      if (!identical(savedAlbums[album.id], album)) albums.add(album);
    }
    return _CatalogDelta(
      items: items,
      removedItemIds: [
        for (final id in savedItems.keys)
          if (!present.contains(id)) id,
      ],
      albums: albums,
      removedAlbumIds: [
        for (final id in savedAlbums.keys)
          if (!presentAlbums.contains(id)) id,
      ],
      schemaVersion: snapshot.schemaVersion,
      savedAt: snapshot.savedAt,
    );
  }

  final List<MediaItem> items;
  final List<String> removedItemIds;
  final List<MediaAlbum> albums;
  final List<String> removedAlbumIds;
  final int schemaVersion;
  final DateTime savedAt;
}

final class _SqliteStore {
  _SqliteStore(this.path, this.legacyPath, this.maximumLegacyBytes);

  final String path;
  final String legacyPath;
  final int maximumLegacyBytes;
  String? recoveredPath;
  String? backupError;

  Future<(CatalogSnapshot, String?, String?)> load() async {
    final db = _open();
    try {
      final snapshot = _read(db);
      if (snapshot.savedAt.microsecondsSinceEpoch != 0 ||
          snapshot.items.isNotEmpty ||
          snapshot.albums.isNotEmpty) {
        await _tryBackup(db);
      }
      return (snapshot, recoveredPath, backupError);
    } finally {
      db.close();
    }
  }

  Future<(String?, String?, bool)> save(CatalogSnapshot snapshot) async {
    _validateSnapshot(snapshot);
    final db = _open();
    try {
      _transaction(db, () => _write(db, snapshot));
      await _tryBackup(db);
      return (recoveredPath, backupError, false);
    } finally {
      db.close();
    }
  }

  /// Writes only [delta]. The database was verified when it was loaded in
  /// this process, so the full integrity pass is not repeated on every save.
  /// Reports `true` when the file had to be restored and needs a full write.
  Future<(String?, String?, bool)> saveDelta(_CatalogDelta delta) async {
    // A database deleted since loading cannot take a partial write.
    if (!File(path).existsSync()) return (null, null, true);
    final db = _open(verified: true);
    try {
      if (recoveredPath != null) return (recoveredPath, backupError, true);
      _transaction(db, () => _writeDelta(db, delta));
      await _tryBackup(db);
      return (recoveredPath, backupError, false);
    } finally {
      db.close();
    }
  }

  Database _open({bool verified = false}) {
    File(path).parent.createSync(recursive: true);
    final exists = File(path).existsSync();
    var version = 0;
    if (exists && verified) {
      final probe = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        version = probe.userVersion;
      } finally {
        probe.close();
      }
      if (version == 0) {
        _recover();
        version = _inspect(path);
      }
    } else if (exists) {
      try {
        version = _inspect(path);
      } on SqliteException catch (error) {
        if (error.resultCode != 11 && error.resultCode != 26) rethrow;
        _recover();
        version = _inspect(path);
      } on FormatException {
        _recover();
        version = _inspect(path);
      }
    } else if (File('$path.bak').existsSync() ||
        File('$path.bak.previous').existsSync()) {
      _recover();
      version = _inspect(path);
    }

    // Validate legacy data before creating a file: a failed import must never
    // leave an empty database that hides the legacy data on the next launch.
    final initial = version == 0 ? _legacySnapshot() : null;
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA foreign_keys = ON');
      final mode = db.select('PRAGMA journal_mode = WAL').single.values.first;
      if (mode != 'wal') throw StateError('WAL mode is unavailable.');
      db.execute('PRAGMA synchronous = FULL');
      _migrate(db, initial);
      return db;
    } catch (_) {
      db.close();
      // An interrupted brand-new migration is recognizable as schema zero;
      // keep it for inspection instead of deleting evidence or source files.
      rethrow;
    }
  }

  int _inspect(String candidate) {
    final db = sqlite3.open(candidate, mode: OpenMode.readOnly);
    try {
      final version = db.userVersion;
      if (version > SqliteCatalogPersistence.currentSchemaVersion) {
        throw UnsupportedError('Catalogue database schema $version is newer.');
      }
      if (version == 0) {
        if (db
            .select(
              "SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
            )
            .isNotEmpty) {
          throw UnsupportedError('Unrecognized catalogue database schema.');
        }
        // SQLite rolled an interrupted first migration back before COMMIT.
        return 0;
      }
      final checks = db.select('PRAGMA quick_check');
      if (checks.length != 1 || checks.single.values.first != 'ok') {
        throw const FormatException(
          'Catalogue database integrity check failed.',
        );
      }
      _validateSnapshot(_read(db));
      if (db.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const FormatException('Catalogue foreign key check failed.');
      }
      return version;
    } finally {
      db.close();
    }
  }

  void _recover() {
    String? validBackup;
    for (final candidate in <String>['$path.bak', '$path.bak.previous']) {
      if (!File(candidate).existsSync()) continue;
      try {
        if (_inspect(candidate) == 0) continue;
        validBackup = candidate;
        break;
      } on Object {
        // A corrupt or unsupported backup is never promoted to the primary.
      }
    }
    if (validBackup == null) {
      throw const FormatException(
        'Catalogue is damaged and no valid database backup is available. '
        'Existing files were preserved.',
      );
    }
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final temporary = '$path.recovery.$suffix.tmp';
    File(validBackup).copySync(temporary);
    _flushFile(temporary);
    final damaged = File(path);
    if (damaged.existsSync()) {
      recoveredPath = '$path.corrupt.$suffix';
      damaged.renameSync(recoveredPath!);
      for (final sidecar in <String>['-wal', '-shm']) {
        final source = File('$path$sidecar');
        if (source.existsSync()) source.renameSync('$recoveredPath$sidecar');
      }
    }
    File(temporary).renameSync(path);
  }

  CatalogSnapshot? _legacySnapshot() {
    final file = File(legacyPath);
    if (!file.existsSync()) {
      // The old JSON writer rotated to .bak before installing the new file.
      final backup = File('$legacyPath.bak');
      return backup.existsSync() ? _readLegacy(backup) : null;
    }
    try {
      return _readLegacy(file);
    } on FormatException {
      final backup = File('$legacyPath.bak');
      if (!backup.existsSync()) rethrow;
      return _readLegacy(backup);
    }
  }

  CatalogSnapshot _readLegacy(File file) {
    if (file.lengthSync() > maximumLegacyBytes) {
      throw const FormatException(
        'Legacy catalogue exceeds the safe size limit.',
      );
    }
    final object = _object(jsonDecode(file.readAsStringSync()));
    final version = object['schemaVersion'];
    if (version != null && (version is! int || version < 1)) {
      throw const FormatException('Invalid legacy catalogue schema.');
    }
    if (version is int && version > CatalogSnapshot.currentSchemaVersion) {
      throw UnsupportedError('Legacy catalogue schema $version is newer.');
    }
    // fromJson is deliberately forgiving for optional old metadata. Required
    // arrays and entries are checked here to avoid silently dropping user data.
    for (final field in <String>['items', 'albums']) {
      final entries = object[field];
      if (entries is! List || entries.any((entry) => entry is! Map)) {
        throw FormatException('Invalid legacy catalogue $field.');
      }
    }
    final snapshot = CatalogSnapshot.fromJson(object);
    _validateSnapshot(snapshot);
    return snapshot;
  }

  void _migrate(Database db, CatalogSnapshot? initial) {
    final version = db.userVersion;
    if (version == SqliteCatalogPersistence.currentSchemaVersion) return;
    _transaction(db, () {
      if (version == 0) {
        db.execute(_schemaV1);
        _write(db, initial ?? CatalogSnapshot.empty());
      }
      if (version < 2) db.execute(_schemaV2);
      db.userVersion = SqliteCatalogPersistence.currentSchemaVersion;
    });
  }

  CatalogSnapshot _read(Database db) {
    final state = db.select('SELECT * FROM catalog_state WHERE singleton = 1');
    if (state.length != 1) {
      throw const FormatException('Catalogue state record is missing.');
    }
    final schema = state.single['snapshot_schema'] as int;
    if (schema > CatalogSnapshot.currentSchemaVersion) {
      throw UnsupportedError('Catalogue snapshot schema $schema is newer.');
    }
    final items = db
        .select('SELECT * FROM media_items ORDER BY rowid')
        .map((row) {
          return MediaItem(
            id: row['id'] as String,
            name: row['name'] as String,
            uri: row['uri'] as String,
            relativePath: row['relative_path'] as String,
            kind: MediaKind.values.byName(row['kind'] as String),
            source: MediaSource.values.byName(row['source'] as String),
            section: MediaSection.values.byName(row['section'] as String),
            isFavorite: row['is_favorite'] == 1,
            isAvailable: row['is_available'] == 1,
            thumbnailUri: row['thumbnail_uri'] as String?,
            indexedAt: _date(row['indexed_at'] as int),
            deletedAt: row['deleted_at'] == null
                ? null
                : _date(row['deleted_at'] as int),
            metadata: MediaMetadata.fromJson(
              _object(jsonDecode(row['metadata_json'] as String)),
            ),
          );
        })
        .toList(growable: false);
    final membership = <String, List<String>>{};
    for (final row in db.select(
      'SELECT * FROM album_items ORDER BY position',
    )) {
      membership
          .putIfAbsent(row['album_id'] as String, () => <String>[])
          .add(row['item_id'] as String);
    }
    final albums = db
        .select('SELECT * FROM albums ORDER BY rowid')
        .map((row) {
          return MediaAlbum(
            id: row['id'] as String,
            name: row['name'] as String,
            kind: AlbumKind.values.byName(row['kind'] as String),
            createdAt: _date(row['created_at'] as int),
            updatedAt: _date(row['updated_at'] as int),
            coverItemId: row['cover_item_id'] as String?,
            isReadOnly: row['is_read_only'] == 1,
            itemIds: membership[row['id']] ?? const <String>[],
          );
        })
        .toList(growable: false);
    return CatalogSnapshot(
      schemaVersion: schema,
      savedAt: _date(state.single['saved_at'] as int),
      items: items,
      albums: albums,
    );
  }

  void _write(Database db, CatalogSnapshot snapshot) {
    db.execute(
      'DELETE FROM album_items; DELETE FROM albums; DELETE FROM media_items',
    );
    final itemStatement = db.prepare(
      'INSERT INTO media_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    final albumStatement = db.prepare(
      'INSERT INTO albums VALUES (?, ?, ?, ?, ?, ?, ?)',
    );
    final membershipStatement = db.prepare(
      'INSERT INTO album_items VALUES (?, ?, ?)',
    );
    try {
      for (final item in snapshot.items) {
        itemStatement.execute(_itemRow(item));
      }
      for (final album in snapshot.albums) {
        albumStatement.execute(_albumRow(album));
        for (var position = 0; position < album.itemIds.length; position++) {
          membershipStatement.execute(<Object?>[
            album.id,
            album.itemIds[position],
            position,
          ]);
        }
      }
      _writeState(db, snapshot.schemaVersion, snapshot.savedAt);
    } finally {
      itemStatement.close();
      albumStatement.close();
      membershipStatement.close();
    }
  }

  void _writeDelta(Database db, _CatalogDelta delta) {
    // Upserts keep each row's id, so the full-text index update trigger runs.
    final upsertItem = db.prepare('''
INSERT INTO media_items VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, uri = excluded.uri,
  relative_path = excluded.relative_path, kind = excluded.kind,
  source = excluded.source, section = excluded.section,
  is_favorite = excluded.is_favorite, is_available = excluded.is_available,
  thumbnail_uri = excluded.thumbnail_uri, indexed_at = excluded.indexed_at,
  deleted_at = excluded.deleted_at, metadata_json = excluded.metadata_json,
  searchable = excluded.searchable''');
    final upsertAlbum = db.prepare('''
INSERT INTO albums VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  name = excluded.name, kind = excluded.kind,
  created_at = excluded.created_at, updated_at = excluded.updated_at,
  cover_item_id = excluded.cover_item_id,
  is_read_only = excluded.is_read_only''');
    final deleteItem = db.prepare('DELETE FROM media_items WHERE id = ?');
    final deleteAlbum = db.prepare('DELETE FROM albums WHERE id = ?');
    final clearMembers = db.prepare(
      'DELETE FROM album_items WHERE album_id = ?',
    );
    final addMember = db.prepare('INSERT INTO album_items VALUES (?, ?, ?)');
    try {
      for (final id in delta.removedAlbumIds) {
        deleteAlbum.execute(<Object?>[id]);
      }
      for (final album in delta.albums) {
        clearMembers.execute(<Object?>[album.id]);
      }
      for (final id in delta.removedItemIds) {
        deleteItem.execute(<Object?>[id]);
      }
      for (final item in delta.items) {
        upsertItem.execute(_itemRow(item));
      }
      for (final album in delta.albums) {
        upsertAlbum.execute(_albumRow(album));
        for (var position = 0; position < album.itemIds.length; position++) {
          addMember.execute(<Object?>[
            album.id,
            album.itemIds[position],
            position,
          ]);
        }
      }
      _writeState(db, delta.schemaVersion, delta.savedAt);
    } finally {
      for (final statement in [
        upsertItem,
        upsertAlbum,
        deleteItem,
        deleteAlbum,
        clearMembers,
        addMember,
      ]) {
        statement.close();
      }
    }
  }

  static List<Object?> _itemRow(MediaItem item) {
    final metadata = item.metadata;
    return <Object?>[
      item.id,
      item.name,
      item.uri,
      item.relativePath,
      item.kind.name,
      item.source.name,
      item.section.name,
      item.isFavorite ? 1 : 0,
      item.isAvailable ? 1 : 0,
      item.thumbnailUri,
      item.indexedAt.toUtc().microsecondsSinceEpoch,
      item.deletedAt?.toUtc().microsecondsSinceEpoch,
      jsonEncode(metadata.toJson()),
      <String>[
        item.name,
        item.relativePath,
        metadata.extension ?? '',
        metadata.mimeType ?? '',
        ...metadata.tags,
        ...metadata.attributes.values,
      ].join(' '),
    ];
  }

  static List<Object?> _albumRow(MediaAlbum album) => <Object?>[
    album.id,
    album.name,
    album.kind.name,
    album.createdAt.toUtc().microsecondsSinceEpoch,
    album.updatedAt.toUtc().microsecondsSinceEpoch,
    album.coverItemId,
    album.isReadOnly ? 1 : 0,
  ];

  static void _writeState(Database db, int schemaVersion, DateTime savedAt) {
    db.execute(
      'INSERT OR REPLACE INTO catalog_state VALUES (1, ?, ?)',
      <Object?>[schemaVersion, savedAt.toUtc().microsecondsSinceEpoch],
    );
  }

  Future<void> _backupIfDue(Database db) async {
    final backup = File('$path.bak');
    if (backup.existsSync()) {
      final age = DateTime.now().toUtc().difference(
        backup.lastModifiedSync().toUtc(),
      );
      if (age < const Duration(days: 1)) return;
    }
    final temporary = File(
      '$path.backup.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    // One consistent, compacted copy; page-by-page backup with a sync per
    // step took about 20 seconds for 100,000 items.
    db.execute('VACUUM INTO ?', <Object?>[temporary.path]);
    _flushFile(temporary.path);
    _inspect(temporary.path);
    final previous = File('$path.bak.previous');
    if (backup.existsSync()) {
      if (previous.existsSync()) previous.deleteSync();
      backup.renameSync(previous.path);
    }
    temporary.renameSync(backup.path);
  }

  Future<void> _tryBackup(Database db) async {
    try {
      await _backupIfDue(db);
    } catch (error) {
      backupError = error.toString();
    }
  }
}

void _transaction(Database db, void Function() operation) {
  db.execute('BEGIN IMMEDIATE');
  try {
    operation();
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _validateSnapshot(CatalogSnapshot snapshot) {
  if (snapshot.schemaVersion < 1) {
    throw const FormatException('Invalid catalogue snapshot schema.');
  }
  if (snapshot.schemaVersion > CatalogSnapshot.currentSchemaVersion) {
    throw UnsupportedError(
      'Catalogue snapshot schema ${snapshot.schemaVersion} is newer.',
    );
  }
  final itemIds = <String>{};
  for (final item in snapshot.items) {
    if (item.id.isEmpty || !itemIds.add(item.id)) {
      throw const FormatException(
        'Catalogue contains empty or duplicate item IDs.',
      );
    }
  }
  final albumIds = <String>{};
  for (final album in snapshot.albums) {
    if (album.id.isEmpty ||
        !albumIds.add(album.id) ||
        album.itemIds.toSet().length != album.itemIds.length ||
        album.itemIds.any((id) => !itemIds.contains(id)) ||
        (album.coverItemId != null &&
            !album.itemIds.contains(album.coverItemId))) {
      throw const FormatException(
        'Catalogue contains invalid album membership.',
      );
    }
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map) {
    throw const FormatException('Catalogue JSON must be an object.');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

DateTime _date(int micros) =>
    DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);

void _flushFile(String path) {
  final file = File(path).openSync(mode: FileMode.append);
  try {
    file.flushSync();
  } finally {
    file.closeSync();
  }
}

const _schemaV1 = '''
CREATE TABLE catalog_state (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  snapshot_schema INTEGER NOT NULL,
  saved_at INTEGER NOT NULL
) STRICT;
CREATE TABLE media_items (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) > 0),
  name TEXT NOT NULL,
  uri TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  kind TEXT NOT NULL,
  source TEXT NOT NULL,
  section TEXT NOT NULL,
  is_favorite INTEGER NOT NULL CHECK(is_favorite IN (0, 1)),
  is_available INTEGER NOT NULL CHECK(is_available IN (0, 1)),
  thumbnail_uri TEXT,
  indexed_at INTEGER NOT NULL,
  deleted_at INTEGER,
  metadata_json TEXT NOT NULL CHECK(json_valid(metadata_json)),
  searchable TEXT NOT NULL
) STRICT;
CREATE TABLE albums (
  id TEXT PRIMARY KEY NOT NULL CHECK(length(id) > 0),
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  cover_item_id TEXT,
  is_read_only INTEGER NOT NULL CHECK(is_read_only IN (0, 1))
) STRICT;
CREATE TABLE album_items (
  album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  PRIMARY KEY(album_id, item_id),
  UNIQUE(album_id, position)
) STRICT;
''';

const _schemaV2 = '''
CREATE INDEX media_items_section_indexed ON media_items(section, indexed_at DESC);
CREATE INDEX media_items_source_kind ON media_items(source, kind);
CREATE INDEX album_items_item ON album_items(item_id);
CREATE VIRTUAL TABLE media_search USING fts5(
  searchable, content='media_items', content_rowid='rowid', tokenize='unicode61'
);
CREATE TRIGGER media_search_insert AFTER INSERT ON media_items BEGIN
  INSERT INTO media_search(rowid, searchable) VALUES (new.rowid, new.searchable);
END;
CREATE TRIGGER media_search_delete AFTER DELETE ON media_items BEGIN
  INSERT INTO media_search(media_search, rowid, searchable)
    VALUES('delete', old.rowid, old.searchable);
END;
CREATE TRIGGER media_search_update AFTER UPDATE ON media_items BEGIN
  INSERT INTO media_search(media_search, rowid, searchable)
    VALUES('delete', old.rowid, old.searchable);
  INSERT INTO media_search(rowid, searchable) VALUES (new.rowid, new.searchable);
END;
INSERT INTO media_search(media_search) VALUES('rebuild');
''';
