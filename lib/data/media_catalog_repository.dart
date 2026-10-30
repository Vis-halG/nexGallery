import 'dart:async';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import 'catalog_persistence.dart';

/// Owns the local catalogue, applies user mutations and serves paged queries.
final class MediaCatalogRepository {
  MediaCatalogRepository._({
    required this._persistence,
    required CatalogSnapshot initialSnapshot,
  }) : _items = <String, MediaItem>{
         for (final item in initialSnapshot.items)
           if (item.id.isNotEmpty) item.id: item,
       },
       _albums = <String, MediaAlbum>{
         for (final album in initialSnapshot.albums)
           if (album.id.isNotEmpty) album.id: album,
       };

  static Future<MediaCatalogRepository> open({
    CatalogPersistence? persistence,
    String? databaseFilePath,
    String? legacyJsonFilePath,
  }) async {
    final selectedPersistence =
        persistence ??
        createCatalogPersistence(
          databaseFilePath: databaseFilePath,
          legacyJsonFilePath: legacyJsonFilePath,
        );
    final snapshot = await selectedPersistence.load();
    return MediaCatalogRepository._(
      persistence: selectedPersistence,
      initialSnapshot: snapshot,
    );
  }

  CatalogPersistence _persistence;

  /// Switches storage only after the complete current state is durably saved.
  /// It shares the mutation queue so a favorite/scan cannot race migration.
  Future<void> migratePersistence(
    CatalogPersistence target, {
    Future<void> Function()? commit,
  }) {
    if (_disposed) return Future.error(StateError('Catalogue is closed.'));
    final result = _writeQueue.then((_) async {
      await target.save(snapshot);
      final previous = _persistence;
      _persistence = target;
      if (previous is CloseableCatalogPersistence) await previous.close();
      if (commit != null) await commit();
    });
    _writeQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  final Map<String, MediaItem> _items;
  final Map<String, MediaAlbum> _albums;
  final StreamController<CatalogSnapshot> _changes =
      StreamController<CatalogSnapshot>.broadcast();
  Future<void> _writeQueue = Future<void>.value();
  int _albumSequence = 0;
  bool _disposed = false;

  Stream<CatalogSnapshot> get changes => _changes.stream;
  Future<void> flush() => _writeQueue;
  int get itemCount => _items.length;
  int get albumCount => _albums.length;

  CatalogSnapshot get snapshot => CatalogSnapshot(
    items: _items.values,
    albums: _albums.values,
    savedAt: DateTime.now().toUtc(),
  );

  MediaItem? itemById(String id) => _items[id];
  MediaAlbum? albumById(String id) => _albums[id];

  CatalogPage<MediaItem> query([CatalogQuery? request]) {
    final query = request ?? CatalogQuery();
    Iterable<MediaItem> result = _items.values;
    if (query.itemIds case final itemIds?) {
      result = result.where((item) => itemIds.contains(item.id));
    }

    if (query.section case final section?) {
      result = result.where((item) => item.section == section);
    }
    if (query.favoritesOnly) {
      result = result.where((item) => item.isFavorite);
    }
    if (query.kinds.isNotEmpty) {
      result = result.where((item) => query.kinds.contains(item.kind));
    }
    if (query.sources.isNotEmpty) {
      result = result.where((item) => query.sources.contains(item.source));
    }
    if (query.albumId case final albumId?) {
      final itemIds = _albums[albumId]?.itemIds.toSet() ?? const <String>{};
      result = result.where((item) => itemIds.contains(item.id));
    }

    final terms = query.searchText
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList(growable: false);
    if (terms.isNotEmpty) {
      result = result.where((item) {
        final searchable = <String>[
          item.name,
          item.relativePath,
          item.metadata.extension ?? '',
          item.metadata.mimeType ?? '',
          ...item.metadata.tags,
          ...item.metadata.attributes.values,
        ].join(' ').toLowerCase();
        return terms.every(searchable.contains);
      });
    }

    final sorted = result.toList(growable: false)
      ..sort((left, right) => _compareItems(left, right, query));
    final offset = query.offset.clamp(0, sorted.length);
    final limit = query.limit.clamp(1, 500);
    final end = (offset + limit).clamp(offset, sorted.length);
    return CatalogPage<MediaItem>(
      items: sorted.sublist(offset, end),
      offset: offset,
      limit: limit,
      totalCount: sorted.length,
    );
  }

  List<CategorySummary> categories({
    MediaSection section = MediaSection.library,
    MediaSource? source,
  }) {
    final counts = <MediaKind, int>{};
    final bytes = <MediaKind, int>{};
    for (final item in _items.values) {
      if (item.section != section ||
          (source != null && item.source != source)) {
        continue;
      }
      counts.update(item.kind, (value) => value + 1, ifAbsent: () => 1);
      bytes.update(
        item.kind,
        (value) => value + item.metadata.sizeBytes,
        ifAbsent: () => item.metadata.sizeBytes,
      );
    }
    return List<CategorySummary>.unmodifiable(
      MediaKind.values.map(
        (kind) => CategorySummary(
          kind: kind,
          itemCount: counts[kind] ?? 0,
          totalBytes: bytes[kind] ?? 0,
        ),
      ),
    );
  }

  CatalogPage<MediaAlbum> albums({
    int offset = 0,
    int limit = 60,
    String searchText = '',
  }) {
    final normalized = searchText.trim().toLowerCase();
    final result =
        _albums.values
            .where(
              (album) =>
                  normalized.isEmpty ||
                  album.name.toLowerCase().contains(normalized),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final byName = left.name.toLowerCase().compareTo(
              right.name.toLowerCase(),
            );
            return byName != 0 ? byName : left.id.compareTo(right.id);
          });
    final safeOffset = offset.clamp(0, result.length);
    final safeLimit = limit.clamp(1, 500);
    final end = (safeOffset + safeLimit).clamp(safeOffset, result.length);
    return CatalogPage<MediaAlbum>(
      items: result.sublist(safeOffset, end),
      offset: safeOffset,
      limit: safeLimit,
      totalCount: result.length,
    );
  }

  Future<void> upsert(MediaItem item, {bool preserveUserState = true}) =>
      upsertAll(<MediaItem>[item], preserveUserState: preserveUserState);

  /// Reconciles a physical snapshot while preserving user organization.
  /// Incomplete scans must set [removeMissing] to false: a missing observation
  /// does not prove that a file was deleted.
  Future<int> synchronizeSource(
    MediaSource source,
    Iterable<MediaItem> scannedItems, {
    bool removeMissing = true,
    Set<MediaKind>? scannedKinds,
    bool preserveTrash = true,
  }) => _mutate<int>(() {
    final incoming = <String, MediaItem>{
      for (final item in scannedItems)
        if (item.id.isNotEmpty && item.source == source) item.id: item,
    };
    _adoptMovedItems(source, incoming, removeMissing: removeMissing);
    for (final entry in incoming.entries) {
      final existing = _items[entry.key];
      if (existing == null) {
        _items[entry.key] = entry.value;
        continue;
      }
      final merged = entry.value.copyWith(
        indexedAt: existing.indexedAt,
        section: existing.section,
        isFavorite: existing.isFavorite,
        thumbnailUri: existing.thumbnailUri,
        deletedAt: existing.deletedAt,
        metadata: _mergeMetadata(existing, entry.value),
      );
      // An unchanged file keeps its object, so the save skips it.
      _items[entry.key] = sameMediaItem(existing, merged) ? existing : merged;
    }
    final staleIds = _items.values
        .where(
          (item) =>
              item.source == source &&
              removeMissing &&
              (scannedKinds == null || scannedKinds.contains(item.kind)) &&
              (!preserveTrash || item.section != MediaSection.trash) &&
              !incoming.containsKey(item.id),
        )
        .map((item) => item.id)
        .toList(growable: false);
    for (final id in staleIds) {
      _items.remove(id);
      _removeItemFromEveryAlbum(id);
    }
    return staleIds.length;
  });

  Future<void> upsertAll(
    Iterable<MediaItem> items, {
    bool preserveUserState = true,
  }) => _mutate<void>(() {
    for (final incoming in items) {
      if (incoming.id.isEmpty) continue;
      final existing = _items[incoming.id];
      final merged = existing == null || !preserveUserState
          ? incoming
          : incoming.copyWith(
              section: existing.section,
              isFavorite: existing.isFavorite,
              thumbnailUri: existing.thumbnailUri,
              deletedAt: existing.deletedAt,
            );
      _items[incoming.id] = existing != null && sameMediaItem(existing, merged)
          ? existing
          : merged;
    }
  });

  /// Item ids follow paths, so a renamed or moved file would arrive as a new
  /// item. It keeps its favorite, albums, Archive/Trash state and edits when
  /// it is the same file: on one drive the Windows file ID matches; across
  /// drives its name, size and modification time match exactly one missing
  /// file. Incomplete scans copy organization instead of moving it, because
  /// an unseen original may still exist.
  void _adoptMovedItems(
    MediaSource source,
    Map<String, MediaItem> incoming, {
    required bool removeMissing,
  }) {
    final fresh = [
      for (final item in incoming.values)
        if (!_items.containsKey(item.id)) item,
    ];
    if (fresh.isEmpty) return;
    final missing = [
      for (final item in _items.values)
        if (item.source == source &&
            item.section != MediaSection.trash &&
            !incoming.containsKey(item.id))
          item,
    ];
    if (missing.isEmpty) return;
    final byIdentity = <String, MediaItem>{
      for (final item in missing)
        ?item.metadata.attributes['fileIdentity']: item,
    };
    String shape(MediaItem item) =>
        '${item.name.toLowerCase()}|${item.metadata.sizeBytes}|'
        '${item.metadata.modifiedAt.toUtc().microsecondsSinceEpoch}';
    final missingByShape = <String, List<MediaItem>>{};
    final freshByShape = <String, int>{};
    if (removeMissing) {
      for (final item in missing) {
        missingByShape.putIfAbsent(shape(item), () => []).add(item);
      }
      for (final item in fresh) {
        freshByShape.update(shape(item), (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final adopted = <String>{};
    for (final item in fresh) {
      var previous = switch (item.metadata.attributes['fileIdentity']) {
        final identity? => byIdentity[identity],
        null => null,
      };
      if (previous != null &&
          previous.metadata.sizeBytes != item.metadata.sizeBytes) {
        previous = null;
      }
      if (previous == null) {
        final candidates = missingByShape[shape(item)];
        if (candidates != null &&
            candidates.length == 1 &&
            freshByShape[shape(item)] == 1) {
          previous = candidates.single;
        }
      }
      if (previous == null || !adopted.add(previous.id)) continue;
      final history = [
        ...?previous.metadata.attributes[movedFromAttribute]
            ?.split(',')
            .where((id) => id.isNotEmpty),
        previous.id,
      ];
      final merged = _mergeMetadata(previous, item);
      _items[item.id] = item.copyWith(
        section: previous.section,
        isFavorite: previous.isFavorite,
        deletedAt: previous.deletedAt,
        metadata: merged.copyWith(
          attributes: {
            ...merged.attributes,
            movedFromAttribute: history
                .skip(history.length > 5 ? history.length - 5 : 0)
                .join(','),
          },
        ),
      );
      final now = DateTime.now().toUtc();
      for (final entry in _albums.entries.toList(growable: false)) {
        final album = entry.value;
        if (!album.itemIds.contains(previous.id)) continue;
        _albums[entry.key] = album.copyWith(
          itemIds: removeMissing
              ? album.itemIds.map((id) => id == previous!.id ? item.id : id)
              : [...album.itemIds, item.id],
          coverItemId: removeMissing && album.coverItemId == previous.id
              ? item.id
              : album.coverItemId,
          updatedAt: now,
        );
      }
      if (removeMissing) _items.remove(previous.id);
    }
  }

  /// Earlier ids of a moved item, oldest first, so local analysis can carry
  /// its faces and indexes over.
  static const movedFromAttribute = 'analysis.movedFrom';

  MediaMetadata _mergeMetadata(MediaItem existing, MediaItem incoming) {
    final old = existing.metadata, fresh = incoming.metadata;
    final unchanged =
        old.sizeBytes == fresh.sizeBytes && old.modifiedAt == fresh.modifiedAt;
    return withUserOverrides(
      fresh.copyWith(
        latitude: fresh.latitude ?? (unchanged ? old.latitude : null),
        longitude: fresh.longitude ?? (unchanged ? old.longitude : null),
        tags: {...fresh.tags, ...old.tags},
        attributes: {
          for (final entry in old.attributes.entries)
            if (entry.key.startsWith('user.') ||
                (unchanged && entry.key.startsWith('analysis.')))
              entry.key: entry.value,
          ...fresh.attributes,
        },
      ),
    );
  }

  /// Forgets catalogue entries whose originals were deleted by the caller.
  Future<int> removeItems(Iterable<String> itemIds) => _mutate<int>(() {
    var count = 0;
    for (final id in itemIds.toSet()) {
      if (_items.remove(id) == null) continue;
      _removeItemFromEveryAlbum(id);
      count++;
    }
    return count;
  });

  /// Applies one catalogue-only change to many items in a single save.
  Future<int> updateItems(
    Iterable<String> itemIds,
    MediaItem Function(MediaItem item) update,
  ) => _mutate<int>(() {
    var count = 0;
    for (final id in itemIds.toSet()) {
      final item = _items[id];
      if (item == null) continue;
      _items[id] = update(item);
      count++;
    }
    return count;
  });

  /// Restores exported organization onto items that still exist. Unknown items
  /// are skipped; albums are merged by identifier without dropping members.
  Future<int> restoreOrganization({
    required Iterable<MediaAlbum> albums,
    required Map<String, OrganizationRecord> items,
  }) => _mutate<int>(() {
    var restored = 0;
    for (final entry in items.entries) {
      final item = _items[entry.key];
      if (item == null) continue;
      final value = entry.value;
      _items[entry.key] = item.copyWith(
        isFavorite: value.favorite || item.isFavorite,
        section:
            item.section == MediaSection.library &&
                value.section == MediaSection.archive
            ? MediaSection.archive
            : item.section,
        metadata: withUserOverrides(
          item.metadata.copyWith(
            attributes: {
              ...item.metadata.attributes,
              for (final attribute in value.attributes.entries)
                if (attribute.key.startsWith('user.'))
                  attribute.key: attribute.value,
            },
          ),
        ),
      );
      restored++;
    }
    final now = DateTime.now().toUtc();
    for (final album in albums) {
      if (album.id.isEmpty || album.name.trim().isEmpty) continue;
      final members = album.itemIds.where(_items.containsKey);
      final existing = _albums[album.id];
      if (existing != null && existing.isReadOnly) continue;
      _albums[album.id] = existing == null
          ? album.copyWith(
              itemIds: members,
              coverItemId: _items.containsKey(album.coverItemId)
                  ? album.coverItemId
                  : null,
              isReadOnly: false,
              updatedAt: now,
            )
          : existing.copyWith(
              itemIds: {...existing.itemIds, ...members},
              updatedAt: now,
            );
    }
    return restored;
  });

  Future<void> setFavorite(String itemId, bool value) => _mutate<void>(() {
    final item = _requireItem(itemId);
    _items[itemId] = item.copyWith(isFavorite: value);
  });

  Future<void> moveToArchive(String itemId) => _mutate<void>(() {
    final item = _requireItem(itemId);
    _items[itemId] = item.copyWith(
      section: MediaSection.archive,
      deletedAt: null,
    );
  });

  Future<void> moveToTrash(String itemId, {DateTime? deletedAt}) =>
      _mutate<void>(() {
        final item = _requireItem(itemId);
        _items[itemId] = item.copyWith(
          section: MediaSection.trash,
          deletedAt: (deletedAt ?? DateTime.now()).toUtc(),
        );
      });

  Future<void> restore(String itemId) => _mutate<void>(() {
    final item = _requireItem(itemId);
    _items[itemId] = item.copyWith(
      section: MediaSection.library,
      deletedAt: null,
    );
  });

  Future<void> deletePermanently(String itemId) => _mutate<void>(() {
    _requireItem(itemId);
    _items.remove(itemId);
    _removeItemFromEveryAlbum(itemId);
  });

  Future<int> emptyTrash({Duration? olderThan}) => _mutate<int>(() {
    final now = DateTime.now().toUtc();
    final ids = _items.values
        .where((item) {
          if (item.section != MediaSection.trash) return false;
          if (olderThan == null) return true;
          final deletedAt = item.deletedAt;
          return deletedAt != null && now.difference(deletedAt) >= olderThan;
        })
        .map((item) => item.id)
        .toList(growable: false);
    for (final id in ids) {
      _items.remove(id);
      _removeItemFromEveryAlbum(id);
    }
    return ids.length;
  });

  Future<MediaAlbum> createAlbum(
    String name, {
    String? id,
    AlbumKind kind = AlbumKind.manual,
    bool isReadOnly = false,
  }) => _mutate<MediaAlbum>(() {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Album name cannot be empty.');
    }
    final now = DateTime.now().toUtc();
    final albumId = id?.trim().isNotEmpty == true
        ? id!.trim()
        : _newAlbumId(now);
    if (_albums.containsKey(albumId)) {
      throw StateError('Album "$albumId" already exists.');
    }
    final album = MediaAlbum(
      id: albumId,
      name: trimmedName,
      kind: kind,
      isReadOnly: isReadOnly,
      createdAt: now,
      updatedAt: now,
    );
    _albums[album.id] = album;
    return album;
  });

  Future<void> renameAlbum(String albumId, String name) => _mutate<void>(() {
    final album = _requireWritableAlbum(albumId);
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Album name cannot be empty.');
    }
    _albums[albumId] = album.copyWith(
      name: trimmedName,
      updatedAt: DateTime.now().toUtc(),
    );
  });

  Future<void> deleteAlbum(String albumId) => _mutate<void>(() {
    _requireWritableAlbum(albumId);
    _albums.remove(albumId);
  });

  Future<void> addToAlbum(String albumId, Iterable<String> itemIds) =>
      _mutate<void>(() {
        final album = _requireWritableAlbum(albumId);
        final updatedIds = album.itemIds.toSet();
        for (final itemId in itemIds) {
          _requireItem(itemId);
          updatedIds.add(itemId);
        }
        _albums[albumId] = album.copyWith(
          itemIds: updatedIds,
          updatedAt: DateTime.now().toUtc(),
        );
      });

  Future<void> removeFromAlbum(String albumId, Iterable<String> itemIds) =>
      _mutate<void>(() {
        final album = _requireWritableAlbum(albumId);
        final removedIds = itemIds.toSet();
        final updatedIds = album.itemIds
            .where((itemId) => !removedIds.contains(itemId))
            .toList(growable: false);
        final coverItemId = removedIds.contains(album.coverItemId)
            ? null
            : album.coverItemId;
        _albums[albumId] = album.copyWith(
          itemIds: updatedIds,
          coverItemId: coverItemId,
          updatedAt: DateTime.now().toUtc(),
        );
      });

  Future<void> setAlbumCover(String albumId, String? itemId) =>
      _mutate<void>(() {
        final album = _requireWritableAlbum(albumId);
        if (itemId != null && !album.itemIds.contains(itemId)) {
          throw ArgumentError.value(
            itemId,
            'itemId',
            'Album cover must be an item in the album.',
          );
        }
        _albums[albumId] = album.copyWith(
          coverItemId: itemId,
          updatedAt: DateTime.now().toUtc(),
        );
      });

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _writeQueue;
    await _changes.close();
    if (_persistence case final CloseableCatalogPersistence persistence) {
      await persistence.close();
    }
  }

  Future<T> _mutate<T>(T Function() operation) {
    if (_disposed) {
      return Future<T>.error(StateError('Repository is disposed.'));
    }
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      final previousItems = Map<String, MediaItem>.of(_items);
      final previousAlbums = Map<String, MediaAlbum>.of(_albums);
      try {
        final result = operation();
        final updated = snapshot;
        await _persistence.save(updated);
        if (!_changes.isClosed) _changes.add(updated);
        completer.complete(result);
      } catch (error, stackTrace) {
        _items
          ..clear()
          ..addAll(previousItems);
        _albums
          ..clear()
          ..addAll(previousAlbums);
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  MediaItem _requireItem(String itemId) {
    final item = _items[itemId];
    if (item == null) throw StateError('Unknown media item "$itemId".');
    return item;
  }

  MediaAlbum _requireWritableAlbum(String albumId) {
    final album = _albums[albumId];
    if (album == null) throw StateError('Unknown album "$albumId".');
    if (album.isReadOnly) {
      throw StateError('Album "$albumId" is read-only.');
    }
    return album;
  }

  void _removeItemFromEveryAlbum(String itemId) {
    final now = DateTime.now().toUtc();
    for (final entry in _albums.entries.toList(growable: false)) {
      final album = entry.value;
      if (!album.itemIds.contains(itemId)) continue;
      _albums[entry.key] = album.copyWith(
        itemIds: album.itemIds.where((id) => id != itemId),
        coverItemId: album.coverItemId == itemId ? null : album.coverItemId,
        updatedAt: now,
      );
    }
  }

  String _newAlbumId(DateTime now) {
    _albumSequence += 1;
    return 'album_${now.microsecondsSinceEpoch}_$_albumSequence';
  }
}

int _compareItems(MediaItem left, MediaItem right, CatalogQuery query) {
  int comparison;
  switch (query.sortField) {
    case CatalogSortField.name:
      comparison = left.name.toLowerCase().compareTo(right.name.toLowerCase());
    case CatalogSortField.modifiedAt:
      comparison = left.metadata.modifiedAt.compareTo(
        right.metadata.modifiedAt,
      );
    case CatalogSortField.createdAt:
      comparison = _fallbackDate(left).compareTo(_fallbackDate(right));
    case CatalogSortField.takenAt:
      comparison = (left.metadata.takenAt ?? left.metadata.modifiedAt)
          .compareTo(right.metadata.takenAt ?? right.metadata.modifiedAt);
    case CatalogSortField.size:
      comparison = left.metadata.sizeBytes.compareTo(right.metadata.sizeBytes);
    case CatalogSortField.kind:
      comparison = left.kind.index.compareTo(right.kind.index);
  }
  if (query.sortDirection == CatalogSortDirection.descending) {
    comparison = -comparison;
  }
  return comparison != 0 ? comparison : left.id.compareTo(right.id);
}

DateTime _fallbackDate(MediaItem item) =>
    item.metadata.createdAt ?? item.metadata.modifiedAt;
