import 'catalog_persistence_factory_stub.dart'
    if (dart.library.io) 'catalog_persistence_factory_io.dart'
    as platform;

export 'catalog_persistence_base.dart';

import 'catalog_persistence_base.dart';

/// Creates JSON persistence when a file path and `dart:io` are available.
/// Otherwise it returns a fully functional in-memory store.
CatalogPersistence createCatalogPersistence({String? databaseFilePath}) =>
    platform.createCatalogPersistence(databaseFilePath: databaseFilePath);
