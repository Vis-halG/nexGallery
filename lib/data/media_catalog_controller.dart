import 'dart:async';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import 'media_catalog_repository.dart';

final class CatalogViewState {
  CatalogViewState({
    required this.query,
    required this.page,
    required Iterable<CategorySummary> categories,
    required this.albumPage,
    required this.isBusy,
    this.error,
  }) : categories = List<CategorySummary>.unmodifiable(categories);

  final CatalogQuery query;
  final CatalogPage<MediaItem> page;
  final List<CategorySummary> categories;
  final CatalogPage<MediaAlbum> albumPage;
  final bool isBusy;
  final Object? error;

  CatalogViewState copyWith({
    CatalogQuery? query,
    CatalogPage<MediaItem>? page,
    Iterable<CategorySummary>? categories,
    CatalogPage<MediaAlbum>? albumPage,
    bool? isBusy,
    Object? error = _unset,
  }) => CatalogViewState(
    query: query ?? this.query,
    page: page ?? this.page,
    categories: categories ?? this.categories,
    albumPage: albumPage ?? this.albumPage,
    isBusy: isBusy ?? this.isBusy,
    error: identical(error, _unset) ? this.error : error,
  );
}

/// Small reactive adapter that presentation code can bind to without a state
/// management dependency.
final class MediaCatalogController {
  MediaCatalogController(this.repository, {CatalogQuery? initialQuery})
    : _query = initialQuery ?? CatalogQuery() {
    _state = _readState(isBusy: false);
    _repositorySubscription = repository.changes.listen((_) => refresh());
  }

  final MediaCatalogRepository repository;
  final StreamController<CatalogViewState> _states =
      StreamController<CatalogViewState>.broadcast(sync: true);
  late final StreamSubscription<CatalogSnapshot> _repositorySubscription;
  late CatalogViewState _state;
  CatalogQuery _query;
  bool _disposed = false;

  CatalogViewState get state => _state;
  Stream<CatalogViewState> get states => _states.stream;

  void setQuery(CatalogQuery query) {
    _ensureActive();
    _query = query;
    refresh();
  }

  void updateSearch(String searchText) =>
      setQuery(_query.copyWith(searchText: searchText, offset: 0));

  void showSection(MediaSection section) =>
      setQuery(_query.copyWith(section: section, offset: 0));

  void showKinds(Iterable<MediaKind> kinds) =>
      setQuery(_query.copyWith(kinds: kinds, offset: 0));

  void showSources(Iterable<MediaSource> sources) =>
      setQuery(_query.copyWith(sources: sources, offset: 0));

  void showAlbum(String? albumId) =>
      setQuery(_query.copyWith(albumId: albumId, offset: 0));

  void sortBy(
    CatalogSortField field, {
    CatalogSortDirection direction = CatalogSortDirection.descending,
  }) => setQuery(
    _query.copyWith(sortField: field, sortDirection: direction, offset: 0),
  );

  void nextPage() {
    final nextOffset = _state.page.nextOffset;
    if (nextOffset != null) {
      setQuery(_query.copyWith(offset: nextOffset));
    }
  }

  void previousPage() {
    if (!_state.page.hasPrevious) return;
    final offset = (_query.offset - _query.limit).clamp(0, _query.offset);
    setQuery(_query.copyWith(offset: offset));
  }

  void refresh() {
    if (_disposed) return;
    _state = _readState(isBusy: _state.isBusy, error: null);
    _emit();
  }

  Future<void> upsertAll(Iterable<MediaItem> items) =>
      _run(() => repository.upsertAll(items));

  Future<void> setFavorite(String itemId, bool value) =>
      _run(() => repository.setFavorite(itemId, value));

  Future<void> moveToArchive(String itemId) =>
      _run(() => repository.moveToArchive(itemId));

  Future<void> moveToTrash(String itemId) =>
      _run(() => repository.moveToTrash(itemId));

  Future<void> restore(String itemId) => _run(() => repository.restore(itemId));

  Future<void> deletePermanently(String itemId) =>
      _run(() => repository.deletePermanently(itemId));

  Future<MediaAlbum?> createAlbum(String name) async {
    MediaAlbum? created;
    await _run(() async {
      created = await repository.createAlbum(name);
    });
    return created;
  }

  Future<void> addToAlbum(String albumId, Iterable<String> itemIds) =>
      _run(() => repository.addToAlbum(albumId, itemIds));

  Future<void> removeFromAlbum(String albumId, Iterable<String> itemIds) =>
      _run(() => repository.removeFromAlbum(albumId, itemIds));

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _repositorySubscription.cancel();
    await _states.close();
  }

  Future<void> _run(Future<void> Function() operation) async {
    _ensureActive();
    _state = _state.copyWith(isBusy: true, error: null);
    _emit();
    try {
      await operation();
      _state = _readState(isBusy: false, error: null);
    } catch (error) {
      _state = _readState(isBusy: false, error: error);
      rethrow;
    } finally {
      _emit();
    }
  }

  CatalogViewState _readState({required bool isBusy, Object? error}) =>
      CatalogViewState(
        query: _query,
        page: repository.query(_query),
        categories: repository.categories(
          section: _query.section ?? MediaSection.library,
          source: _query.sources.length == 1 ? _query.sources.single : null,
        ),
        albumPage: repository.albums(),
        isBusy: isBusy,
        error: error,
      );

  void _emit() {
    if (!_states.isClosed) _states.add(_state);
  }

  void _ensureActive() {
    if (_disposed) throw StateError('Controller is disposed.');
  }
}

const Object _unset = Object();
