import 'catalog_persistence_factory_stub.dart'
    if (dart.library.io) 'catalog_persistence_factory_io.dart'
    as platform;

export 'catalog_persistence_base.dart';

import 'catalog_persistence_base.dart';

/// Creates SQLite persistence for `.sqlite`/`.db` paths and supports older JSON
/// paths. SQLite imports a sibling `catalog.json` once, unless a legacy path is
/// explicitly supplied. Unsupported or corrupt catalogues fail closed.
/// Otherwise it returns a fully functional in-memory store.
CatalogPersistence createCatalogPersistence({
  String? databaseFilePath,
  String? legacyJsonFilePath,
}) => platform.createCatalogPersistence(
  databaseFilePath: databaseFilePath,
  legacyJsonFilePath: legacyJsonFilePath,
);
