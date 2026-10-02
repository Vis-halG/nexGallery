import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'sha256.dart';

final class RemoteApiException implements Exception {
  const RemoteApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() => message;
}

final class RemoteRoot {
  const RemoteRoot({required this.id, required this.name});

  factory RemoteRoot.fromJson(Map<String, dynamic> json) => RemoteRoot(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? json['id'] as String? ?? '',
  );

  final String id;
  final String name;
}

final class RemoteEntry {
  const RemoteEntry({
    required this.root,
    required this.path,
    required this.name,
    required this.type,
    required this.modifiedAt,
    this.size,
  });

  factory RemoteEntry.fromJson(Map<String, dynamic> json) => RemoteEntry(
    root: json['root'] as String? ?? '',
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'file',
    modifiedAt: DateTime.tryParse(json['modifiedAt'] as String? ?? '')?.toUtc(),
    size: (json['size'] as num?)?.toInt(),
  );

  final String root;
  final String path;
  final String name;
  final String type;
  final DateTime? modifiedAt;
  final int? size;

  bool get isDirectory => type == 'directory';
}

/// Dependency-free client for the nexGallery PC server.
///
/// The bearer token is intentionally kept in memory here. The Android UI stores
/// it with the native Keystore bridge before restoring a connection.
final class NexGalleryRemoteClient {
  factory NexGalleryRemoteClient({required Uri baseUri, String? token}) =>
      NexGalleryRemoteClient._(_normalizeBase(baseUri), token);

  NexGalleryRemoteClient._(this.baseUri, this._token);

  final Uri baseUri;
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);
  String? _token;

  String? get token => _token;
  bool get isPaired => _token != null;

  Future<void> health() async {
    await _json('GET', '/v1/health', authenticate: false);
  }

  Future<String> pair({
    required String code,
    required String deviceName,
  }) async {
    final response = await _json(
      'POST',
      '/v1/pair',
      authenticate: false,
      body: <String, Object?>{'code': code, 'deviceName': deviceName},
    );
    final token = response['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const FormatException('The PC returned no device token.');
    }
    _token = token;
    return token;
  }

  Future<List<RemoteRoot>> roots() async {
    final response = await _json('GET', '/v1/roots');
    return _maps(response['roots']).map(RemoteRoot.fromJson).toList();
  }

  Future<List<RemoteEntry>> list({
    required String root,
    String path = '',
  }) async {
    final response = await _json(
      'GET',
      '/v1/list',
      query: <String, String>{'root': root, 'path': path},
    );
    return _maps(response['entries']).map(RemoteEntry.fromJson).toList();
  }

  Future<List<RemoteEntry>> search({
    required String root,
    required String query,
    String path = '',
    int limit = 100,
  }) async {
    final response = await _json(
      'GET',
      '/v1/search',
      query: <String, String>{
        'root': root,
        'path': path,
        'q': query,
        'limit': '${limit.clamp(1, 500)}',
      },
    );
    return _maps(response['results']).map(RemoteEntry.fromJson).toList();
  }

  Future<File> download({
    required RemoteEntry entry,
    required File destination,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (entry.isDirectory) {
      throw ArgumentError('A directory cannot be downloaded as one file.');
    }
    await destination.parent.create(recursive: true);
    final part = File('${destination.path}.part');
    var offset = await part.exists() ? await part.length() : 0;
    if (entry.size != null && offset > entry.size!) {
      await part.writeAsBytes(const <int>[], flush: true);
      offset = 0;
    }
    final request = await _open(
      'GET',
      '/v1/download',
      query: <String, String>{'root': entry.root, 'path': entry.path},
    );
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        offset > 0) {
      final remoteLength = _unsatisfiedRangeLength(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      await response.drain<void>();
      if (remoteLength == offset) {
        return _replaceFile(part, destination);
      }
      throw RemoteApiException(
        response.statusCode,
        'invalid_range',
        'The partial download cannot be resumed because the PC file changed.',
      );
    }
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw await _error(response);
    }
    if (offset > 0 && response.statusCode == HttpStatus.ok) {
      await part.writeAsBytes(const <int>[], flush: true);
      offset = 0;
    }
    int? expected;
    if (response.statusCode == HttpStatus.partialContent) {
      final range = _responseRange(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (range == null || range.start != offset) {
        await response.drain<void>();
        throw const RemoteApiException(
          502,
          'invalid_content_range',
          'The PC returned an invalid resume range.',
        );
      }
      if (response.contentLength >= 0 &&
          response.contentLength != range.end - range.start + 1) {
        await response.drain<void>();
        throw const RemoteApiException(
          502,
          'invalid_content_length',
          'The PC returned an invalid download length.',
        );
      }
      expected = range.total;
    } else {
      expected = response.contentLength >= 0
          ? response.contentLength
          : entry.size;
    }
    final sink = part.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    try {
      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, expected);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (expected != null && await part.length() != expected) {
      throw const FileSystemException(
        'The download ended before all bytes arrived.',
      );
    }
    return _replaceFile(part, destination);
  }

  Future<void> upload({
    required String root,
    required String remotePath,
    required File source,
    int chunkBytes = 4 * 1024 * 1024,
    bool verifyChecksum = true,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (chunkBytes <= 0) {
      throw RangeError.range(chunkBytes, 1, null, 'chunkBytes');
    }
    final total = await source.length();
    final checksum = verifyChecksum ? await Sha256.fileHex(source) : null;
    final uploadId = _uploadId();
    var offset = 0;
    final randomAccess = await source.open();
    try {
      while (offset < total || total == 0) {
        await randomAccess.setPosition(offset);
        final remaining = total - offset;
        final count = min(chunkBytes, remaining);
        final bytes = count == 0
            ? Uint8List(0)
            : await randomAccess.read(count);
        if (count > 0 && bytes.isEmpty) {
          throw const FileSystemException(
            'The source file ended before its reported size.',
          );
        }
        final complete = offset + bytes.length == total;
        final request = await _open(
          'PUT',
          '/v1/upload',
          query: <String, String>{'root': root, 'path': remotePath},
        );
        request.headers
          ..set('X-Upload-Id', uploadId)
          ..set('X-Upload-Offset', '$offset')
          ..set('X-Upload-Total', '$total')
          ..set('X-Upload-Complete', '$complete')
          ..contentLength = bytes.length;
        if (complete && checksum != null) {
          request.headers.set('X-Content-SHA256', checksum);
        }
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(minutes: 2),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw await _error(response);
        }
        final body = await _decodeJson(response);
        final expectedOffset = offset + bytes.length;
        final reportedOffset = (body['nextOffset'] as num?)?.toInt();
        if (reportedOffset != null && reportedOffset != expectedOffset) {
          throw const RemoteApiException(
            502,
            'invalid_upload_offset',
            'The PC returned an invalid upload offset.',
          );
        }
        offset = expectedOffset;
        onProgress?.call(offset, total);
        if (complete) break;
      }
    } finally {
      await randomAccess.close();
    }
  }

  Future<void> createFolder({
    required String root,
    required String path,
  }) async {
    await _json(
      'POST',
      '/v1/folders',
      body: <String, Object?>{'root': root, 'path': path},
    );
  }

  Future<void> move({
    required String root,
    required String sourcePath,
    required String destinationPath,
  }) async {
    await _json(
      'POST',
      '/v1/move',
      body: <String, Object?>{
        'root': root,
        'sourcePath': sourcePath,
        'destinationPath': destinationPath,
      },
    );
  }

  Future<String> trash(RemoteEntry entry) async {
    final response = await _json(
      'POST',
      '/v1/trash',
      body: <String, Object?>{'root': entry.root, 'path': entry.path},
    );
    return response['trashId'] as String? ?? '';
  }

  Future<void> restore({
    required String root,
    required String trashId,
    String? destinationPath,
  }) async {
    await _json(
      'POST',
      '/v1/trash/restore',
      body: <String, Object?>{
        'root': root,
        'trashId': trashId,
        'destinationPath': ?destinationPath,
      },
    );
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    bool authenticate = true,
  }) async {
    final request = await _open(
      method,
      path,
      query: query,
      authenticate: authenticate,
    );
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw await _error(response);
    }
    return _decodeJson(response);
  }

  Future<HttpClientRequest> _open(
    String method,
    String path, {
    Map<String, String>? query,
    bool authenticate = true,
  }) async {
    final uri = baseUri.replace(
      path: path,
      queryParameters: query?.isEmpty == true ? null : query,
    );
    final request = await _httpClient
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 15));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.userAgentHeader, 'nexGallery/0.2');
    if (authenticate) {
      final token = _token;
      if (token == null) {
        throw const RemoteApiException(
          401,
          'not_paired',
          'Pair with the PC first.',
        );
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    return request;
  }

  Future<RemoteApiException> _error(HttpClientResponse response) async {
    try {
      final body = await _decodeJson(response);
      final nested = body['error'];
      final error = nested is Map
          ? nested.map<String, dynamic>(
              (key, value) => MapEntry<String, dynamic>(key.toString(), value),
            )
          : body;
      return RemoteApiException(
        response.statusCode,
        error['code'] as String? ?? 'request_failed',
        error['message'] as String? ?? 'The PC rejected this request.',
      );
    } catch (_) {
      return RemoteApiException(
        response.statusCode,
        'request_failed',
        'The PC returned HTTP ${response.statusCode}.',
      );
    }
  }

  Future<Map<String, dynamic>> _decodeJson(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('The PC response is too large.');
      }
    }
    if (bytes.isEmpty) return <String, dynamic>{};
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('The PC returned invalid JSON.');
    }
    return value;
  }

  void close() => _httpClient.close(force: true);
}

Future<File> _replaceFile(File part, File destination) async {
  if (await destination.exists()) await destination.delete();
  return part.rename(destination.path);
}

_ResponseRange? _responseRange(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(value.trim());
  if (match == null) return null;
  final start = int.tryParse(match.group(1)!);
  final end = int.tryParse(match.group(2)!);
  final total = int.tryParse(match.group(3)!);
  if (start == null ||
      end == null ||
      total == null ||
      start < 0 ||
      end < start ||
      end >= total) {
    return null;
  }
  return _ResponseRange(start, end, total);
}

int? _unsatisfiedRangeLength(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^bytes \*/(\d+)$').firstMatch(value.trim());
  return match == null ? null : int.tryParse(match.group(1)!);
}

final class _ResponseRange {
  const _ResponseRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int total;
}

Uri _normalizeBase(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const FormatException(
      'Server address must start with http:// or https://.',
    );
  }
  if (uri.host.isEmpty || uri.hasFragment || uri.userInfo.isNotEmpty) {
    throw const FormatException('Server address is invalid.');
  }
  return uri.replace(path: '', query: null, fragment: null);
}

Iterable<Map<String, dynamic>> _maps(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is Map) {
      yield item.map<String, dynamic>(
        (key, value) => MapEntry<String, dynamic>(key.toString(), value),
      );
    }
  }
}

String _uploadId() {
  final random = Random.secure();
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${time}_$suffix';
}
