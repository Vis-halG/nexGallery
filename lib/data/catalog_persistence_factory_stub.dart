import 'catalog_persistence_base.dart';

CatalogPersistence createCatalogPersistence({String? databaseFilePath}) =>
    InMemoryCatalogPersistence();
