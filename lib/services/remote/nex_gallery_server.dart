import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'path_guard.dart';
import 'security.dart';
import 'sha256.dart';

final class RemoteServerConfig {
  const RemoteServerConfig({
    required this.allowedRoots,
    required this.dataDirectory,
    this.port = 8732,
    this.listenOnLan = false,
    this.maxJsonBytes = 1024 * 1024,
    this.maxUploadChunkBytes = 8 * 1024 * 1024,
    this.maxUploadFileBytes = 20 * 1024 * 1024 * 1024,
    this.maxSearchEntries = 50000,
    this.requestsPerMinute = 240,
    this.pairAttemptsPerMinute = 10,
    this.pairingLifetime = const Duration(minutes: 5),
  });

  final Map<String, String> allowedRoots;
  final Directory dataDirectory;
  final int port;
  final bool listenOnLan;
  final int maxJsonBytes;
  final int maxUploadChunkBytes;
  final int maxUploadFileBytes;
  final int maxSearchEntries;
  final int requestsPerMinute;
  final int pairAttemptsPerMinute;
  final Duration pairingLifetime;
}

final class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}

/// Local-first HTTP server used by the Windows companion.
///
/// It binds to loopback unless [RemoteServerConfig.listenOnLan] is explicitly
/// enabled. The transport is plain HTTP: callers must not expose this port
/// directly to the public internet. Remote access requires a separately
/// configured encrypted private network or a future TLS transport layer.
final class NexGalleryServer {
  NexGalleryServer._({
    required this.config,
    required this._pathGuard,
    required this._tokenStore,
    required this._auditLog,
  }) : _requestLimiter = FixedWindowRateLimiter(
         limit: config.requestsPerMinute,
         window: const Duration(minutes: 1),
       ),
       _pairLimiter = FixedWindowRateLimiter(
         limit: config.pairAttemptsPerMinute,
         window: const Duration(minutes: 1),
       );

  final RemoteServerConfig config;
  final PathGuard _pathGuard;
  final DeviceTokenStore _tokenStore;
  final AuditLog _auditLog;
  final FixedWindowRateLimiter _requestLimiter;
  final FixedWindowRateLimiter _pairLimiter;
  final _KeyedLock _uploadLocks = _KeyedLock();
  final Random _random = Random.secure();
  final Map<String, DateTime> _pairingHashes = <String, DateTime>{};
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  static Future<NexGalleryServer> create(RemoteServerConfig config) async {
    if (config.port < 0 || config.port > 65535) {
      throw ArgumentError.value(config.port, 'port');
    }
    if (config.maxJsonBytes <= 0 ||
        config.maxUploadChunkBytes <= 0 ||
        config.maxUploadFileBytes <= 0 ||
        config.maxSearchEntries <= 0 ||
        config.requestsPerMinute <= 0 ||
        config.pairAttemptsPerMinute <= 0 ||
        config.pairingLifetime <= Duration.zero) {
      throw ArgumentError('Server limits and durations must be positive.');
    }
    await config.dataDirectory.create(recursive: true);
    final guard = await PathGuard.create(config.allowedRoots);
    final canonicalDataDirectory = await config.dataDirectory
        .resolveSymbolicLinks();
    if (guard.containsAbsolutePath(canonicalDataDirectory)) {
      throw ArgumentError(
        'The private server data directory must be outside every allowed root.',
      );
    }
    final tokenStore = DeviceTokenStore(
      File('${config.dataDirectory.path}${Platform.pathSeparator}tokens.json'),
    );
    await tokenStore.load();
    return NexGalleryServer._(
      config: config,
      pathGuard: guard,
      tokenStore: tokenStore,
      auditLog: AuditLog(
        File(
          '${config.dataDirectory.path}${Platform.pathSeparator}audit.jsonl',
        ),
      ),
    );
  }

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  InternetAddress? get boundAddress => _server?.address;

  Future<void> start() async {
    if (_server != null) {
      throw StateError('Server is already running.');
    }
    // LAN binding is opt-in because this implementation does not terminate TLS.
    final address = config.listenOnLan
        ? InternetAddress.anyIPv4
        : InternetAddress.loopbackIPv4;
    final server = await HttpServer.bind(address, config.port, shared: false);
    _server = server;
    _subscription = server.listen(
      _handle,
      onError: (Object error, StackTrace stackTrace) {
        stderr.writeln('nexGallery server request error: $error');
      },
    );
    try {
      await _auditLog.record(
        action: 'server.start',
        outcome: 'success',
        details: <String, Object?>{
          'bind': address.address,
          'port': server.port,
          'lan': config.listenOnLan,
          'tls': false,
        },
      );
    } catch (_) {
      _server = null;
      final subscription = _subscription;
      _subscription = null;
      await subscription?.cancel();
      await server.close(force: true);
      rethrow;
    }
  }

  Future<void> stop({bool force = false}) async {
    final server = _server;
    if (server == null) {
      return;
    }
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    await server.close(force: force);
    await _auditLog.record(action: 'server.stop', outcome: 'success');
  }

  /// Creates a short-lived code suitable for displaying as text or encoding in
  /// a QR payload. The code is consumed after one successful pairing.
  PairingCode createPairingCode() {
    final now = DateTime.now().toUtc();
    _pairingHashes.removeWhere((_, expiresAt) => !expiresAt.isAfter(now));
    final code = List<String>.generate(
      8,
      (_) => _random.nextInt(10).toString(),
    ).join();
    final expiresAt = now.add(config.pairingLifetime);
    _pairingHashes[sha256Hex(utf8.encode(code))] = expiresAt;
    return PairingCode(code: code, expiresAt: expiresAt);
  }

  Future<void> _handle(HttpRequest request) async {
    _applyHeaders(request.response);
    final remoteAddress =
        request.connectionInfo?.remoteAddress.address ?? 'unknown';
    final route = '${request.method} ${request.uri.path}';
    DeviceIdentity? identity;
    try {
      if (!_requestLimiter.allow(remoteAddress)) {
        throw const _ApiException(429, 'rate_limited', 'Too many requests.');
      }
      if (request.uri.path == '/v1/health' && request.method == 'GET') {
        await _json(request.response, 200, <String, Object?>{
          'status': 'ok',
          'service': 'nexGallery PC server',
          'version': 1,
          'tls': false,
          'lanEnabled': config.listenOnLan,
        });
        return;
      }
      if (request.uri.path == '/v1/pair/code' && request.method == 'POST') {
        if (!_isLoopback(request.connectionInfo?.remoteAddress)) {
          throw const _ApiException(
            403,
            'local_only',
            'Pairing codes can only be created from this PC.',
          );
        }
        final code = createPairingCode();
        await _auditLog.record(
          action: 'pair.code.create',
          outcome: 'success',
          remoteAddress: remoteAddress,
        );
        await _json(request.response, 201, code.toJson());
        return;
      }
      if (request.uri.path == '/v1/pair' && request.method == 'POST') {
        if (!_pairLimiter.allow(remoteAddress)) {
          throw const _ApiException(
            429,
            'pair_rate_limited',
            'Too many pairing attempts.',
          );
        }
        await _handlePair(request, remoteAddress);
        return;
      }

      identity = await _authenticate(request);
      if (!_requestLimiter.allow('${identity.id}:authenticated')) {
        throw const _ApiException(429, 'rate_limited', 'Too many requests.');
      }

      switch (route) {
        case 'GET /v1/roots':
          await _json(request.response, 200, <String, Object?>{
            'roots': _pathGuard.roots.values
                .map((root) => root.toJson())
                .toList(growable: false),
          });
        case 'GET /v1/list':
          await _handleList(request, identity);
        case 'GET /v1/search':
          await _handleSearch(request, identity);
        case 'GET /v1/download':
        case 'HEAD /v1/download':
          await _handleDownload(request, identity);
        case 'GET /v1/thumbnail':
          throw const _ApiException(
            501,
            'thumbnail_not_supported',
            'Thumbnail generation is not available in this server core.',
          );
        case 'PUT /v1/upload':
          await _handleUpload(request, identity);
        case 'POST /v1/folders':
          await _handleCreateFolder(request, identity);
        case 'POST /v1/move':
          await _handleMove(request, identity);
        case 'POST /v1/trash':
          await _handleTrash(request, identity);
        case 'GET /v1/trash':
          await _handleTrashList(request, identity);
        case 'POST /v1/trash/restore':
          await _handleRestore(request, identity);
        case 'GET /v1/tokens':
          await _json(request.response, 200, <String, Object?>{
            'devices': _tokenStore
                .list()
                .map((device) => device.toPublicJson())
                .toList(growable: false),
          });
        case 'POST /v1/tokens/revoke':
          await _handleRevoke(request, identity);
        default:
          throw const _ApiException(
            404,
            'not_found',
            'Endpoint was not found.',
          );
      }
    } on _ApiException catch (error) {
      await _safeAudit(
        action: route,
        outcome: 'rejected',
        identity: identity,
        remoteAddress: remoteAddress,
        details: <String, Object?>{'code': error.code},
      );
      await _jsonError(request.response, error);
    } on RemotePathException catch (error) {
      await _safeAudit(
        action: route,
        outcome: 'rejected',
        identity: identity,
        remoteAddress: remoteAddress,
        details: <String, Object?>{'code': 'invalid_path'},
      );
      await _jsonError(
        request.response,
        _ApiException(error.statusCode, 'invalid_path', error.message),
      );
    } on FormatException catch (error) {
      await _jsonError(
        request.response,
        _ApiException(400, 'invalid_request', error.message),
      );
    } on FileSystemException catch (error) {
      await _safeAudit(
        action: route,
        outcome: 'failed',
        identity: identity,
        remoteAddress: remoteAddress,
        details: <String, Object?>{'code': 'filesystem_error'},
      );
      await _jsonError(
        request.response,
        _ApiException(
          409,
          'filesystem_error',
          error.osError?.message ?? 'File operation failed.',
        ),
      );
    } catch (error, stackTrace) {
      stderr.writeln('Unhandled request failure: $error\n$stackTrace');
      await _safeAudit(
        action: route,
        outcome: 'failed',
        identity: identity,
        remoteAddress: remoteAddress,
        details: <String, Object?>{'code': 'internal_error'},
      );
      await _jsonError(
        request.response,
        const _ApiException(500, 'internal_error', 'Request failed.'),
      );
    }
  }

  Future<void> _handlePair(HttpRequest request, String remoteAddress) async {
    final body = await _readJson(request);
    final code = _requiredString(body, 'code', maxLength: 32);
    final deviceName = _requiredString(body, 'deviceName', maxLength: 80);
    final digest = sha256Hex(utf8.encode(code));
    final expiresAt = _pairingHashes[digest];
    final now = DateTime.now().toUtc();
    if (expiresAt == null || !expiresAt.isAfter(now)) {
      _pairingHashes.remove(digest);
      await _auditLog.record(
        action: 'pair.complete',
        outcome: 'rejected',
        remoteAddress: remoteAddress,
      );
      throw const _ApiException(
        401,
        'invalid_pairing_code',
        'Pairing code is invalid or expired.',
      );
    }
    _pairingHashes.remove(digest);
    final issued = await _tokenStore.issue(deviceName);
    await _auditLog.record(
      action: 'pair.complete',
      outcome: 'success',
      deviceId: issued.identity.id,
      remoteAddress: remoteAddress,
    );
    await _json(request.response, 201, <String, Object?>{
      'token': issued.token,
      'tokenType': 'Bearer',
      'device': issued.identity.toPublicJson(),
    });
  }

  Future<DeviceIdentity> _authenticate(HttpRequest request) async {
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final bearer = authorization == null
        ? null
        : RegExp(
            r'^Bearer[ \t]+(.+)$',
            caseSensitive: false,
          ).firstMatch(authorization);
    if (bearer == null) {
      throw const _ApiException(
        401,
        'authentication_required',
        'A bearer token is required.',
      );
    }
    final identity = await _tokenStore.authenticate(bearer.group(1)!.trim());
    if (identity == null) {
      throw const _ApiException(
        401,
        'invalid_token',
        'Bearer token is invalid.',
      );
    }
    return identity;
  }

  Future<void> _handleList(HttpRequest request, DeviceIdentity identity) async {
    final rootId = _requiredQuery(request, 'root');
    final relativePath = request.uri.queryParameters['path'] ?? '';
    final absolutePath = await _pathGuard.resolve(rootId, relativePath);
    final directory = Directory(absolutePath);
    if (!await directory.exists()) {
      throw const _ApiException(
        400,
        'not_a_directory',
        'Path is not a directory.',
      );
    }
    final entries = <Map<String, Object?>>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = _basename(entity.path);
      if (_isHiddenServerEntry(name)) {
        continue;
      }
      final childRelative = _combineRelative(relativePath, name);
      try {
        await _pathGuard.resolve(rootId, childRelative);
        entries.add(await _metadata(rootId, childRelative, entity));
      } on RemotePathException {
        // Links that resolve outside the configured root are intentionally hidden.
      }
      if (entries.length >= 5000) {
        break;
      }
    }
    entries.sort((left, right) {
      final typeOrder =
          (left['type'] == 'directory' ? 0 : 1) -
          (right['type'] == 'directory' ? 0 : 1);
      if (typeOrder != 0) return typeOrder;
      return (left['name'] as String).toLowerCase().compareTo(
        (right['name'] as String).toLowerCase(),
      );
    });
    await _safeAudit(
      action: 'files.list',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{'count': entries.length},
    );
    await _json(request.response, 200, <String, Object?>{
      'root': rootId,
      'path': _normalizedRelative(relativePath),
      'entries': entries,
      'truncated': entries.length >= 5000,
    });
  }

  Future<void> _handleSearch(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final rootId = _requiredQuery(request, 'root');
    final relativePath = request.uri.queryParameters['path'] ?? '';
    final query = _requiredQuery(request, 'q').trim().toLowerCase();
    if (query.length > 200) {
      throw const _ApiException(
        400,
        'invalid_query',
        'Search query is too long.',
      );
    }
    final requestedLimit =
        int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 100;
    final limit = requestedLimit.clamp(1, 500);
    final start = await _pathGuard.resolve(rootId, relativePath);
    if (!await Directory(start).exists()) {
      throw const _ApiException(
        400,
        'not_a_directory',
        'Search path is not a directory.',
      );
    }
    final results = <Map<String, Object?>>[];
    var scanned = 0;
    final pending = <Directory>[Directory(start)];
    while (pending.isNotEmpty &&
        results.length < limit &&
        scanned < config.maxSearchEntries) {
      final directory = pending.removeLast();
      await for (final entity in directory.list(followLinks: false)) {
        scanned += 1;
        final name = _basename(entity.path);
        if (_isHiddenServerEntry(name)) {
          continue;
        }
        final childRelative = _pathGuard.relative(rootId, entity.path);
        try {
          await _pathGuard.resolve(rootId, childRelative);
        } on RemotePathException {
          continue;
        }
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          pending.add(Directory(entity.path));
        }
        if (name.toLowerCase().contains(query)) {
          results.add(await _metadata(rootId, childRelative, entity));
          if (results.length >= limit) break;
        }
        if (scanned >= config.maxSearchEntries) break;
      }
    }
    await _safeAudit(
      action: 'files.search',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{
        'resultCount': results.length,
        'scanned': scanned,
      },
    );
    await _json(request.response, 200, <String, Object?>{
      'results': results,
      'scanned': scanned,
      'truncated':
          scanned >= config.maxSearchEntries || results.length >= limit,
    });
  }

  Future<void> _handleDownload(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final rootId = _requiredQuery(request, 'root');
    final relativePath = _requiredQuery(request, 'path');
    final absolutePath = await _pathGuard.resolve(
      rootId,
      relativePath,
      allowRoot: false,
    );
    final file = File(absolutePath);
    if (!await file.exists()) {
      throw const _ApiException(400, 'not_a_file', 'Path is not a file.');
    }
    final length = await file.length();
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      length,
    );
    final start = range?.start ?? 0;
    final end = range?.end ?? (length - 1);
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, _contentType(relativePath))
      ..set(
        'Content-Disposition',
        'inline; filename*=UTF-8\'\'${Uri.encodeComponent(_basename(relativePath))}',
      );
    if (range != null) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    } else {
      request.response.statusCode = HttpStatus.ok;
    }
    final responseLength = length == 0 ? 0 : end - start + 1;
    request.response.contentLength = responseLength;
    await _safeAudit(
      action: 'files.download',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{'start': start, 'end': end, 'size': length},
    );
    if (request.method != 'HEAD' && responseLength > 0) {
      await request.response.addStream(file.openRead(start, end + 1));
    }
    await request.response.close();
  }

  Future<void> _handleUpload(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final rootId = _requiredQuery(request, 'root');
    final relativePath = _requiredQuery(request, 'path');
    final uploadId = request.headers.value('x-upload-id') ?? '';
    if (!RegExp(r'^[a-zA-Z0-9_-]{8,80}$').hasMatch(uploadId)) {
      throw const _ApiException(
        400,
        'invalid_upload_id',
        'X-Upload-Id must contain 8-80 safe characters.',
      );
    }
    final offset = _requiredIntegerHeader(request, 'x-upload-offset', min: 0);
    final total = _requiredIntegerHeader(
      request,
      'x-upload-total',
      min: 0,
      max: config.maxUploadFileBytes,
    );
    final completeHeader = request.headers
        .value('x-upload-complete')
        ?.toLowerCase();
    if (completeHeader != 'true' && completeHeader != 'false') {
      throw const _ApiException(
        400,
        'invalid_header',
        'X-Upload-Complete must be true or false.',
      );
    }
    final complete = completeHeader == 'true';
    final declaredChunk = request.contentLength;
    if (declaredChunk > config.maxUploadChunkBytes) {
      throw const _ApiException(
        413,
        'chunk_too_large',
        'Upload chunk is too large.',
      );
    }
    if (offset > total) {
      throw const _ApiException(
        400,
        'invalid_offset',
        'Upload offset exceeds total.',
      );
    }

    final uploadLockKey = '$rootId:${_normalizedRelative(relativePath)}';
    await _uploadLocks.run(
      Platform.isWindows ? uploadLockKey.toLowerCase() : uploadLockKey,
      () async {
        final target = await _pathGuard.resolve(
          rootId,
          relativePath,
          mustExist: false,
          allowRoot: false,
        );
        final parent = File(target).parent;
        if (!await parent.exists()) {
          throw const _ApiException(
            409,
            'parent_not_found',
            'Destination folder does not exist.',
          );
        }
        await _pathGuard.resolve(
          rootId,
          _pathGuard.relative(rootId, parent.path),
        );
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const _ApiException(
            409,
            'destination_exists',
            'Destination already exists.',
          );
        }
        // Including the declared total in the private part name prevents a
        // later chunk from silently changing the transfer's expected size.
        final partRelative = '$relativePath.$uploadId.$total.part';
        final partPath = await _pathGuard.resolve(
          rootId,
          partRelative,
          mustExist: false,
          allowRoot: false,
        );
        final part = File(partPath);
        final currentLength = await part.exists() ? await part.length() : 0;
        if (currentLength != offset) {
          throw _ApiException(
            409,
            'offset_mismatch',
            'Expected upload offset $currentLength.',
            details: <String, Object?>{'expectedOffset': currentLength},
          );
        }

        var received = 0;
        try {
          final output = await part.open(mode: FileMode.append);
          try {
            await for (final chunk in request) {
              received += chunk.length;
              if (received > config.maxUploadChunkBytes ||
                  offset + received > total ||
                  offset + received > config.maxUploadFileBytes) {
                throw const _ApiException(
                  413,
                  'upload_limit_exceeded',
                  'Upload exceeds the configured limit.',
                );
              }
              await output.writeFrom(chunk);
            }
            if (declaredChunk >= 0 && received != declaredChunk) {
              throw const _ApiException(
                400,
                'incomplete_chunk',
                'Upload chunk ended before Content-Length bytes arrived.',
              );
            }
            await output.flush();
          } finally {
            await output.close();
          }
        } catch (error, stackTrace) {
          try {
            final rollback = await part.open(mode: FileMode.append);
            try {
              await rollback.truncate(offset);
              await rollback.flush();
            } finally {
              await rollback.close();
            }
          } catch (rollbackError) {
            stderr.writeln(
              'Could not roll upload back to offset $offset: $rollbackError',
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
        final nextOffset = offset + received;
        if (complete && nextOffset != total) {
          throw _ApiException(
            409,
            'incomplete_upload',
            'Final size does not match X-Upload-Total.',
            details: <String, Object?>{'nextOffset': nextOffset},
          );
        }
        if (!complete) {
          await _safeAudit(
            action: 'files.upload.chunk',
            outcome: 'success',
            identity: identity,
            rootId: rootId,
            relativePath: relativePath,
            details: <String, Object?>{
              'nextOffset': nextOffset,
              'total': total,
            },
          );
          await _json(request.response, 202, <String, Object?>{
            'uploadId': uploadId,
            'nextOffset': nextOffset,
            'total': total,
            'complete': false,
          });
          return;
        }

        final expectedHash = request.headers
            .value('x-content-sha256')
            ?.toLowerCase();
        String? actualHash;
        if (expectedHash != null) {
          if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHash)) {
            throw const _ApiException(
              400,
              'invalid_checksum',
              'X-Content-SHA256 must be 64 hexadecimal characters.',
            );
          }
          actualHash = await Sha256.fileHex(part);
          if (!constantTimeEquals(expectedHash, actualHash)) {
            await part.delete();
            throw const _ApiException(
              422,
              'checksum_mismatch',
              'Uploaded file checksum did not match.',
            );
          }
        }
        // The part file is beside its destination, so rename is an atomic finalize
        // on the supported local filesystems when the destination does not exist.
        await part.rename(target);
        await _safeAudit(
          action: 'files.upload.complete',
          outcome: 'success',
          identity: identity,
          rootId: rootId,
          relativePath: relativePath,
          details: <String, Object?>{'size': nextOffset, 'sha256': ?actualHash},
        );
        await _json(request.response, 201, <String, Object?>{
          'uploadId': uploadId,
          'path': _normalizedRelative(relativePath),
          'size': nextOffset,
          'complete': true,
          'sha256': ?actualHash,
        });
      },
    );
  }

  Future<void> _handleCreateFolder(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final body = await _readJson(request);
    final rootId = _requiredString(body, 'root', maxLength: 40);
    final relativePath = _requiredString(body, 'path', maxLength: 4096);
    final target = await _pathGuard.resolve(
      rootId,
      relativePath,
      mustExist: false,
      allowRoot: false,
    );
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _ApiException(
        409,
        'destination_exists',
        'Path already exists.',
      );
    }
    final parent = Directory(target).parent;
    if (!await parent.exists()) {
      throw const _ApiException(
        409,
        'parent_not_found',
        'Parent folder is missing.',
      );
    }
    await Directory(target).create();
    await _safeAudit(
      action: 'folders.create',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
    );
    await _json(request.response, 201, <String, Object?>{
      'root': rootId,
      'path': _normalizedRelative(relativePath),
    });
  }

  Future<void> _handleMove(HttpRequest request, DeviceIdentity identity) async {
    final body = await _readJson(request);
    final rootId = _requiredString(body, 'root', maxLength: 40);
    final sourcePath = _requiredString(body, 'sourcePath', maxLength: 4096);
    final destinationPath = _requiredString(
      body,
      'destinationPath',
      maxLength: 4096,
    );
    final source = await _pathGuard.resolve(
      rootId,
      sourcePath,
      allowRoot: false,
    );
    final destination = await _pathGuard.resolve(
      rootId,
      destinationPath,
      mustExist: false,
      allowRoot: false,
    );
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _ApiException(
        409,
        'destination_exists',
        'Destination exists.',
      );
    }
    if (!await File(destination).parent.exists()) {
      throw const _ApiException(
        409,
        'parent_not_found',
        'Destination folder is missing.',
      );
    }
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(destination);
    } else if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(source).rename(destination);
    } else {
      throw const _ApiException(404, 'not_found', 'Source was not found.');
    }
    await _safeAudit(
      action: 'files.move',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: sourcePath,
      details: <String, Object?>{'destinationPath': destinationPath},
    );
    await _json(request.response, 200, <String, Object?>{
      'root': rootId,
      'sourcePath': _normalizedRelative(sourcePath),
      'destinationPath': _normalizedRelative(destinationPath),
    });
  }

  Future<void> _handleTrash(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final body = await _readJson(request);
    final rootId = _requiredString(body, 'root', maxLength: 40);
    final relativePath = _requiredString(body, 'path', maxLength: 4096);
    final source = await _pathGuard.resolve(
      rootId,
      relativePath,
      allowRoot: false,
    );
    final trashDirectory = await _trashDirectory(rootId);
    final trashId =
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-${_random.nextInt(1 << 32).toRadixString(16)}';
    final payloadPath =
        '${trashDirectory.path}${Platform.pathSeparator}$trashId.payload';
    final metadataPath =
        '${trashDirectory.path}${Platform.pathSeparator}$trashId.json';
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(payloadPath);
    } else if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(source).rename(payloadPath);
    } else {
      throw const _ApiException(404, 'not_found', 'Path was not found.');
    }
    try {
      await File(metadataPath).writeAsString(
        jsonEncode(<String, Object?>{
          'version': 1,
          'trashId': trashId,
          'originalPath': _normalizedRelative(relativePath),
          'deletedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      if (type == FileSystemEntityType.directory) {
        await Directory(payloadPath).rename(source);
      } else {
        await File(payloadPath).rename(source);
      }
      rethrow;
    }
    await _safeAudit(
      action: 'trash.move',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{'trashId': trashId},
    );
    await _json(request.response, 200, <String, Object?>{
      'trashId': trashId,
      'originalPath': _normalizedRelative(relativePath),
      'recoverable': true,
    });
  }

  Future<void> _handleRestore(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final body = await _readJson(request);
    final rootId = _requiredString(body, 'root', maxLength: 40);
    final trashId = _requiredString(body, 'trashId', maxLength: 80);
    if (!RegExp(r'^[0-9]+-[0-9a-f]+$').hasMatch(trashId)) {
      throw const _ApiException(
        400,
        'invalid_trash_id',
        'Trash id is invalid.',
      );
    }
    final trashDirectory = await _trashDirectory(rootId);
    final metadata = File(
      '${trashDirectory.path}${Platform.pathSeparator}$trashId.json',
    );
    final payloadPath =
        '${trashDirectory.path}${Platform.pathSeparator}$trashId.payload';
    if (!await metadata.exists() ||
        await FileSystemEntity.type(payloadPath, followLinks: false) ==
            FileSystemEntityType.notFound) {
      throw const _ApiException(
        404,
        'trash_not_found',
        'Trash item was not found.',
      );
    }
    final decoded = jsonDecode(await metadata.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['originalPath'] is! String) {
      throw const _ApiException(
        409,
        'trash_metadata_invalid',
        'Trash metadata is invalid.',
      );
    }
    final destinationPath = body['destinationPath'] is String
        ? body['destinationPath'] as String
        : decoded['originalPath'] as String;
    final destination = await _pathGuard.resolve(
      rootId,
      destinationPath,
      mustExist: false,
      allowRoot: false,
    );
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const _ApiException(
        409,
        'destination_exists',
        'Restore destination exists.',
      );
    }
    if (!await File(destination).parent.exists()) {
      throw const _ApiException(
        409,
        'parent_not_found',
        'Restore folder is missing.',
      );
    }
    final type = await FileSystemEntity.type(payloadPath, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(payloadPath).rename(destination);
    } else {
      await File(payloadPath).rename(destination);
    }
    await metadata.delete();
    await _safeAudit(
      action: 'trash.restore',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: destinationPath,
      details: <String, Object?>{'trashId': trashId},
    );
    await _json(request.response, 200, <String, Object?>{
      'trashId': trashId,
      'path': _normalizedRelative(destinationPath),
      'restored': true,
    });
  }

  Future<void> _handleTrashList(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final rootId = _requiredQuery(request, 'root');
    final trashDirectory = await _trashDirectory(rootId);
    final items = <Map<String, Object?>>[];
    await for (final entity in trashDirectory.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      final stat = await entity.stat();
      if (stat.size > 64 * 1024) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map<String, dynamic> ||
            decoded['trashId'] is! String ||
            decoded['originalPath'] is! String ||
            decoded['deletedAt'] is! String) {
          continue;
        }
        final trashId = decoded['trashId'] as String;
        if (!RegExp(r'^[0-9]+-[0-9a-f]+$').hasMatch(trashId)) continue;
        final payloadPath =
            '${trashDirectory.path}${Platform.pathSeparator}$trashId.payload';
        final payloadType = await FileSystemEntity.type(
          payloadPath,
          followLinks: false,
        );
        if (payloadType == FileSystemEntityType.notFound) continue;
        final payloadStat = await FileStat.stat(payloadPath);
        items.add(<String, Object?>{
          'trashId': trashId,
          'originalPath': decoded['originalPath'],
          'deletedAt': decoded['deletedAt'],
          'type': payloadType == FileSystemEntityType.directory
              ? 'directory'
              : 'file',
          'size': payloadType == FileSystemEntityType.file
              ? payloadStat.size
              : null,
        });
      } on FormatException {
        // Ignore malformed metadata instead of exposing internal state.
      } on FileSystemException {
        // An item can disappear while the directory is being listed.
      }
      if (items.length >= 1000) break;
    }
    items.sort(
      (left, right) =>
          (right['deletedAt'] as String).compareTo(left['deletedAt'] as String),
    );
    await _safeAudit(
      action: 'trash.list',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      details: <String, Object?>{'count': items.length},
    );
    await _json(request.response, 200, <String, Object?>{
      'root': rootId,
      'items': items,
      'truncated': items.length >= 1000,
    });
  }

  Future<void> _handleRevoke(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final body = await _readJson(request);
    final tokenId = body['tokenId'] is String
        ? body['tokenId'] as String
        : identity.tokenId;
    if (!await _tokenStore.revoke(tokenId)) {
      throw const _ApiException(404, 'token_not_found', 'Token was not found.');
    }
    await _safeAudit(
      action: 'tokens.revoke',
      outcome: 'success',
      identity: identity,
      details: <String, Object?>{'revokedTokenId': tokenId},
    );
    await _json(request.response, 200, <String, Object?>{
      'revoked': true,
      'tokenId': tokenId,
    });
  }

  Future<Directory> _trashDirectory(String rootId) async {
    final root = _pathGuard.root(rootId);
    final directory = Directory(
      '${root.canonicalPath}${Platform.pathSeparator}.nexgallery-trash',
    );
    if (!await directory.exists()) {
      await directory.create();
    }
    final resolved = await _pathGuard.resolve(
      rootId,
      '.nexgallery-trash',
      allowInternal: true,
    );
    return Directory(resolved);
  }

  Future<Map<String, Object?>> _metadata(
    String rootId,
    String relativePath,
    FileSystemEntity entity,
  ) async {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    final stat = await entity.stat();
    return <String, Object?>{
      'name': _basename(entity.path),
      'path': _normalizedRelative(relativePath),
      'root': rootId,
      'type': switch (type) {
        FileSystemEntityType.directory => 'directory',
        FileSystemEntityType.link => 'link',
        _ => 'file',
      },
      'size': type == FileSystemEntityType.file ? stat.size : null,
      'modifiedAt': stat.modified.toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    if (request.contentLength > config.maxJsonBytes) {
      throw const _ApiException(
        413,
        'body_too_large',
        'Request body is too large.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
      if (bytes.length > config.maxJsonBytes) {
        throw const _ApiException(
          413,
          'body_too_large',
          'Request body is too large.',
        );
      }
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object.');
    }
    return value;
  }

  Future<void> _safeAudit({
    required String action,
    required String outcome,
    DeviceIdentity? identity,
    String? remoteAddress,
    String? rootId,
    String? relativePath,
    Map<String, Object?> details = const <String, Object?>{},
  }) async {
    try {
      await _auditLog.record(
        action: action,
        outcome: outcome,
        deviceId: identity?.id,
        remoteAddress: remoteAddress,
        rootId: rootId,
        relativePath: relativePath,
        details: details,
      );
    } catch (error) {
      stderr.writeln('Could not write audit log: $error');
    }
  }

  static _ByteRange? _parseRange(String? header, int length) {
    if (header == null) return null;
    if (length == 0 || !header.startsWith('bytes=') || header.contains(',')) {
      throw _RangeException(length);
    }
    final parts = header.substring(6).split('-');
    if (parts.length != 2) throw _RangeException(length);
    int start;
    int end;
    if (parts[0].isEmpty) {
      final suffix = int.tryParse(parts[1]);
      if (suffix == null || suffix <= 0) throw _RangeException(length);
      start = max(0, length - suffix);
      end = length - 1;
    } else {
      start = int.tryParse(parts[0]) ?? -1;
      end = parts[1].isEmpty ? length - 1 : int.tryParse(parts[1]) ?? -1;
    }
    if (start < 0 || start >= length || end < start) {
      throw _RangeException(length);
    }
    return _ByteRange(start, min(end, length - 1));
  }

  static int _requiredIntegerHeader(
    HttpRequest request,
    String name, {
    required int min,
    int? max,
  }) {
    final value = int.tryParse(request.headers.value(name) ?? '');
    if (value == null || value < min || (max != null && value > max)) {
      throw _ApiException(400, 'invalid_header', 'Invalid $name header.');
    }
    return value;
  }

  static String _requiredQuery(HttpRequest request, String name) {
    final value = request.uri.queryParameters[name];
    if (value == null || value.trim().isEmpty) {
      throw _ApiException(400, 'missing_parameter', 'Missing $name parameter.');
    }
    return value;
  }

  static String _requiredString(
    Map<String, dynamic> body,
    String name, {
    required int maxLength,
  }) {
    final value = body[name];
    if (value is! String || value.trim().isEmpty || value.length > maxLength) {
      throw FormatException(
        '$name must be a non-empty string up to $maxLength characters.',
      );
    }
    return value;
  }

  static bool _isLoopback(InternetAddress? address) {
    if (address == null) return false;
    return address.isLoopback || address.address == '::ffff:127.0.0.1';
  }

  static bool _isHiddenServerEntry(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('.nexgallery-') || lower.endsWith('.part');
  }

  static String _combineRelative(String parent, String child) {
    final normalizedParent = _normalizedRelative(parent);
    return normalizedParent.isEmpty ? child : '$normalizedParent/$child';
  }

  static String _normalizedRelative(String value) => value
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');

  static String _basename(String path) {
    final pieces = path.replaceAll('\\', '/').split('/');
    return pieces.lastWhere((part) => part.isNotEmpty, orElse: () => '');
  }

  static String _contentType(String path) {
    final extension = path.toLowerCase().split('.').last;
    return switch (extension) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'mp4' => 'video/mp4',
      'webm' => 'video/webm',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'pdf' => 'application/pdf',
      'json' => 'application/json; charset=utf-8',
      'txt' => 'text/plain; charset=utf-8',
      _ => 'application/octet-stream',
    };
  }

  static void _applyHeaders(HttpResponse response) {
    response.headers
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Cache-Control', 'no-store')
      ..set('Referrer-Policy', 'no-referrer');
  }

  static Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
    } on StateError {
      // A streaming response may already have sent headers before I/O failed.
    } on HttpException {
      // The peer may have disconnected while a response was being written.
    } finally {
      await response.close();
    }
  }

  static Future<void> _jsonError(
    HttpResponse response,
    _ApiException error,
  ) async {
    try {
      if (error is _RangeException) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${error.length}',
        );
      }
    } on StateError {
      await response.close();
      return;
    }
    await _json(response, error.status, <String, Object?>{
      'error': <String, Object?>{
        'code': error.code,
        'message': error.message,
        if (error.details.isNotEmpty) 'details': error.details,
      },
    });
  }
}

class _ApiException implements Exception {
  const _ApiException(
    this.status,
    this.code,
    this.message, {
    this.details = const {},
  });

  final int status;
  final String code;
  final String message;
  final Map<String, Object?> details;
}

final class _RangeException extends _ApiException {
  const _RangeException(this.length)
    : super(416, 'invalid_range', 'Requested byte range is invalid.');

  final int length;
}

final class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int start;
  final int end;
}

final class _KeyedLock {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<T> run<T>(String key, Future<T> Function() action) async {
    final previous = _tails[key] ?? Future<void>.value();
    final gate = Completer<void>();
    final tail = gate.future;
    _tails[key] = tail;
    try {
      await previous;
      return await action();
    } finally {
      gate.complete();
      if (identical(_tails[key], tail)) {
        _tails.remove(key);
      }
    }
  }
}
