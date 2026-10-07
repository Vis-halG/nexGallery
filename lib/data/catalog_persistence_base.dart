import '../core/catalog_models.dart';

abstract interface class CatalogPersistence {
  Future<CatalogSnapshot> load();

  Future<void> save(CatalogSnapshot snapshot);
}

/// Persistence stores that must drain background work before shutdown.
abstract interface class CloseableCatalogPersistence
    implements CatalogPersistence {
  Future<void> close();
}

final class InMemoryCatalogPersistence implements CatalogPersistence {
  InMemoryCatalogPersistence([CatalogSnapshot? initial])
    : _snapshot = initial ?? CatalogSnapshot.empty();

  CatalogSnapshot _snapshot;

  @override
  Future<CatalogSnapshot> load() async => _snapshot;

  @override
  Future<void> save(CatalogSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

/// Keeps a usable in-memory copy if disk persistence becomes unavailable.
final class ResilientCatalogPersistence implements CatalogPersistence {
  ResilientCatalogPersistence(
    this._primary, {
    InMemoryCatalogPersistence? fallback,
  }) : _fallback = fallback ?? InMemoryCatalogPersistence();

  final CatalogPersistence _primary;
  final InMemoryCatalogPersistence _fallback;

  bool _isDegraded = false;
  Object? _lastError;

  bool get isDegraded => _isDegraded;
  Object? get lastError => _lastError;

  @override
  Future<CatalogSnapshot> load() async {
    try {
      final snapshot = await _primary.load();
      await _fallback.save(snapshot);
      _isDegraded = false;
      _lastError = null;
      return snapshot;
    } catch (error) {
      _isDegraded = true;
      _lastError = error;
      return _fallback.load();
    }
  }

  @override
  Future<void> save(CatalogSnapshot snapshot) async {
    await _fallback.save(snapshot);
    try {
      await _primary.save(snapshot);
      _isDegraded = false;
      _lastError = null;
    } catch (error) {
      _isDegraded = true;
      _lastError = error;
    }
  }
}
