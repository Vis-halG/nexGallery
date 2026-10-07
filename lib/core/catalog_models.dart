import 'dart:collection';

import 'media_item.dart';

enum AlbumKind { manual, folder, smart, person }

final class MediaAlbum {
  MediaAlbum({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.kind = AlbumKind.manual,
    this.coverItemId,
    this.isReadOnly = false,
    Iterable<String> itemIds = const <String>[],
  }) : itemIds = List<String>.unmodifiable(itemIds);

  final String id;
  final String name;
  final AlbumKind kind;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? coverItemId;
  final bool isReadOnly;
  final List<String> itemIds;

  MediaAlbum copyWith({
    String? id,
    String? name,
    AlbumKind? kind,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? coverItemId = _unset,
    bool? isReadOnly,
    Iterable<String>? itemIds,
  }) => MediaAlbum(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    coverItemId: identical(coverItemId, _unset)
        ? this.coverItemId
        : coverItemId as String?,
    isReadOnly: isReadOnly ?? this.isReadOnly,
    itemIds: itemIds ?? this.itemIds,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'kind': kind.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (coverItemId != null) 'coverItemId': coverItemId,
    'isReadOnly': isReadOnly,
    'itemIds': itemIds,
  };

  factory MediaAlbum.fromJson(Map<String, Object?> json) => MediaAlbum(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    kind: _enumByName(AlbumKind.values, json['kind'], AlbumKind.manual),
    createdAt: _dateTime(json['createdAt']) ?? DateTime.now().toUtc(),
    updatedAt: _dateTime(json['updatedAt']) ?? DateTime.now().toUtc(),
    coverItemId: json['coverItemId'] as String?,
    isReadOnly: json['isReadOnly'] as bool? ?? false,
    itemIds: _strings(json['itemIds']),
  );
}

enum CatalogSortField { name, modifiedAt, createdAt, takenAt, size, kind }

enum CatalogSortDirection { ascending, descending }

/// Filter, ordering and pagination options for a local catalogue request.
final class CatalogQuery {
  CatalogQuery({
    this.searchText = '',
    this.section = MediaSection.library,
    this.favoritesOnly = false,
    this.albumId,
    this.sortField = CatalogSortField.modifiedAt,
    this.sortDirection = CatalogSortDirection.descending,
    this.offset = 0,
    this.limit = 60,
    Iterable<MediaKind> kinds = const <MediaKind>[],
    Iterable<MediaSource> sources = const <MediaSource>[],
    Iterable<String>? itemIds,
  }) : assert(offset >= 0),
       assert(limit > 0),
       kinds = Set<MediaKind>.unmodifiable(kinds),
       sources = Set<MediaSource>.unmodifiable(sources),
       itemIds = itemIds == null ? null : Set<String>.unmodifiable(itemIds);

  final String searchText;
  final MediaSection? section;
  final bool favoritesOnly;
  final String? albumId;
  final CatalogSortField sortField;
  final CatalogSortDirection sortDirection;
  final int offset;
  final int limit;
  final Set<MediaKind> kinds;
  final Set<MediaSource> sources;
  /// An access-filtered identity set. Null means unrestricted; empty means no
  /// currently authorized items, including when media permission was revoked.
  final Set<String>? itemIds;

  CatalogQuery copyWith({
    String? searchText,
    Object? section = _unset,
    bool? favoritesOnly,
    Object? albumId = _unset,
    CatalogSortField? sortField,
    CatalogSortDirection? sortDirection,
    int? offset,
    int? limit,
    Iterable<MediaKind>? kinds,
    Iterable<MediaSource>? sources,
    Object? itemIds = _unset,
  }) => CatalogQuery(
    searchText: searchText ?? this.searchText,
    section: identical(section, _unset)
        ? this.section
        : section as MediaSection?,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    albumId: identical(albumId, _unset) ? this.albumId : albumId as String?,
    sortField: sortField ?? this.sortField,
    sortDirection: sortDirection ?? this.sortDirection,
    offset: offset ?? this.offset,
    limit: limit ?? this.limit,
    kinds: kinds ?? this.kinds,
    sources: sources ?? this.sources,
    itemIds: identical(itemIds, _unset) ? this.itemIds : itemIds as Iterable<String>?,
  );
}

final class CatalogPage<T> {
  CatalogPage({
    required Iterable<T> items,
    required this.offset,
    required this.limit,
    required this.totalCount,
  }) : items = List<T>.unmodifiable(items);

  final List<T> items;
  final int offset;
  final int limit;
  final int totalCount;

  bool get hasPrevious => offset > 0;
  bool get hasNext => offset + items.length < totalCount;
  int? get nextOffset => hasNext ? offset + items.length : null;
}

final class CategorySummary {
  const CategorySummary({
    required this.kind,
    required this.itemCount,
    required this.totalBytes,
  });

  final MediaKind kind;
  final int itemCount;
  final int totalBytes;
}

/// Serializable point-in-time catalogue state.
final class CatalogSnapshot {
  CatalogSnapshot({
    required Iterable<MediaItem> items,
    required Iterable<MediaAlbum> albums,
    required this.savedAt,
    this.schemaVersion = currentSchemaVersion,
  }) : items = List<MediaItem>.unmodifiable(items),
       albums = List<MediaAlbum>.unmodifiable(albums);

  static const int currentSchemaVersion = 1;

  factory CatalogSnapshot.empty() => CatalogSnapshot(
    items: const <MediaItem>[],
    albums: const <MediaAlbum>[],
    savedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  final int schemaVersion;
  final DateTime savedAt;
  final List<MediaItem> items;
  final List<MediaAlbum> albums;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'savedAt': savedAt.toUtc().toIso8601String(),
    'items': items.map((item) => item.toJson()).toList(growable: false),
    'albums': albums.map((album) => album.toJson()).toList(growable: false),
  };

  factory CatalogSnapshot.fromJson(Map<String, Object?> json) =>
      CatalogSnapshot(
        schemaVersion: _integer(json['schemaVersion']) ?? currentSchemaVersion,
        savedAt: _dateTime(json['savedAt']) ?? DateTime.now().toUtc(),
        items: _maps(json['items']).map(MediaItem.fromJson),
        albums: _maps(json['albums']).map(MediaAlbum.fromJson),
      );
}

const Object _unset = Object();

T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  if (name is! String) return fallback;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

DateTime? _dateTime(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

int? _integer(Object? value) => value is num ? value.toInt() : null;

List<String> _strings(Object? value) => value is List<Object?>
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

Iterable<Map<String, Object?>> _maps(Object? value) sync* {
  if (value is! List<Object?>) return;
  for (final element in value) {
    if (element is Map) {
      yield UnmodifiableMapView<String, Object?>(
        element.map<String, Object?>(
          (key, value) => MapEntry<String, Object?>(key.toString(), value),
        ),
      );
    }
  }
}
