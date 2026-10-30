import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../core/catalog_models.dart';
import '../../data/catalog_key.dart';
import '../../data/encrypted_catalog_persistence.dart';
import '../../data/local_media_scanner.dart';
import '../../data/sqlite_catalog_persistence.dart';

/// Reads the same catalogue as the desktop app without mutating its database.
/// A folder-only installation can still serve a timeline before its first scan.
final class RemoteCatalogSource {
  RemoteCatalogSource(this.directory, this.roots);
  final Directory directory;
  final Iterable<String> roots;

  Future<CatalogSnapshot> load() async {
    CatalogSnapshot snapshot;
    final encrypted = File('${directory.path}/catalog.enc');
    if (await encrypted.exists() ||
        await File('${encrypted.path}.previous').exists()) {
      final store = EncryptedCatalogPersistence(
        encrypted.path,
        await CatalogKey.load(directory, create: false),
      );
      try {
        snapshot = await store.load();
      } finally {
        await store.close();
      }
    } else {
      final database = File('${directory.path}/catalog.sqlite');
      snapshot = await database.exists()
          ? await SqliteCatalogPersistence.readOnlySnapshot(database.path)
          : CatalogSnapshot.empty();
    }
    // A server share can be selected before that folder is added to the PC
    // gallery. Include those roots without losing existing albums/favorites.
    final unindexed = roots
        .where(
          (root) => !snapshot.items.any((item) {
            final uri = Uri.tryParse(item.uri);
            return uri?.scheme == 'file' &&
                p.isWithin(
                  Directory(root).absolute.path,
                  File.fromUri(uri!).absolute.path,
                );
          }),
        )
        .toList();
    if (unindexed.isNotEmpty) {
      final scan = await createLocalMediaScanner().scan(unindexed);
      final byUri = {
        for (final item in scan.items) item.uri: item,
        for (final item in snapshot.items) item.uri: item,
      };
      snapshot = CatalogSnapshot(
        items: byUri.values,
        albums: snapshot.albums,
        savedAt: snapshot.savedAt,
      );
    }
    final file = File('${directory.path}/tools/analysis/analysis.json');
    if (!await file.exists() || await file.length() > 64 << 20) return snapshot;
    try {
      final analysis = jsonDecode(await file.readAsString()) as Map;
      if (analysis['version'] != 1 ||
          analysis['faces'] is! List ||
          analysis['names'] is! Map) {
        return snapshot;
      }
      final groups = <String, Set<String>>{};
      for (final face in analysis['faces'] as List) {
        if (face is Map &&
            face['personId'] is String &&
            face['itemId'] is String) {
          (groups[face['personId'] as String] ??= {}).add(
            face['itemId'] as String,
          );
        }
      }
      return CatalogSnapshot(
        items: snapshot.items,
        savedAt: snapshot.savedAt,
        albums: [
          ...snapshot.albums,
          for (final entry in groups.entries)
            MediaAlbum(
              id: 'person:${entry.key}',
              kind: AlbumKind.person,
              name:
                  analysis['names'][entry.key] is String &&
                      (analysis['names'][entry.key] as String).isNotEmpty
                  ? analysis['names'][entry.key] as String
                  : 'Unnamed person',
              itemIds: entry.value,
              createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
              updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            ),
        ],
      );
    } on FormatException {
      return snapshot;
    } on TypeError {
      return snapshot;
    }
  }
}
