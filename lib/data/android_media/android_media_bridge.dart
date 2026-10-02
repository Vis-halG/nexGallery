import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Media collections exposed by Android's MediaStore.
enum AndroidMediaType {
  image,
  video,
  audio;

  String get wireName => name;
}

enum AndroidMediaSort {
  dateAdded,
  dateModified,
  dateTaken,
  displayName,
  size,
  duration,
}

enum AndroidMediaPermission {
  granted,
  partial,
  denied;

  static AndroidMediaPermission fromWire(Object? value) => switch (value) {
    'granted' => granted,
    'partial' => partial,
    _ => denied,
  };
}

@immutable
class AndroidMediaPermissionStatus {
  const AndroidMediaPermissionStatus({
    required this.sdkInt,
    required this.statuses,
    required this.visualAccess,
    required this.canOpenSettings,
  });

  factory AndroidMediaPermissionStatus.fromMap(Map<Object?, Object?> value) {
    final rawStatuses = _map(value['statuses']);
    return AndroidMediaPermissionStatus(
      sdkInt: _integer(value['sdkInt']) ?? 0,
      statuses: <AndroidMediaType, AndroidMediaPermission>{
        for (final type in AndroidMediaType.values)
          if (rawStatuses.containsKey(type.wireName))
            type: AndroidMediaPermission.fromWire(rawStatuses[type.wireName]),
      },
      visualAccess: value['visualAccess'] as String? ?? 'denied',
      canOpenSettings: value['canOpenSettings'] as bool? ?? false,
    );
  }

  final int sdkInt;
  final Map<AndroidMediaType, AndroidMediaPermission> statuses;

  /// `full`, `partial`, or `denied`. `partial` is Android 14's selected-media
  /// access and still allows a useful, user-controlled gallery.
  final String visualAccess;
  final bool canOpenSettings;

  bool isGranted(AndroidMediaType type) =>
      statuses[type] == AndroidMediaPermission.granted ||
      statuses[type] == AndroidMediaPermission.partial;
}

@immutable
class AndroidMediaItem {
  const AndroidMediaItem({
    required this.id,
    required this.uri,
    required this.type,
    this.displayName,
    this.mimeType,
    this.sizeBytes,
    this.dateAddedSeconds,
    this.dateModifiedSeconds,
    this.dateTakenMilliseconds,
    this.width,
    this.height,
    this.durationMilliseconds,
    this.orientationDegrees,
    this.bucketId,
    this.bucketName,
    this.title,
    this.artist,
    this.album,
    this.relativePath,
  });

  factory AndroidMediaItem.fromMap(Map<Object?, Object?> value) {
    return AndroidMediaItem(
      id: _integer(value['id']) ?? 0,
      uri: Uri.parse(value['uri'] as String),
      type: AndroidMediaType.values.byName(value['mediaType'] as String),
      displayName: value['displayName'] as String?,
      mimeType: value['mimeType'] as String?,
      sizeBytes: _integer(value['size']),
      dateAddedSeconds: _integer(value['dateAdded']),
      dateModifiedSeconds: _integer(value['dateModified']),
      dateTakenMilliseconds: _integer(value['dateTaken']),
      width: _integer(value['width']),
      height: _integer(value['height']),
      durationMilliseconds: _integer(value['duration']),
      orientationDegrees: _integer(value['orientation']),
      bucketId: value['bucketId'] as String?,
      bucketName: value['bucketName'] as String?,
      title: value['title'] as String?,
      artist: value['artist'] as String?,
      album: value['album'] as String?,
      relativePath: value['relativePath'] as String?,
    );
  }

  final int id;
  final Uri uri;
  final AndroidMediaType type;
  final String? displayName;
  final String? mimeType;
  final int? sizeBytes;
  final int? dateAddedSeconds;
  final int? dateModifiedSeconds;
  final int? dateTakenMilliseconds;
  final int? width;
  final int? height;
  final int? durationMilliseconds;
  final int? orientationDegrees;
  final String? bucketId;
  final String? bucketName;
  final String? title;
  final String? artist;
  final String? album;
  final String? relativePath;
}

@immutable
class AndroidMediaPage {
  const AndroidMediaPage({
    required this.items,
    required this.type,
    required this.offset,
    required this.limit,
    required this.hasMore,
    this.nextOffset,
  });

  factory AndroidMediaPage.fromMap(Map<Object?, Object?> value) {
    final rawItems = value['items'] as List<Object?>? ?? const <Object?>[];
    return AndroidMediaPage(
      items: rawItems
          .map((item) => AndroidMediaItem.fromMap(_map(item)))
          .toList(),
      type: AndroidMediaType.values.byName(value['mediaType'] as String),
      offset: _integer(value['offset']) ?? 0,
      limit: _integer(value['limit']) ?? 0,
      hasMore: value['hasMore'] as bool? ?? false,
      nextOffset: _integer(value['nextOffset']),
    );
  }

  final List<AndroidMediaItem> items;
  final AndroidMediaType type;
  final int offset;
  final int limit;
  final bool hasMore;
  final int? nextOffset;
}

@immutable
class AndroidThumbnail {
  const AndroidThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
    required this.mimeType,
  });

  factory AndroidThumbnail.fromMap(Map<Object?, Object?> value) {
    final bytes = value['bytes'];
    if (bytes is! Uint8List) {
      throw const FormatException('Android returned invalid thumbnail bytes');
    }
    return AndroidThumbnail(
      bytes: bytes,
      width: _integer(value['width']) ?? 0,
      height: _integer(value['height']) ?? 0,
      mimeType: value['mimeType'] as String? ?? 'image/jpeg',
    );
  }

  final Uint8List bytes;
  final int width;
  final int height;
  final String mimeType;
}

@immutable
class AndroidMediaOperationResult {
  const AndroidMediaOperationResult({
    required this.status,
    required this.operation,
    required this.requestedCount,
    required this.affectedCount,
    required this.requiresRetry,
  });

  factory AndroidMediaOperationResult.fromMap(Map<Object?, Object?> value) {
    return AndroidMediaOperationResult(
      status: value['status'] as String? ?? 'unknown',
      operation: value['operation'] as String? ?? 'unknown',
      requestedCount: _integer(value['requestedCount']) ?? 0,
      affectedCount:
          _integer(value['affectedCount']) ??
          _integer(value['deletedCount']) ??
          0,
      requiresRetry: value['requiresRetry'] as bool? ?? false,
    );
  }

  /// `completed`, `cancelled`, `authorized`, or `unsupported`.
  final String status;
  final String operation;
  final int requestedCount;
  final int affectedCount;

  /// Android 10 grants consent for one protected item at a time. When true,
  /// invoke delete again with the remaining URI after the user approved it.
  final bool requiresRetry;

  bool get completed => status == 'completed';
}

@immutable
class AndroidIntentResult {
  const AndroidIntentResult(this.status);

  factory AndroidIntentResult.fromMap(Map<Object?, Object?> value) =>
      AndroidIntentResult(value['status'] as String? ?? 'unknown');

  /// `launched` or `unavailable`.
  final String status;
}

@immutable
class AndroidStorageArea {
  const AndroidStorageArea({
    required this.totalBytes,
    required this.availableBytes,
    required this.usedBytes,
  });

  factory AndroidStorageArea.fromMap(Map<Object?, Object?> value) {
    return AndroidStorageArea(
      totalBytes: _integer(value['totalBytes']) ?? 0,
      availableBytes: _integer(value['availableBytes']) ?? 0,
      usedBytes: _integer(value['usedBytes']) ?? 0,
    );
  }

  final int totalBytes;
  final int availableBytes;
  final int usedBytes;
}

@immutable
class AndroidStorageStats {
  const AndroidStorageStats({
    required this.data,
    required this.shared,
    required this.sharedState,
    required this.sdkInt,
  });

  factory AndroidStorageStats.fromMap(Map<Object?, Object?> value) {
    return AndroidStorageStats(
      data: AndroidStorageArea.fromMap(_map(value['data'])),
      shared: AndroidStorageArea.fromMap(_map(value['shared'])),
      sharedState: value['sharedState'] as String? ?? 'unknown',
      sdkInt: _integer(value['sdkInt']) ?? 0,
    );
  }

  final AndroidStorageArea data;
  final AndroidStorageArea shared;
  final String sharedState;
  final int sdkInt;
}

@immutable
class AndroidSafDirectory {
  const AndroidSafDirectory({
    required this.status,
    this.uri,
    this.name,
    this.persisted = false,
    this.canRead = false,
    this.canWrite = false,
  });

  factory AndroidSafDirectory.fromMap(Map<Object?, Object?> value) {
    final rawUri = value['uri'] as String?;
    return AndroidSafDirectory(
      status: value['status'] as String? ?? 'unknown',
      uri: rawUri == null ? null : Uri.parse(rawUri),
      name: value['name'] as String?,
      persisted: value['persisted'] as bool? ?? false,
      canRead: value['canRead'] as bool? ?? false,
      canWrite: value['canWrite'] as bool? ?? false,
    );
  }

  /// `selected`, `persisted`, `cancelled`, or `unavailable`.
  final String status;
  final Uri? uri;
  final String? name;
  final bool persisted;
  final bool canRead;
  final bool canWrite;
}

@immutable
class AndroidDocumentItem {
  const AndroidDocumentItem({
    required this.uri,
    required this.isDirectory,
    required this.flags,
    required this.canWrite,
    required this.canDelete,
    required this.canRename,
    required this.canCreate,
    required this.hasThumbnail,
    this.name,
    this.mimeType,
    this.sizeBytes,
    this.lastModifiedMilliseconds,
  });

  factory AndroidDocumentItem.fromMap(Map<Object?, Object?> value) {
    return AndroidDocumentItem(
      uri: Uri.parse(value['uri'] as String),
      name: value['name'] as String?,
      mimeType: value['mimeType'] as String?,
      isDirectory: value['isDirectory'] as bool? ?? false,
      sizeBytes: _integer(value['size']),
      lastModifiedMilliseconds: _integer(value['lastModified']),
      flags: _integer(value['flags']) ?? 0,
      canWrite: value['canWrite'] as bool? ?? false,
      canDelete: value['canDelete'] as bool? ?? false,
      canRename: value['canRename'] as bool? ?? false,
      canCreate: value['canCreate'] as bool? ?? false,
      hasThumbnail: value['hasThumbnail'] as bool? ?? false,
    );
  }

  final Uri uri;
  final String? name;
  final String? mimeType;
  final bool isDirectory;
  final int? sizeBytes;
  final int? lastModifiedMilliseconds;
  final int flags;
  final bool canWrite;
  final bool canDelete;
  final bool canRename;
  final bool canCreate;
  final bool hasThumbnail;
}

@immutable
class AndroidDocumentPage {
  const AndroidDocumentPage({
    required this.items,
    required this.uri,
    required this.offset,
    required this.limit,
    required this.hasMore,
    this.nextOffset,
  });

  factory AndroidDocumentPage.fromMap(Map<Object?, Object?> value) {
    final rawItems = value['items'] as List<Object?>? ?? const <Object?>[];
    return AndroidDocumentPage(
      items: rawItems
          .map((item) => AndroidDocumentItem.fromMap(_map(item)))
          .toList(),
      uri: Uri.parse(value['uri'] as String),
      offset: _integer(value['offset']) ?? 0,
      limit: _integer(value['limit']) ?? 0,
      hasMore: value['hasMore'] as bool? ?? false,
      nextOffset: _integer(value['nextOffset']),
    );
  }

  final List<AndroidDocumentItem> items;
  final Uri uri;
  final int offset;
  final int limit;
  final bool hasMore;
  final int? nextOffset;
}

@immutable
class AndroidDocumentMutationResult {
  const AndroidDocumentMutationResult({
    required this.status,
    this.uri,
    this.name,
  });

  factory AndroidDocumentMutationResult.fromMap(Map<Object?, Object?> value) {
    final rawUri = value['uri'] as String?;
    return AndroidDocumentMutationResult(
      status: value['status'] as String? ?? 'unknown',
      uri: rawUri == null ? null : Uri.parse(rawUri),
      name: value['name'] as String?,
    );
  }

  /// `completed`, `unsupported`, or `failed`.
  final String status;
  final Uri? uri;
  final String? name;
}

/// Typed Flutter API for nexGallery's dependency-free Android MediaStore code.
///
/// This bridge deliberately has no fallback on desktop. Check [isSupported]
/// before invoking it when sharing a repository across Android and Windows.
class AndroidMediaBridge {
  AndroidMediaBridge._();

  static final AndroidMediaBridge instance = AndroidMediaBridge._();
  static const MethodChannel _channel = MethodChannel(
    'com.thenex.nex_gallery/media',
  );

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<AndroidMediaPermissionStatus> getPermissionStatus({
    Set<AndroidMediaType> mediaTypes = const <AndroidMediaType>{
      AndroidMediaType.image,
      AndroidMediaType.video,
      AndroidMediaType.audio,
    },
  }) async {
    final value = await _invokeMap('getPermissionStatus', <String, Object>{
      'mediaTypes': mediaTypes.map((type) => type.wireName).toList(),
    });
    return AndroidMediaPermissionStatus.fromMap(value);
  }

  Future<AndroidMediaPermissionStatus> requestPermissions({
    Set<AndroidMediaType> mediaTypes = const <AndroidMediaType>{
      AndroidMediaType.image,
      AndroidMediaType.video,
      AndroidMediaType.audio,
    },
    bool includeWriteForLegacy = false,
  }) async {
    final value = await _invokeMap('requestPermissions', <String, Object>{
      'mediaTypes': mediaTypes.map((type) => type.wireName).toList(),
      'includeWriteForLegacy': includeWriteForLegacy,
    });
    return AndroidMediaPermissionStatus.fromMap(value);
  }

  /// Returns one MediaStore collection page. [limit] is bounded to 1..500 by
  /// Android, and [offset] is an item offset within the selected ordering.
  Future<AndroidMediaPage> queryMedia({
    required AndroidMediaType mediaType,
    int limit = 100,
    int offset = 0,
    AndroidMediaSort sortBy = AndroidMediaSort.dateAdded,
    bool descending = true,
  }) async {
    final value = await _invokeMap('queryMedia', <String, Object>{
      'mediaType': mediaType.wireName,
      'limit': limit,
      'offset': offset,
      'sortBy': sortBy.name,
      'descending': descending,
    });
    return AndroidMediaPage.fromMap(value);
  }

  /// Loads a content-URI thumbnail without needing a temporary filesystem path.
  /// Android bounds [size] to 32..1024 logical pixels.
  Future<AndroidThumbnail> loadThumbnail(
    Uri uri, {
    int size = 256,
    String format = 'jpeg',
    int quality = 85,
  }) async {
    final value = await _invokeMap('loadThumbnail', <String, Object>{
      'uri': uri.toString(),
      'size': size,
      'format': format,
      'quality': quality,
    });
    return AndroidThumbnail.fromMap(value);
  }

  /// Opens Android's mandatory confirmation UI on scoped-storage versions.
  Future<AndroidMediaOperationResult> deleteMedia(Iterable<Uri> uris) async {
    final value = await _invokeMap('deleteMedia', <String, Object>{
      'uris': uris.map((uri) => uri.toString()).toList(),
    });
    return AndroidMediaOperationResult.fromMap(value);
  }

  /// Moves media to or out of the Android trash. This is supported on API 30+.
  Future<AndroidMediaOperationResult> setTrashed(
    Iterable<Uri> uris, {
    bool trashed = true,
  }) async {
    final value = await _invokeMap('trashMedia', <String, Object>{
      'uris': uris.map((uri) => uri.toString()).toList(),
      'trashed': trashed,
    });
    return AndroidMediaOperationResult.fromMap(value);
  }

  Future<AndroidIntentResult> openMedia(Uri uri, {String? mimeType}) async {
    final value = await _invokeMap('openMedia', <String, Object?>{
      'uri': uri.toString(),
      'mimeType': mimeType,
    });
    return AndroidIntentResult.fromMap(value);
  }

  Future<AndroidIntentResult> shareMedia(
    Iterable<Uri> uris, {
    String? mimeType,
    String chooserTitle = 'Share media',
  }) async {
    final value = await _invokeMap('shareMedia', <String, Object?>{
      'uris': uris.map((uri) => uri.toString()).toList(),
      'mimeType': mimeType,
      'chooserTitle': chooserTitle,
    });
    return AndroidIntentResult.fromMap(value);
  }

  Future<AndroidStorageStats> getStorageStats() async {
    final value = await _invokeMap('getStorageStats');
    return AndroidStorageStats.fromMap(value);
  }

  /// Absolute path to Android's private, backed-up files directory. Use it for
  /// app-owned catalogs and preferences; media content itself remains in place.
  Future<String> getAppDataPath() async {
    _requireAndroid();
    final value = await _channel.invokeMethod<String>('getAppDataPath');
    if (value == null || value.isEmpty) {
      throw const FormatException('Android returned no app data path');
    }
    return value;
  }

  /// Opens Android's folder picker and persists the user's read/write grant
  /// when the selected document provider supports it.
  Future<AndroidSafDirectory> pickDirectory() async {
    final value = await _invokeMap('pickDirectory');
    return AndroidSafDirectory.fromMap(value);
  }

  /// Returns folder grants retained by Android across app restarts.
  Future<List<AndroidSafDirectory>> getPersistedDirectories() async {
    _requireAndroid();
    final value = await _channel.invokeMethod<List<Object?>>(
      'getPersistedDirectories',
    );
    return (value ?? const <Object?>[])
        .map((item) => AndroidSafDirectory.fromMap(_map(item)))
        .toList();
  }

  /// Lists children of a user-selected Storage Access Framework directory.
  Future<AndroidDocumentPage> listDirectory(
    Uri uri, {
    int limit = 100,
    int offset = 0,
  }) async {
    final value = await _invokeMap('listDirectory', <String, Object>{
      'uri': uri.toString(),
      'limit': limit,
      'offset': offset,
    });
    return AndroidDocumentPage.fromMap(value);
  }

  Future<AndroidDocumentMutationResult> createDirectory(
    Uri parentUri,
    String name,
  ) async {
    final value = await _invokeMap('createDirectory', <String, Object>{
      'parentUri': parentUri.toString(),
      'name': name,
    });
    return AndroidDocumentMutationResult.fromMap(value);
  }

  Future<AndroidDocumentMutationResult> renameDocument(
    Uri uri,
    String name,
  ) async {
    final value = await _invokeMap('renameDocument', <String, Object>{
      'uri': uri.toString(),
      'name': name,
    });
    return AndroidDocumentMutationResult.fromMap(value);
  }

  Future<AndroidDocumentMutationResult> deleteDocument(Uri uri) async {
    final value = await _invokeMap('deleteDocument', <String, Object>{
      'uri': uri.toString(),
    });
    return AndroidDocumentMutationResult.fromMap(value);
  }

  /// Encrypts a small credential with an AES-256-GCM key held by Android
  /// Keystore. Only ciphertext is written to the app's private preferences.
  Future<void> storeSecret(String key, String value) async {
    await _invokeMap('storeSecret', <String, Object>{
      'key': key,
      'value': value,
    });
  }

  /// Decrypts a credential inside the Android process. Returns null when the
  /// key has not been stored; authentication/corruption failures are surfaced.
  Future<String?> readSecret(String key) async {
    final value = await _invokeMap('readSecret', <String, Object>{'key': key});
    if (value['found'] != true) return null;
    final secret = value['value'];
    if (secret is! String) {
      throw const FormatException('Android returned an invalid secret');
    }
    return secret;
  }

  Future<bool> deleteSecret(String key) async {
    final value = await _invokeMap('deleteSecret', <String, Object>{
      'key': key,
    });
    return value['deleted'] as bool? ?? false;
  }

  Future<AndroidIntentResult> openAppSettings() async {
    final value = await _invokeMap('openAppSettings');
    return AndroidIntentResult.fromMap(value);
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    _requireAndroid();
    final value = await _channel.invokeMethod<Object?>(method, arguments);
    return _map(value);
  }

  void _requireAndroid() {
    if (!isSupported) {
      throw UnsupportedError('AndroidMediaBridge is available only on Android');
    }
  }
}

Map<Object?, Object?> _map(Object? value) {
  if (value is Map<Object?, Object?>) return value;
  if (value is Map) return Map<Object?, Object?>.from(value);
  throw const FormatException('Android returned an invalid map');
}

int? _integer(Object? value) => value is num ? value.toInt() : null;
