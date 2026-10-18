import 'dart:collection';

/// Broad media groups used throughout the local catalogue.
enum MediaKind { image, video, document, audio, apk, archive, other }

/// Identifies where a catalogue entry physically lives.
enum MediaSource { phone, pc }

/// Lifecycle section for an item. Only one section can be active at a time.
enum MediaSection { library, archive, trash }

/// Metadata that can be read without decoding the entire file.
final class MediaMetadata {
  MediaMetadata({
    required this.sizeBytes,
    required this.modifiedAt,
    this.createdAt,
    this.takenAt,
    this.duration,
    this.width,
    this.height,
    this.mimeType,
    this.extension,
    this.checksum,
    this.latitude,
    this.longitude,
    Iterable<String> tags = const <String>[],
    Map<String, String> attributes = const <String, String>{},
  }) : tags = List<String>.unmodifiable(tags),
       attributes = UnmodifiableMapView<String, String>(
         Map<String, String>.from(attributes),
       );

  final int sizeBytes;
  final DateTime modifiedAt;
  final DateTime? createdAt;
  final DateTime? takenAt;
  final Duration? duration;
  final int? width;
  final int? height;
  final String? mimeType;
  final String? extension;
  final String? checksum;
  final double? latitude;
  final double? longitude;
  final List<String> tags;
  final Map<String, String> attributes;

  MediaMetadata copyWith({
    int? sizeBytes,
    DateTime? modifiedAt,
    Object? createdAt = _unset,
    Object? takenAt = _unset,
    Object? duration = _unset,
    Object? width = _unset,
    Object? height = _unset,
    Object? mimeType = _unset,
    Object? extension = _unset,
    Object? checksum = _unset,
    Object? latitude = _unset,
    Object? longitude = _unset,
    Iterable<String>? tags,
    Map<String, String>? attributes,
  }) => MediaMetadata(
    sizeBytes: sizeBytes ?? this.sizeBytes,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    createdAt: identical(createdAt, _unset)
        ? this.createdAt
        : createdAt as DateTime?,
    takenAt: identical(takenAt, _unset) ? this.takenAt : takenAt as DateTime?,
    duration: identical(duration, _unset)
        ? this.duration
        : duration as Duration?,
    width: identical(width, _unset) ? this.width : width as int?,
    height: identical(height, _unset) ? this.height : height as int?,
    mimeType: identical(mimeType, _unset) ? this.mimeType : mimeType as String?,
    extension: identical(extension, _unset)
        ? this.extension
        : extension as String?,
    checksum: identical(checksum, _unset) ? this.checksum : checksum as String?,
    latitude: identical(latitude, _unset) ? this.latitude : latitude as double?,
    longitude: identical(longitude, _unset)
        ? this.longitude
        : longitude as double?,
    tags: tags ?? this.tags,
    attributes: attributes ?? this.attributes,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sizeBytes': sizeBytes,
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    if (takenAt != null) 'takenAt': takenAt!.toUtc().toIso8601String(),
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (mimeType != null) 'mimeType': mimeType,
    if (extension != null) 'extension': extension,
    if (checksum != null) 'checksum': checksum,
    if (latitude != null) 'latitude': latitude,
    if (longitude != null) 'longitude': longitude,
    if (tags.isNotEmpty) 'tags': tags,
    if (attributes.isNotEmpty) 'attributes': attributes,
  };

  factory MediaMetadata.fromJson(Map<String, Object?> json) {
    final modifiedAt =
        _dateTime(json['modifiedAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return MediaMetadata(
      sizeBytes: _integer(json['sizeBytes']) ?? 0,
      modifiedAt: modifiedAt,
      createdAt: _dateTime(json['createdAt']),
      takenAt: _dateTime(json['takenAt']),
      duration: _duration(json['durationMs']),
      width: _integer(json['width']),
      height: _integer(json['height']),
      mimeType: json['mimeType'] as String?,
      extension: json['extension'] as String?,
      checksum: json['checksum'] as String?,
      latitude: _number(json['latitude']),
      longitude: _number(json['longitude']),
      tags: _strings(json['tags']),
      attributes: _stringMap(json['attributes']),
    );
  }
}

/// Immutable entry representing a local phone or PC file.
final class MediaItem {
  MediaItem({
    required this.id,
    required this.name,
    required this.uri,
    required this.relativePath,
    required this.kind,
    required this.source,
    required this.metadata,
    required this.indexedAt,
    this.section = MediaSection.library,
    this.isFavorite = false,
    this.isAvailable = true,
    this.thumbnailUri,
    this.deletedAt,
  });

  final String id;
  final String name;
  final String uri;
  final String relativePath;
  final MediaKind kind;
  final MediaSource source;
  final MediaMetadata metadata;
  final DateTime indexedAt;
  final MediaSection section;
  final bool isFavorite;

  /// Whether the original can be read. Unavailable entries keep their metadata
  /// and user organization until a later scan can read their folder again.
  final bool isAvailable;
  final String? thumbnailUri;
  final DateTime? deletedAt;

  MediaItem copyWith({
    String? id,
    String? name,
    String? uri,
    String? relativePath,
    MediaKind? kind,
    MediaSource? source,
    MediaMetadata? metadata,
    DateTime? indexedAt,
    MediaSection? section,
    bool? isFavorite,
    bool? isAvailable,
    Object? thumbnailUri = _unset,
    Object? deletedAt = _unset,
  }) => MediaItem(
    id: id ?? this.id,
    name: name ?? this.name,
    uri: uri ?? this.uri,
    relativePath: relativePath ?? this.relativePath,
    kind: kind ?? this.kind,
    source: source ?? this.source,
    metadata: metadata ?? this.metadata,
    indexedAt: indexedAt ?? this.indexedAt,
    section: section ?? this.section,
    isFavorite: isFavorite ?? this.isFavorite,
    isAvailable: isAvailable ?? this.isAvailable,
    thumbnailUri: identical(thumbnailUri, _unset)
        ? this.thumbnailUri
        : thumbnailUri as String?,
    deletedAt: identical(deletedAt, _unset)
        ? this.deletedAt
        : deletedAt as DateTime?,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'uri': uri,
    'relativePath': relativePath,
    'kind': kind.name,
    'source': source.name,
    'metadata': metadata.toJson(),
    'indexedAt': indexedAt.toUtc().toIso8601String(),
    'section': section.name,
    'isFavorite': isFavorite,
    'isAvailable': isAvailable,
    if (thumbnailUri != null) 'thumbnailUri': thumbnailUri,
    if (deletedAt != null) 'deletedAt': deletedAt!.toUtc().toIso8601String(),
  };

  factory MediaItem.fromJson(Map<String, Object?> json) => MediaItem(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    uri: json['uri'] as String? ?? '',
    relativePath: json['relativePath'] as String? ?? '',
    kind: _enumByName(MediaKind.values, json['kind'], MediaKind.other),
    source: _enumByName(MediaSource.values, json['source'], MediaSource.phone),
    metadata: MediaMetadata.fromJson(_objectMap(json['metadata'])),
    indexedAt: _dateTime(json['indexedAt']) ?? DateTime.now().toUtc(),
    section: _enumByName(
      MediaSection.values,
      json['section'],
      MediaSection.library,
    ),
    isFavorite: json['isFavorite'] as bool? ?? false,
    isAvailable: json['isAvailable'] as bool? ?? true,
    thumbnailUri: json['thumbnailUri'] as String?,
    deletedAt: _dateTime(json['deletedAt']),
  );
}

/// User corrections live in `user.*` attributes so rescans cannot undo them.
const userTakenAtKey = 'user.takenAt';
const userLatitudeKey = 'user.latitude';
const userLongitudeKey = 'user.longitude';
const userNoLocationKey = 'user.noLocation';

MediaMetadata withUserOverrides(MediaMetadata metadata) {
  final attributes = metadata.attributes;
  var result = metadata;
  final takenAt = DateTime.tryParse(attributes[userTakenAtKey] ?? '');
  if (takenAt != null) result = result.copyWith(takenAt: takenAt.toUtc());
  if (attributes[userNoLocationKey] == 'true') {
    return result.copyWith(latitude: null, longitude: null);
  }
  final latitude = double.tryParse(attributes[userLatitudeKey] ?? '');
  final longitude = double.tryParse(attributes[userLongitudeKey] ?? '');
  if (latitude != null &&
      longitude != null &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180) {
    result = result.copyWith(latitude: latitude, longitude: longitude);
  }
  return result;
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

double? _number(Object? value) => value is num ? value.toDouble() : null;

Duration? _duration(Object? value) {
  final milliseconds = _integer(value);
  return milliseconds == null ? null : Duration(milliseconds: milliseconds);
}

List<String> _strings(Object? value) => value is List<Object?>
    ? value.whereType<String>().toList(growable: false)
    : const <String>[];

Map<String, String> _stringMap(Object? value) =>
    _objectMap(value)
        .map((key, value) => MapEntry<String, String>(key, value.toString()));

Map<String, Object?> _objectMap(Object? value) => value is Map
    ? value.map<String, Object?>(
        (key, value) => MapEntry<String, Object?>(key.toString(), value),
      )
    : <String, Object?>{};

/// Whether [a] and [b] hold the same catalogue state. Unchanged items keep
/// their object, so saves can skip them.
bool sameMediaItem(MediaItem a, MediaItem b) =>
    identical(a, b) ||
    (a.id == b.id &&
        a.name == b.name &&
        a.uri == b.uri &&
        a.relativePath == b.relativePath &&
        a.kind == b.kind &&
        a.source == b.source &&
        a.section == b.section &&
        a.isFavorite == b.isFavorite &&
        a.isAvailable == b.isAvailable &&
        a.thumbnailUri == b.thumbnailUri &&
        a.indexedAt == b.indexedAt &&
        a.deletedAt == b.deletedAt &&
        _sameJson(a.metadata.toJson(), b.metadata.toJson()));

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameJson(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
