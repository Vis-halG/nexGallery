import 'dart:convert';
import 'dart:io';

import '../core/catalog_models.dart';
import 'catalog_persistence_base.dart';

CatalogPersistence createCatalogPersistence({String? databaseFilePath}) {
  final path = databaseFilePath?.trim();
  if (path == null || path.isEmpty) return InMemoryCatalogPersistence();
  return ResilientCatalogPersistence(JsonFileCatalogPersistence(path));
}

final class JsonFileCatalogPersistence implements CatalogPersistence {
  JsonFileCatalogPersistence(this.filePath, {this.maximumBytes = 128 << 20});

  final String filePath;
  final int maximumBytes;

  @override
  Future<CatalogSnapshot> load() async {
    final file = File(filePath);
    if (!await file.exists()) return CatalogSnapshot.empty();
    final length = await file.length();
    if (length > maximumBytes) {
      throw const FormatException(
        'Catalogue file exceeds the safe size limit.',
      );
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const FormatException('Catalogue root must be a JSON object.');
    }
    final object = decoded.map<String, Object?>(
      (key, value) => MapEntry<String, Object?>(key.toString(), value),
    );
    final version = object['schemaVersion'];
    if (version is num &&
        version.toInt() > CatalogSnapshot.currentSchemaVersion) {
      throw UnsupportedError(
        'Catalogue schema ${version.toInt()} is newer than supported.',
      );
    }
    return CatalogSnapshot.fromJson(object);
  }

  @override
  Future<void> save(CatalogSnapshot snapshot) async {
    final target = File(filePath);
    await target.parent.create(recursive: true);

    final suffix = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File('$filePath.$suffix.tmp');
    final backup = File('$filePath.bak');
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);

    if (!await target.exists()) {
      await temporary.rename(filePath);
      return;
    }

    if (await backup.exists()) await backup.delete();
    await target.rename(backup.path);
    try {
      await temporary.rename(filePath);
      await backup.delete();
    } catch (_) {
      if (await temporary.exists()) await temporary.delete();
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(filePath);
      }
      rethrow;
    }
  }
}
