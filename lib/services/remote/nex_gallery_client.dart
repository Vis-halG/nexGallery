import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'request_signing.dart';
import 'sha256.dart';

final class RemoteApiException implements Exception {
  const RemoteApiException(
    this.statusCode,
    this.code,
    this.message, {
    this.details = const {},
  });

  final int statusCode;
  final String code;
  final String message;
  final Map<String, dynamic> details;

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
    this.version,
  });

  factory RemoteEntry.fromJson(Map<String, dynamic> json) => RemoteEntry(
    root: json['root'] as String? ?? '',
    path: json['path'] as String? ?? '',
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'file',
    modifiedAt: DateTime.tryParse(json['modifiedAt'] as String? ?? '')?.toUtc(),
    size: (json['size'] as num?)?.toInt(),
    version: json['version'] as String?,
  );

  final String root;
  final String path;
  final String name;
  final String type;
  final DateTime? modifiedAt;
  final int? size;

  /// The PC file version this listing saw; changes are refused when the
  /// file has changed since.
  final String? version;

  bool get isDirectory => type == 'directory';
}

/// Dependency-free client for the nexGallery PC server.
///
/// The bearer token is intentionally kept in memory here. The Android UI stores
/// it with the native Keystore bridge before restoring a connection.
/// How the PC accepted a finished upload.
final class UploadResult {
  const UploadResult({this.quarantined = false, this.scan});

  /// Programs, scripts, archives and macro documents wait outside the folder
  /// until the PC has scanned them.
  final bool quarantined;

  /// `scanning` (released automatically when clean) or `held` (waits for
  /// the PC owner).
  final String? scan;
}

/// A smaller copy of a video the PC is preparing.
final class ProxyProgress {
  const ProxyProgress({required this.status, this.progress = 0, this.error});

  /// `queued`, `preparing`, `ready` or `failed`.
  final String status;
  final double progress;
  final String? error;

  bool get ready => status == 'ready';
  bool get failed => status == 'failed';
}

/// A pairing request waiting for the PC owner's approval.
final class PairingTicket {
  const PairingTicket(this.requestId, this.pollSecret, this.expiresAt);
  final String requestId;
  final String pollSecret;
  final DateTime expiresAt;
}

final class RemoteInfo {
  const RemoteInfo({
    required this.name,
    required this.scopes,
    required this.macAddresses,
    required this.allowWrites,
    this.videoProxy = false,
  });

  factory RemoteInfo.fromJson(Map<String, dynamic> json) => RemoteInfo(
    name: json['name'] as String? ?? 'PC',
    scopes: (json['scopes'] as List? ?? const []).whereType<String>().toSet(),
    macAddresses: (json['macAddresses'] as List? ?? const [])
        .whereType<String>()
        .toList(),
    allowWrites: json['allowWrites'] == true,
    videoProxy:
        json['videoProxy'] is Map &&
        (json['videoProxy'] as Map)['available'] == true,
  );

  final String name;
  final Set<String> scopes;
  final List<String> macAddresses;
  final bool allowWrites;

  /// The PC can make smaller copies of videos for slow connections.
  final bool videoProxy;

  bool allows(String scope) => scopes.contains(scope);
}

final class NexGalleryRemoteClient {
  factory NexGalleryRemoteClient({
    required Uri baseUri,
    String? token,
    String? certificateFingerprint,
    DeviceKey? deviceKey,
    String? tokenId,
  }) {
    final normalized = _normalizeBase(baseUri);
    if (certificateFingerprint != null && normalized.scheme != 'https') {
      throw const FormatException('Certificate pinning requires HTTPS.');
    }
    return NexGalleryRemoteClient._(normalized, token, certificateFingerprint)
      ..deviceKey = deviceKey
      ..tokenId = tokenId;
  }

  NexGalleryRemoteClient._(this.baseUri, this._token, String? fingerprint)
    : _httpClient =
          HttpClient(
              context: fingerprint == null
                  ? null
                  : SecurityContext(withTrustedRoots: false),
            )
            ..connectionTimeout = const Duration(seconds: 15)
            ..idleTimeout = const Duration(seconds: 30) {
    final normalized = fingerprint
        ?.replaceAll(RegExp(r'[:\s]'), '')
        .toLowerCase();
    certificateFingerprint = normalized;
    if (normalized != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalized)) {
      _httpClient.close(force: true);
      throw const FormatException(
        'Enter the 64-character SHA-256 fingerprint shown on the PC.',
      );
    }
    _httpClient.badCertificateCallback = (cert, host, port) =>
        normalized != null &&
        host == baseUri.host &&
        port == baseUri.port &&
        constantTimeEquals(sha256Hex(cert.der), normalized);
  }

  final Uri baseUri;
  final HttpClient _httpClient;
  String? _token;
  String? certificateFingerprint;
  bool allowWrites = false;

  /// Signs every request once paired; sent to the PC during pairing.
  DeviceKey? deviceKey;
  String? tokenId;

  String? get token => _token;
  bool get isPaired => _token != null;

  Future<void> health() async {
    final response = await _json('GET', '/v1/health', authenticate: false);
    allowWrites = response['allowWrites'] == true;
  }

  /// Sends the one-time code. Returns null when the PC issued a token at
  /// once, otherwise a ticket to poll with [checkPairing].
  Future<PairingTicket?> startPairing({
    required String code,
    required String deviceName,
    bool signRequests = true,
  }) async {
    if (signRequests) deviceKey ??= await DeviceKey.generate();
    final response = await _json(
      'POST',
      '/v1/pair',
      authenticate: false,
      body: <String, Object?>{
        'code': code,
        'deviceName': deviceName,
        'publicKey': ?deviceKey?.publicKey,
      },
    );
    if (response['status'] == 'pending') {
      return PairingTicket(
        response['requestId'] as String,
        response['pollSecret'] as String,
        DateTime.tryParse(response['expiresAt'] as String? ?? '') ??
            DateTime.now().add(const Duration(minutes: 5)),
      );
    }
    _acceptToken(response);
    return null;
  }

  /// True once approved (the token is now set); false while still waiting.
  Future<bool> checkPairing(PairingTicket ticket) async {
    final response = await _json(
      'POST',
      '/v1/pair/status',
      authenticate: false,
      body: <String, Object?>{
        'requestId': ticket.requestId,
        'pollSecret': ticket.pollSecret,
      },
    );
    switch (response['status']) {
      case 'approved':
        _acceptToken(response);
        return true;
      case 'denied':
        throw const RemoteApiException(
          403,
          'pairing_denied',
          'The PC owner declined this phone.',
        );
      default:
        return false;
    }
  }

  /// Pairs and, when the PC requires it, waits for the owner's approval.
  Future<String> pair({
    required String code,
    required String deviceName,
    Duration pollInterval = const Duration(seconds: 2),
    bool Function()? cancelled,
  }) async {
    final ticket = await startPairing(code: code, deviceName: deviceName);
    if (ticket != null) {
      while (!await checkPairing(ticket)) {
        if (cancelled?.call() == true) {
          throw const RemoteApiException(
            499,
            'cancelled',
            'Pairing cancelled.',
          );
        }
        if (DateTime.now().isAfter(ticket.expiresAt)) {
          throw const RemoteApiException(
            408,
            'pairing_expired',
            'The PC owner did not approve in time. Pair again.',
          );
        }
        await Future<void>.delayed(pollInterval);
      }
    }
    return _token!;
  }

  void _acceptToken(Map<String, dynamic> response) {
    final token = response['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const FormatException('The PC returned no device token.');
    }
    final device = response['device'];
    tokenId = device is Map ? device['tokenId'] as String? : null;
    _token = token;
  }

  Future<RemoteInfo> info() async =>
      RemoteInfo.fromJson(await _json('GET', '/v1/info'));

  /// Tells the PC to forget this phone.
  Future<void> revokeSelf() async {
    await _json('POST', '/v1/tokens/revoke', body: <String, Object?>{});
  }

  /// A JPEG preview of a PC photo, at most [size] pixels on its longer side.
  Future<Uint8List> thumbnail(RemoteEntry entry, {int size = 256}) async {
    final request = await _open(
      'GET',
      '/v1/thumbnail',
      query: {'root': entry.root, 'path': entry.path, 'size': '$size'},
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) throw await _error(response);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const FormatException('The preview is too large.');
      }
    }
    return bytes.takeBytes();
  }

  Future<List<RemoteRoot>> roots() async {
    final response = await _json('GET', '/v1/roots');
    return _maps(response['roots']).map(RemoteRoot.fromJson).toList();
  }

  Future<List<RemoteEntry>> list({
    required String root,
    String path = '',
    int offset = 0,
    int? limit,
  }) async {
    final response = await _json(
      'GET',
      '/v1/list',
      query: <String, String>{
        'root': root,
        'path': path,
        if (offset > 0) 'offset': '$offset',
        if (limit != null) 'limit': '$limit',
      },
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
      headers: <String, String>{
        if (offset > 0) 'range': 'bytes=$offset-',
        if (entry.version != null)
          'x-nex-file-version': entry.version!
        else if (entry.size != null && entry.modifiedAt != null)
          'x-nex-file-version':
              '${entry.size}:${entry.modifiedAt!.toUtc().microsecondsSinceEpoch}',
      },
    );
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

  Future<UploadResult> upload({
    required String root,
    required String remotePath,
    required File source,
    int chunkBytes = 4 * 1024 * 1024,
    bool verifyChecksum = true,
    File? resumeState,
    bool createParents = false,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (chunkBytes <= 0) {
      throw RangeError.range(chunkBytes, 1, null, 'chunkBytes');
    }
    final total = await source.length();
    final checksum = verifyChecksum ? await Sha256.fileHex(source) : null;
    var uploadId = _uploadId();
    var offset = 0;
    final signature =
        '${baseUri.toString()}:$root:$remotePath:$total:$checksum';
    if (resumeState != null && await resumeState.exists()) {
      if (await resumeState.length() > 4096) {
        throw const FormatException('Invalid upload resume state.');
      }
      final state =
          jsonDecode(await resumeState.readAsString()) as Map<String, dynamic>;
      if (state['signature'] == signature &&
          RegExp(r'^[a-zA-Z0-9_-]{8,80}$')
              .hasMatch(state['uploadId'] as String? ?? '')) {
        uploadId = state['uploadId'] as String;
        offset = state['offset'] as int;
        if (offset < 0 || offset > total) {
          throw const FormatException('Invalid upload offset.');
        }
      }
    }
    Future<void> checkpoint() async {
      if (resumeState != null) {
        await resumeState.parent.create(recursive: true);
        await resumeState.writeAsString(
          jsonEncode({
            'signature': signature,
            'uploadId': uploadId,
            'offset': offset,
          }),
          flush: true,
        );
      }
    }

    await checkpoint();
    final randomAccess = await source.open();
    var reconciliations = 0;
    var result = const UploadResult();
    try {
      while (offset <= total) {
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
          headers: <String, String>{
            'x-upload-id': uploadId,
            'x-upload-offset': '$offset',
            'x-upload-total': '$total',
            'x-upload-complete': '$complete',
            if (createParents && offset == 0) 'x-upload-create-parents': 'true',
            if (complete && checksum != null) 'x-content-sha256': checksum,
          },
        );
        request.headers.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(minutes: 2),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final error = await _error(response);
          final expected = error.details['expectedOffset'];
          if (error.code == 'offset_mismatch' &&
              expected is int &&
              expected >= 0 &&
              expected <= total &&
              expected != offset &&
              reconciliations++ < 3) {
            offset = expected;
            await checkpoint();
            continue;
          }
          throw error;
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
        if (!complete) await checkpoint();
        onProgress?.call(offset, total);
        if (complete) {
          result = UploadResult(
            quarantined: body['quarantined'] == true,
            scan: body['scan'] as String?,
          );
          break;
        }
      }
      if (resumeState != null && await resumeState.exists()) {
        await resumeState.delete();
      }
    } finally {
      await randomAccess.close();
    }
    return result;
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
    String? version,
  }) async {
    await _json(
      'POST',
      '/v1/move',
      body: <String, Object?>{
        'root': root,
        'sourcePath': sourcePath,
        'destinationPath': destinationPath,
        'version': ?version,
      },
    );
  }

  Future<String> trash(RemoteEntry entry) async {
    final response = await _json(
      'POST',
      '/v1/trash',
      body: <String, Object?>{
        'root': entry.root,
        'path': entry.path,
        'version': ?entry.version,
      },
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
    final bytes = body == null ? null : utf8.encode(jsonEncode(body));
    final request = await _open(
      method,
      path,
      query: query,
      authenticate: authenticate,
      headers: {
        if (bytes != null) SignedHeaders.bodyHashHeader: sha256Hex(bytes),
      },
    );
    if (bytes != null) {
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

  /// Opens a request. Authenticated requests carry the bearer token and,
  /// once the device has a key, an Ed25519 signature over the method, path,
  /// query, time, a one-time nonce and every header in [headers].
  Future<HttpClientRequest> _open(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    bool authenticate = true,
  }) async {
    final uri = baseUri.replace(
      path: path,
      queryParameters: query?.isEmpty == true ? null : query,
    );
    final request = await _httpClient
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.userAgentHeader, 'nexGallery/0.3');
    headers.forEach(request.headers.set);
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
      final key = deviceKey, tokenId = this.tokenId;
      if (key != null && tokenId != null) {
        final timestamp = '${DateTime.now().toUtc().millisecondsSinceEpoch}';
        final nonce = randomNonce();
        final lower = {
          for (final entry in headers.entries)
            entry.key.toLowerCase(): entry.value,
        };
        final signature = await key.sign(
          canonicalRequest(
            method: method,
            path: uri.path,
            query: uri.query,
            timestamp: timestamp,
            nonce: nonce,
            tokenId: tokenId,
            header: (name) => lower[name],
          ),
        );
        request.headers
          ..set(SignedHeaders.device, tokenId)
          ..set(SignedHeaders.timestamp, timestamp)
          ..set(SignedHeaders.nonce, nonce)
          ..set(SignedHeaders.signature, signature);
      }
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
        details: error['details'] is Map
            ? Map<String, dynamic>.from(error['details'] as Map)
            : const {},
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

  Uri streamUri(RemoteEntry entry) => baseUri.replace(
    path: '/v1/download',
    queryParameters: {'root': entry.root, 'path': entry.path},
  );

  /// Streams the original, or with [quality] the PC's smaller copy once
  /// [proxyStatus] reports it ready.
  Future<HttpClientResponse> readStream(
    RemoteEntry entry, {
    String? range,
    String method = 'GET',
    int? quality,
  }) async {
    final request = await _open(
      method,
      quality == null ? '/v1/download' : '/v1/proxy',
      query: {
        'root': entry.root,
        'path': entry.path,
        if (quality != null) 'quality': '$quality',
      },
      headers: {'range': ?range},
    );
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200 &&
        response.statusCode != 206 &&
        response.statusCode != 416) {
      throw await _error(response);
    }
    return response;
  }

  /// Asks the PC to prepare a [quality]p copy of a video; repeat until
  /// [ProxyProgress.ready].
  Future<ProxyProgress> proxyStatus(RemoteEntry entry, int quality) async {
    final value = await _json(
      'GET',
      '/v1/proxy/status',
      query: {'root': entry.root, 'path': entry.path, 'quality': '$quality'},
    );
    return ProxyProgress(
      status: value['status'] as String? ?? 'failed',
      progress: (value['progress'] as num?)?.toDouble() ?? 0,
      error: value['error'] as String?,
    );
  }

  Future<List<Map<String, dynamic>>> trashEntries(String root) async =>
      _maps((await _json('GET', '/v1/trash', query: {'root': root}))['items'])
          .toList();
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
