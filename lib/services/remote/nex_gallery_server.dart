import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'path_guard.dart';
import 'power.dart';
import 'request_signing.dart';
import 'security.dart';
import 'sha256.dart';
import 'thumbnails.dart';
import 'upload_quarantine.dart';
import 'video_proxy.dart';
import 'catalog_index.dart';
import 'catalog_source.dart';

void _stderrLog(String message) => stderr.writeln(message);

final class RemoteServerConfig {
  const RemoteServerConfig({
    required this.allowedRoots,
    required this.dataDirectory,
    this.port = 8732,
    this.listenOnLan = false,
    this.bindAddresses,
    this.securityContext,
    this.certificateFingerprint,
    this.allowWrites = false,
    this.requireApproval = true,
    this.serverName,
    this.ownerSecret,
    this.discoveryPort = 8733,
    this.maxJsonBytes = 1024 * 1024,
    this.maxUploadChunkBytes = 8 * 1024 * 1024,
    this.maxUploadFileBytes = 20 * 1024 * 1024 * 1024,
    this.maxSearchEntries = 50000,
    this.requestsPerMinute = 240,
    this.pairAttemptsPerMinute = 10,
    this.pairingLifetime = const Duration(minutes: 5),
    this.keepAwake = false,
    this.powerRequest,
    this.uploadScanner,
    this.videoTranscoder,
    this.catalogLoader,
    this.log = _stderrLog,
  });

  final Map<String, String> allowedRoots;
  final Directory dataDirectory;
  final int port;
  final bool listenOnLan;

  /// Explicit interfaces, for example loopback plus a Tailscale address.
  /// Overrides [listenOnLan] when set.
  final List<InternetAddress>? bindAddresses;
  final SecurityContext? securityContext;

  /// Shown to phones that discover this PC on the local network so the user
  /// can compare it with the PC screen.
  final String? certificateFingerprint;
  final bool allowWrites;

  /// New phones wait until the PC owner approves them.
  final bool requireApproval;
  final String? serverName;

  /// When set, owner endpoints also require this value in `X-Nex-Owner`.
  /// A background agent stores it in its private data folder.
  final String? ownerSecret;

  /// UDP port answering LAN discovery; 0 disables discovery.
  final int discoveryPort;
  final int maxJsonBytes;
  final int maxUploadChunkBytes;
  final int maxUploadFileBytes;
  final int maxSearchEntries;
  final int requestsPerMinute;
  final int pairAttemptsPerMinute;
  final Duration pairingLifetime;

  /// Receives diagnostics. A background agent without a console writes them
  /// to its log file.
  final void Function(String message) log;

  /// "Keep PC available": stop Windows sleeping while the server runs.
  /// Streams and transfers keep it awake either way.
  final bool keepAwake;

  /// Replaces the platform power request, for tests.
  final PowerRequest? powerRequest;

  /// Checks executables, scripts, archives and macro documents before they
  /// appear in a shared folder. Null finds Microsoft Defender; without a
  /// scanner such uploads wait for the owner.
  final UploadScanner? uploadScanner;

  /// Makes 360p-1080p copies of videos for slow connections. Null looks for
  /// FFmpeg on this PC; without it phones stream originals only.
  final VideoTranscoder? videoTranscoder;
  final CatalogLoader? catalogLoader;

  List<InternetAddress> get addresses =>
      bindAddresses ??
      [listenOnLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4];
}

/// A phone waiting for the PC owner's approval.
final class PendingPairing {
  PendingPairing._({
    required this.requestId,
    required this.deviceName,
    required this.remoteAddress,
    required this.createdAt,
    required this.expiresAt,
    required this.publicKey,
    required this._pollSecretHash,
  });

  final String requestId;
  final String deviceName;
  final String remoteAddress;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String? publicKey;
  final String _pollSecretHash;
  String status = 'pending';
  IssuedToken? _issued;

  PairingRequest get request => PairingRequest(
    requestId: requestId,
    deviceName: deviceName,
    remoteAddress: remoteAddress,
    signedRequests: publicKey != null,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'requestId': requestId,
    'deviceName': deviceName,
    'remoteAddress': remoteAddress,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
    'signedRequests': publicKey != null,
    'status': status,
  };
}

/// What an owner UI shows about a phone waiting for approval.
final class PairingRequest {
  const PairingRequest({
    required this.requestId,
    required this.deviceName,
    required this.remoteAddress,
    required this.signedRequests,
  });

  factory PairingRequest.fromJson(Map<String, dynamic> json) => PairingRequest(
    requestId: json['requestId'] as String,
    deviceName: json['deviceName'] as String,
    remoteAddress: json['remoteAddress'] as String? ?? '',
    signedRequests: json['signedRequests'] == true,
  );

  final String requestId;
  final String deviceName;
  final String remoteAddress;
  final bool signedRequests;
}

const _routeScopes = <String, String>{
  'GET /v1/catalog/timeline': DeviceScope.browse,
  'GET /v1/catalog/albums': DeviceScope.browse,
  'GET /v1/catalog/people': DeviceScope.browse,
  'GET /v1/catalog/changes': DeviceScope.browse,
  'GET /v1/roots': DeviceScope.browse,
  'GET /v1/info': DeviceScope.browse,
  'GET /v1/list': DeviceScope.browse,
  'GET /v1/search': DeviceScope.browse,
  'GET /v1/thumbnail': DeviceScope.browse,
  'GET /v1/download': DeviceScope.download,
  'HEAD /v1/download': DeviceScope.download,
  'GET /v1/proxy/status': DeviceScope.download,
  'GET /v1/proxy': DeviceScope.download,
  'HEAD /v1/proxy': DeviceScope.download,
  'PUT /v1/upload': DeviceScope.upload,
  'POST /v1/folders': DeviceScope.organize,
  'POST /v1/move': DeviceScope.organize,
  'POST /v1/trash': DeviceScope.trash,
  'GET /v1/trash': DeviceScope.trash,
  'POST /v1/trash/restore': DeviceScope.trash,
};

const discoveryRequest = 'NEXGALLERY_DISCOVER_V1';

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
    required this._thumbnails,
    required this._scanner,
    required this._transcoder,
  }) : _requestLimiter = FixedWindowRateLimiter(
         limit: config.requestsPerMinute,
         window: const Duration(minutes: 1),
       ),
       _pairLimiter = FixedWindowRateLimiter(
         limit: config.pairAttemptsPerMinute,
         window: const Duration(minutes: 1),
       );

  final RemoteServerConfig config;
  late final _catalogue = RemoteCatalogIndex(
    _pathGuard,
    config.catalogLoader ??
        RemoteCatalogSource(
          config.dataDirectory.parent,
          config.allowedRoots.values,
        ).load,
  );
  final PathGuard _pathGuard;
  final DeviceTokenStore _tokenStore;
  final AuditLog _auditLog;
  final FixedWindowRateLimiter _requestLimiter;
  final FixedWindowRateLimiter _pairLimiter;
  final _KeyedLock _uploadLocks = _KeyedLock();
  final Random _random = Random.secure();
  final Map<String, DateTime> _pairingHashes = <String, DateTime>{};
  final Map<String, PendingPairing> _pending = <String, PendingPairing>{};
  final ThumbnailCache _thumbnails;
  final UploadScanner? _scanner;
  final VideoTranscoder? _transcoder;
  late final VideoProxyCache? _proxies = switch (_transcoder) {
    final transcoder? => VideoProxyCache(
      Directory('${config.dataDirectory.path}${Platform.pathSeparator}proxies'),
      transcoder,
      keepAwake: _keptAwake,
    ),
    null => null,
  };
  Future<void> _scans = Future<void>.value();
  final ReplayGuard _replay = ReplayGuard();
  final _identities = Expando<DeviceIdentity>();
  final _signed = Expando<bool>();
  final _events = StreamController<String>.broadcast();
  final List<HttpServer> _servers = <HttpServer>[];
  final List<StreamSubscription<HttpRequest>> _subscriptions =
      <StreamSubscription<HttpRequest>>[];
  RawDatagramSocket? _discovery;
  HttpServer? _server;
  AwakeTracker? _awake;
  List<String>? _macAddresses;

  /// Emits `pairing` when a phone asks to pair and `devices` when the set of
  /// paired devices changes, so an owner UI can refresh.
  Stream<String> get events => _events.stream;

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
      thumbnails: ThumbnailCache(
        Directory(
          '${config.dataDirectory.path}${Platform.pathSeparator}thumbnails',
        ),
      ),
      scanner: config.uploadScanner ?? await DefenderScanner.find(),
      transcoder: config.videoTranscoder ?? await FfmpegTranscoder.find(),
    );
  }

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;
  InternetAddress? get boundAddress => _server?.address;
  List<InternetAddress> get boundAddresses =>
      _servers.map((server) => server.address).toList(growable: false);
  String get serverName => config.serverName ?? Platform.localHostname;

  Future<void> start() async {
    if (_server != null) {
      throw StateError('Server is already running.');
    }
    // Explicit LAN or private-network opt-in remains required with TLS.
    final addresses = config.addresses;
    if (addresses.isEmpty) throw ArgumentError('No bind address was given.');
    final context = config.securityContext;
    var port = config.port;
    try {
      for (final address in addresses) {
        final server = context == null
            ? await HttpServer.bind(address, port, shared: false)
            : await HttpServer.bindSecure(
                address,
                port,
                context,
                shared: false,
              );
        port = server.port;
        _servers.add(server);
        _subscriptions.add(
          server.listen(
            _handle,
            onError: (Object error, StackTrace stackTrace) {
              config.log('nexGallery server request error: $error');
            },
          ),
        );
      }
      _server = _servers.first;
      _awake = AwakeTracker(
        config.powerRequest ??
            createPowerRequest('nexGallery is serving files to a paired phone'),
        always: config.keepAwake,
      );
      if (config.discoveryPort > 0 &&
          addresses.any((address) => !address.isLoopback)) {
        await _startDiscovery();
      }
      await _auditLog.record(
        action: 'server.start',
        outcome: 'success',
        details: <String, Object?>{
          'bind': addresses.map((address) => address.address).toList(),
          'port': port,
          'lan': config.listenOnLan,
          'tls': config.securityContext != null,
          'approval': config.requireApproval,
          'uploadScanner': ?_scanner?.name,
        },
      );
      unawaited(
        _resumeScans().catchError((Object error) {
          config.log('Could not resume upload scans: $error');
        }),
      );
    } catch (_) {
      await _closeSockets(force: true);
      rethrow;
    }
  }

  Future<void> _closeSockets({required bool force}) async {
    _server = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final server in _servers) {
      await server.close(force: force);
    }
    _servers.clear();
    _discovery?.close();
    _discovery = null;
    _awake?.dispose();
    _awake = null;
  }

  /// Whether this PC is currently prevented from sleeping.
  bool get keepsPcAwake => _awake?.isHeld ?? false;

  Future<void> _keptAwake(Future<void> Function() action) {
    final awake = _awake;
    return awake == null ? action() : awake.during(action);
  }

  /// Answers LAN discovery broadcasts with this PC's name and port. The
  /// certificate fingerprint lets the user compare it with the PC screen.
  Future<void> _startDiscovery() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        config.discoveryPort,
      );
      _discovery = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null || datagram.data.length > 64) return;
        if (utf8.decode(datagram.data, allowMalformed: true).trim() !=
            discoveryRequest) {
          return;
        }
        final reply = utf8.encode(
          jsonEncode(<String, Object?>{
            'service': 'nexgallery',
            'version': 1,
            'name': serverName,
            'port': boundPort,
            'tls': config.securityContext != null,
            'fingerprint': ?config.certificateFingerprint,
          }),
        );
        socket.send(reply, datagram.address, datagram.port);
      });
    } on SocketException catch (error) {
      // Another nexGallery instance may own the port; pairing still works by
      // QR code or typed address.
      config.log('LAN discovery is unavailable: ${error.message}');
    }
  }

  Future<void> stop({bool force = false}) async {
    if (_server == null) {
      return;
    }
    await _closeSockets(force: force);
    await _auditLog.record(action: 'server.stop', outcome: 'success');
  }

  /// Phones waiting for approval, oldest first.
  List<PendingPairing> get pendingPairings {
    _expirePending();
    return _pending.values
        .where((pending) => pending.status == 'pending')
        .toList(growable: false);
  }

  List<DeviceIdentity> get devices => _tokenStore.list();

  void _expirePending() {
    final now = DateTime.now().toUtc();
    _pending.removeWhere((_, pending) => !pending.expiresAt.isAfter(now));
  }

  /// Approves a waiting phone with the chosen permissions. The phone collects
  /// its token on its next status poll.
  Future<DeviceIdentity> approvePairing(
    String requestId, {
    Set<String> scopes = DeviceScope.readOnly,
    List<String>? roots,
  }) async {
    _expirePending();
    final pending = _pending[requestId];
    if (pending == null || pending.status != 'pending') {
      throw StateError(
        'This pairing request expired. Ask the phone to try again.',
      );
    }
    final unknown = roots?.where((root) => !_pathGuard.roots.containsKey(root));
    if (unknown != null && unknown.isNotEmpty) {
      throw ArgumentError('Unknown shared folder: ${unknown.first}');
    }
    final issued = await _tokenStore.issue(
      pending.deviceName,
      scopes: scopes,
      roots: roots,
      publicKey: pending.publicKey,
    );
    pending
      ..status = 'approved'
      .._issued = issued;
    await _safeAudit(
      action: 'pair.approve',
      outcome: 'success',
      identity: issued.identity,
      remoteAddress: pending.remoteAddress,
      details: <String, Object?>{'scopes': scopes.toList()},
    );
    _events.add('devices');
    return issued.identity;
  }

  Future<bool> denyPairing(String requestId) async {
    final pending = _pending[requestId];
    if (pending == null || pending.status != 'pending') return false;
    pending.status = 'denied';
    await _safeAudit(
      action: 'pair.deny',
      outcome: 'success',
      remoteAddress: pending.remoteAddress,
    );
    _events.add('pairing');
    return true;
  }

  Future<bool> revokeDevice(String tokenId) async {
    final revoked = await _tokenStore.revoke(tokenId);
    if (revoked) {
      await _safeAudit(
        action: 'tokens.revoke',
        outcome: 'success',
        details: <String, Object?>{'revokedTokenId': tokenId, 'by': 'owner'},
      );
      _events.add('devices');
    }
    return revoked;
  }

  Future<bool> updateDevicePermissions(
    String tokenId, {
    required Set<String> scopes,
    List<String>? roots,
  }) async {
    final updated = await _tokenStore.updatePermissions(
      tokenId,
      scopes: scopes,
      roots: roots,
    );
    if (updated) {
      await _safeAudit(
        action: 'tokens.permissions',
        outcome: 'success',
        details: <String, Object?>{
          'tokenId': tokenId,
          'scopes': scopes.toList(),
          'roots': ?roots,
        },
      );
      _events.add('devices');
    }
    return updated;
  }

  /// The most recent audit entries, newest first.
  Future<List<Map<String, Object?>>> readAudit({int limit = 200}) =>
      _auditLog.tail(limit: limit);

  Future<List<String>> _localMacAddresses() async {
    final cached = _macAddresses;
    if (cached != null) return cached;
    final found = <String>[];
    if (Platform.isWindows) {
      try {
        final result = await Process.run('getmac', ['/fo', 'csv', '/nh']);
        for (final match in RegExp(
          r'([0-9A-F]{2}(?:-[0-9A-F]{2}){5})',
          caseSensitive: false,
        ).allMatches('${result.stdout}')) {
          found.add(match.group(1)!.replaceAll('-', ':').toUpperCase());
        }
      } on ProcessException {
        // Wake-on-LAN details are optional.
      }
    }
    return _macAddresses = found.toSet().toList(growable: false);
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
          'tls': config.securityContext != null,
          'allowWrites': config.allowWrites,
          'lanEnabled': config.listenOnLan,
        });
        return;
      }
      if (request.uri.path == '/v1/pair/code' && request.method == 'POST') {
        _requireOwner(request);
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
      if (request.uri.path == '/v1/pair/status' && request.method == 'POST') {
        await _handlePairStatus(request);
        return;
      }
      if (await _handleOwner(request, route, remoteAddress)) return;

      identity = await _authenticate(request, remoteAddress);
      _identities[request] = identity;
      if (!_requestLimiter.allow('${identity.id}:authenticated')) {
        throw const _ApiException(429, 'rate_limited', 'Too many requests.');
      }

      if (request.method != 'GET' &&
          request.method != 'HEAD' &&
          request.uri.path != '/v1/tokens/revoke' &&
          !config.allowWrites) {
        throw const _ApiException(
          403,
          'read_only',
          'The PC owner has enabled read-only access.',
        );
      }
      final scope = _routeScopes[route];
      if (scope != null && !identity.allows(scope)) {
        throw _ApiException(
          403,
          'scope_denied',
          'The PC owner has not allowed this phone to $scope.',
          details: <String, Object?>{'scope': scope},
        );
      }
      final queryRoot = request.uri.queryParameters['root'];
      if (queryRoot != null) _checkRoot(identity, queryRoot);

      switch (route) {
        case 'GET /v1/catalog/timeline':
        case 'GET /v1/catalog/albums':
        case 'GET /v1/catalog/people':
          final collection = switch (request.uri.path.split('/').last) {
            'albums' => 'album',
            'people' => 'person',
            _ => 'item',
          };
          await _json(
            request.response,
            200,
            await _catalogue.page(
              collection,
              request.uri.queryParameters,
              identity,
            ),
          );
        case 'GET /v1/catalog/changes':
          await _json(
            request.response,
            200,
            await _catalogue.changes(request.uri.queryParameters, identity),
          );
        case 'GET /v1/roots':
          await _json(request.response, 200, <String, Object?>{
            'roots': _pathGuard.roots.values
                .where((root) => identity!.canUseRoot(root.id))
                .map((root) => root.toJson())
                .toList(growable: false),
          });
        case 'GET /v1/info':
          await _json(request.response, 200, <String, Object?>{
            'name': serverName,
            'version': 2,
            'allowWrites': config.allowWrites,
            'scopes': identity.scopes.toList()..sort(),
            'roots': ?identity.roots,
            'macAddresses': await _localMacAddresses(),
            'videoProxy': <String, Object?>{
              'available': _proxies != null,
              'qualities': videoProxyQualities,
            },
          });
        case 'GET /v1/list':
          await _handleList(request, identity);
        case 'GET /v1/search':
          await _handleSearch(request, identity);
        case 'GET /v1/download':
        case 'HEAD /v1/download':
          await _keptAwake(() => _handleDownload(request, identity!));
        case 'GET /v1/proxy/status':
          await _handleProxyStatus(request);
        case 'GET /v1/proxy':
        case 'HEAD /v1/proxy':
          await _keptAwake(() => _handleProxy(request, identity!));
        case 'GET /v1/thumbnail':
          await _handleThumbnail(request, identity);
        case 'PUT /v1/upload':
          await _keptAwake(() => _handleUpload(request, identity!));
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
        case 'POST /v1/tokens/revoke':
          await _handleRevoke(request, identity);
        default:
          throw const _ApiException(
            404,
            'not_found',
            'Endpoint was not found.',
          );
      }
    } on CatalogApiException catch (error) {
      await _jsonError(
        request.response,
        _ApiException(error.status, error.code, error.message),
      );
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
      config.log('Unhandled request failure: $error\n$stackTrace');
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

  void _requireOwner(HttpRequest request) {
    if (!_isLoopback(request.connectionInfo?.remoteAddress)) {
      throw const _ApiException(
        403,
        'local_only',
        'Manage pairing and devices on the PC.',
      );
    }
    final secret = config.ownerSecret;
    if (secret != null &&
        !constantTimeEquals(
          request.headers.value('x-nex-owner') ?? '',
          secret,
        )) {
      throw const _ApiException(
        403,
        'owner_required',
        'Only the nexGallery app on this PC can manage the server.',
      );
    }
  }

  void _checkRoot(DeviceIdentity identity, String rootId) {
    if (!identity.canUseRoot(rootId)) {
      throw const _ApiException(
        403,
        'root_denied',
        'This phone may not open that shared folder.',
      );
    }
  }

  /// Loopback owner API used by the desktop app to manage a background agent.
  Future<bool> _handleOwner(
    HttpRequest request,
    String route,
    String remoteAddress,
  ) async {
    switch (route) {
      case 'GET /v1/pair/requests':
        _requireOwner(request);
        await _json(request.response, 200, <String, Object?>{
          'requests': [for (final pending in pendingPairings) pending.toJson()],
        });
      case 'POST /v1/pair/approve':
        _requireOwner(request);
        final body = await _readJson(request);
        final identity = await approvePairing(
          _requiredString(body, 'requestId', maxLength: 64),
          scopes: body['scopes'] == null
              ? DeviceScope.readOnly
              : DeviceScope.parse(body['scopes']),
          roots: body['roots'] is List
              ? (body['roots'] as List).whereType<String>().toList()
              : null,
        );
        await _json(request.response, 200, identity.toPublicJson());
      case 'POST /v1/pair/deny':
        _requireOwner(request);
        final body = await _readJson(request);
        await _json(request.response, 200, <String, Object?>{
          'denied': await denyPairing(
            _requiredString(body, 'requestId', maxLength: 64),
          ),
        });
      case 'GET /v1/tokens':
        _requireOwner(request);
        await _json(request.response, 200, <String, Object?>{
          'devices': devices
              .map((device) => device.toPublicJson())
              .toList(growable: false),
        });
      case 'POST /v1/tokens/permissions':
        _requireOwner(request);
        final body = await _readJson(request);
        final updated = await updateDevicePermissions(
          _requiredString(body, 'tokenId', maxLength: 64),
          scopes: DeviceScope.parse(body['scopes']),
          roots: body['roots'] is List
              ? (body['roots'] as List).whereType<String>().toList()
              : null,
        );
        if (!updated) {
          throw const _ApiException(
            404,
            'token_not_found',
            'Token was not found.',
          );
        }
        await _json(request.response, 200, <String, Object?>{'updated': true});
      case 'POST /v1/owner/revoke':
        _requireOwner(request);
        final body = await _readJson(request);
        await _json(request.response, 200, <String, Object?>{
          'revoked': await revokeDevice(
            _requiredString(body, 'tokenId', maxLength: 64),
          ),
        });
      case 'POST /v1/owner/shutdown':
        _requireOwner(request);
        await _json(request.response, 202, <String, Object?>{'stopping': true});
        // The agent process exits when it sees this event.
        _events.add('shutdown');
      case 'GET /v1/quarantine':
        _requireOwner(request);
        await _json(request.response, 200, <String, Object?>{
          'scanner': ?_scanner?.name,
          'uploads': [for (final item in await quarantined()) item.toJson()],
        });
      case 'POST /v1/quarantine/release':
        _requireOwner(request);
        final body = await _readJson(request);
        await _json(request.response, 200, <String, Object?>{
          'path': await releaseQuarantined(
            _requiredString(body, 'root', maxLength: 40),
            _requiredString(body, 'id', maxLength: 80),
          ),
        });
      case 'POST /v1/quarantine/delete':
        _requireOwner(request);
        final body = await _readJson(request);
        await deleteQuarantined(
          _requiredString(body, 'root', maxLength: 40),
          _requiredString(body, 'id', maxLength: 80),
        );
        await _json(request.response, 200, <String, Object?>{'deleted': true});
      case 'GET /v1/audit':
        _requireOwner(request);
        final limit =
            int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 200;
        await _json(request.response, 200, <String, Object?>{
          'entries': await readAudit(limit: limit.clamp(1, 1000)),
        });
      default:
        return false;
    }
    return true;
  }

  Future<void> _handlePairStatus(HttpRequest request) async {
    final body = await _readJson(request);
    final requestId = _requiredString(body, 'requestId', maxLength: 64);
    final secret = _requiredString(body, 'pollSecret', maxLength: 128);
    _expirePending();
    final pending = _pending[requestId];
    if (pending == null ||
        !constantTimeEquals(
          sha256Hex(utf8.encode(secret)),
          pending._pollSecretHash,
        )) {
      throw const _ApiException(
        404,
        'pairing_not_found',
        'This pairing request expired. Start pairing again.',
      );
    }
    final issued = pending._issued;
    if (pending.status == 'approved' && issued != null) {
      // The token is delivered exactly once.
      _pending.remove(requestId);
      await _json(request.response, 200, <String, Object?>{
        'status': 'approved',
        'token': issued.token,
        'tokenType': 'Bearer',
        'device': issued.identity.toPublicJson(),
      });
      return;
    }
    if (pending.status == 'denied') _pending.remove(requestId);
    await _json(request.response, 200, <String, Object?>{
      'status': pending.status,
      'expiresAt': pending.expiresAt.toIso8601String(),
    });
  }

  Future<void> _handlePair(HttpRequest request, String remoteAddress) async {
    final body = await _readJson(request);
    final code = _requiredString(body, 'code', maxLength: 32);
    final deviceName = _requiredString(body, 'deviceName', maxLength: 80);
    final publicKey = body['publicKey'];
    if (publicKey != null &&
        (publicKey is! String || !isValidPublicKey(publicKey))) {
      throw const FormatException('publicKey must be a base64url Ed25519 key.');
    }
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
    if (config.requireApproval) {
      _expirePending();
      if (_pending.length >= 20) {
        throw const _ApiException(
          429,
          'too_many_pending',
          'Too many phones are waiting for approval.',
        );
      }
      final requestId = _randomToken(12);
      final pollSecret = _randomToken(24);
      final pending = PendingPairing._(
        requestId: requestId,
        deviceName: deviceName.trim(),
        remoteAddress: remoteAddress,
        createdAt: now,
        expiresAt: now.add(config.pairingLifetime),
        publicKey: publicKey as String?,
        pollSecretHash: sha256Hex(utf8.encode(pollSecret)),
      );
      _pending[requestId] = pending;
      await _auditLog.record(
        action: 'pair.request',
        outcome: 'pending',
        remoteAddress: remoteAddress,
      );
      _events.add('pairing');
      await _json(request.response, 202, <String, Object?>{
        'status': 'pending',
        'requestId': requestId,
        'pollSecret': pollSecret,
        'expiresAt': pending.expiresAt.toIso8601String(),
      });
      return;
    }
    final issued = await _tokenStore.issue(
      deviceName,
      publicKey: publicKey as String?,
    );
    _events.add('devices');
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

  String _randomToken(int bytes) => base64Url
      .encode(List<int>.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  Future<DeviceIdentity> _authenticate(
    HttpRequest request,
    String remoteAddress,
  ) async {
    final identity = await _bearerIdentity(request, remoteAddress);
    final publicKey = identity.publicKey;
    if (publicKey == null) return identity;
    // Devices that registered a key must sign every request.
    final headers = request.headers;
    final timestamp = headers.value(SignedHeaders.timestamp) ?? '';
    final nonce = headers.value(SignedHeaders.nonce) ?? '';
    final signature = headers.value(SignedHeaders.signature) ?? '';
    if (headers.value(SignedHeaders.device) != identity.tokenId ||
        signature.isEmpty) {
      throw const _ApiException(
        401,
        'signature_required',
        'This phone must sign its requests.',
      );
    }
    final valid = await verifyDeviceSignature(
      publicKey: publicKey,
      signature: signature,
      message: canonicalRequest(
        method: request.method,
        path: request.uri.path,
        query: request.uri.query,
        timestamp: timestamp,
        nonce: nonce,
        tokenId: identity.tokenId,
        header: headers.value,
      ),
    );
    if (!valid) {
      throw const _ApiException(
        401,
        'invalid_signature',
        'Signature is invalid.',
      );
    }
    final replay = _replay.check(identity.tokenId, timestamp, nonce);
    if (replay != null) {
      throw _ApiException(
        401,
        replay,
        'Request was rejected. Check that the phone clock is correct.',
      );
    }
    _signed[request] = true;
    return identity;
  }

  Future<DeviceIdentity> _bearerIdentity(
    HttpRequest request,
    String remoteAddress,
  ) async {
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
    final identity = await _tokenStore.authenticate(
      bearer.group(1)!.trim(),
      remoteAddress: remoteAddress,
    );
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
    final offset = max(
      0,
      int.tryParse(request.uri.queryParameters['offset'] ?? '') ?? 0,
    );
    final limit =
        (int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 5000)
            .clamp(1, 5000);
    // Names are listed first and sorted so pages are stable; metadata is read
    // only for the requested page.
    final children = <(String, FileSystemEntity)>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = _basename(entity.path);
      if (_isHiddenServerEntry(name)) continue;
      children.add((name, entity));
      if (children.length >= 100000) break;
    }
    final directories = <String>{
      for (final (name, entity) in children)
        if (entity is Directory) name,
    };
    children.sort((left, right) {
      final typeOrder =
          (directories.contains(left.$1) ? 0 : 1) -
          (directories.contains(right.$1) ? 0 : 1);
      if (typeOrder != 0) return typeOrder;
      return left.$1.toLowerCase().compareTo(right.$1.toLowerCase());
    });
    final entries = <Map<String, Object?>>[];
    var index = offset;
    for (; index < children.length && entries.length < limit; index++) {
      final (name, entity) = children[index];
      final childRelative = _combineRelative(relativePath, name);
      try {
        await _pathGuard.resolve(rootId, childRelative);
        entries.add(await _metadata(rootId, childRelative, entity));
      } on RemotePathException {
        // Links that resolve outside the configured root are intentionally hidden.
      }
    }
    await _safeAudit(
      action: 'files.list',
      outcome: 'success',
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{'count': entries.length, 'offset': offset},
    );
    await _json(request.response, 200, <String, Object?>{
      'root': rootId,
      'path': _normalizedRelative(relativePath),
      'entries': entries,
      'total': children.length,
      'offset': offset,
      if (index < children.length) 'nextOffset': index,
      'truncated': index < children.length,
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
    final stat = await file.stat();
    final length = stat.size;
    final version = _version(stat);
    final expected =
        request.headers.value('x-nex-file-version') ??
        _unquoteTag(request.headers.value(HttpHeaders.ifMatchHeader));
    if (expected != null && expected != '*' && expected != version) {
      throw const _ApiException(
        412,
        'file_changed',
        'The PC file changed. Refresh the folder before downloading again.',
      );
    }
    final range = _parseRange(
      request.headers.value(HttpHeaders.rangeHeader),
      length,
    );
    final start = range?.start ?? 0;
    final end = range?.end ?? (length - 1);
    request.response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set('X-Nex-File-Version', version)
      ..set(HttpHeaders.etagHeader, '"$version"')
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

  static const _videoExtensions = <String>{
    'mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm', 'wmv', 'flv', '3gp', 'mpg', //
    'mpeg', 'ts', 'mts', 'm2ts', 'vob',
  };

  /// Resolves the original video and the proxy state for `quality`.
  Future<(String, String, int, ProxyState)> _proxyState(
    HttpRequest request,
  ) async {
    final proxies = _proxies;
    if (proxies == null) {
      throw const _ApiException(
        501,
        'proxy_unavailable',
        'Install FFmpeg on the PC to stream smaller copies of videos.',
      );
    }
    final rootId = _requiredQuery(request, 'root');
    final relativePath = _requiredQuery(request, 'path');
    final quality = int.tryParse(request.uri.queryParameters['quality'] ?? '');
    if (!videoProxyQualities.contains(quality)) {
      throw FormatException(
        'quality must be one of ${videoProxyQualities.join(', ')}.',
      );
    }
    final name = _basename(relativePath).toLowerCase();
    if (!_videoExtensions.contains(name.split('.').last)) {
      throw const _ApiException(
        415,
        'not_a_video',
        'Only videos have smaller copies.',
      );
    }
    final file = File(
      await _pathGuard.resolve(rootId, relativePath, allowRoot: false),
    );
    if (!await file.exists()) {
      throw const _ApiException(400, 'not_a_file', 'Path is not a file.');
    }
    final state = await proxies.request(
      file,
      _version(await file.stat()),
      quality!,
    );
    return (rootId, relativePath, quality, state);
  }

  /// Starts (or reports) a smaller copy of a video for slow connections.
  Future<void> _handleProxyStatus(HttpRequest request) async {
    final (_, _, quality, state) = await _proxyState(request);
    await _json(request.response, 200, <String, Object?>{
      ...state.toJson(),
      'quality': quality,
    });
  }

  /// Streams a finished proxy with byte ranges, like an original.
  Future<void> _handleProxy(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final (rootId, relativePath, quality, state) = await _proxyState(request);
    final file = state.file;
    if (state.status != ProxyStatus.ready || file == null) {
      throw _ApiException(
        409,
        'proxy_not_ready',
        state.error ?? 'The smaller copy is still being prepared.',
        details: state.toJson(),
      );
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
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4');
    if (range != null) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/$length',
      );
    }
    final responseLength = length == 0 ? 0 : end - start + 1;
    request.response.contentLength = responseLength;
    if (start == 0) {
      await _safeAudit(
        action: 'files.stream.proxy',
        outcome: 'success',
        identity: identity,
        rootId: rootId,
        relativePath: relativePath,
        details: <String, Object?>{'quality': quality},
      );
    }
    if (request.method != 'HEAD' && responseLength > 0) {
      await request.response.addStream(file.openRead(start, end + 1));
    }
    await request.response.close();
  }

  /// Waits for queued video conversions, for tests.
  Future<void> get proxiesSettled => _proxies?.settled ?? Future.value();

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
          // Uploads may create missing folders inside the shared root, for
          // example dated camera-backup folders.
          if (offset != 0 ||
              request.headers.value('x-upload-create-parents') != 'true') {
            throw const _ApiException(
              409,
              'parent_not_found',
              'Destination folder does not exist.',
            );
          }
          await parent.create(recursive: true);
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
            config.log(
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
        if (needsUploadScan(relativePath)) {
          final held = await _quarantine(
            rootId,
            _normalizedRelative(relativePath),
            part,
            size: nextOffset,
            sha256: actualHash,
            identity: identity,
          );
          await _json(request.response, 201, <String, Object?>{
            'uploadId': uploadId,
            'path': _normalizedRelative(relativePath),
            'size': nextOffset,
            'complete': true,
            'sha256': ?actualHash,
            'quarantined': true,
            'scan': held.status.name,
          });
          return;
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
    await _checkVersion(source, body);
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
    await _checkVersion(source, body);
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
    if (tokenId != identity.tokenId &&
        !_isLoopback(request.connectionInfo?.remoteAddress)) {
      throw const _ApiException(
        403,
        'local_only',
        'Only the PC owner can revoke another device.',
      );
    }
    if (!await _tokenStore.revoke(tokenId)) {
      throw const _ApiException(404, 'token_not_found', 'Token was not found.');
    }
    _events.add('devices');
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
      await _hideOnWindows(directory);
    }
    final resolved = await _pathGuard.resolve(
      rootId,
      '.nexgallery-trash',
      allowInternal: true,
    );
    return Directory(resolved);
  }

  /// Windows does not hide dot-folders; the owner's Explorer view should not
  /// fill with nexGallery's private folders.
  static Future<void> _hideOnWindows(Directory directory) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('attrib', ['+h', directory.path]);
    } on ProcessException {
      // A visible folder is harmless.
    }
  }

  static const _quarantineFolder = '.nexgallery-quarantine';

  Future<Directory> _quarantineDirectory(String rootId) async =>
      (await _existingQuarantine(rootId, create: true))!;

  /// Null when nothing was ever quarantined in this root, so listing never
  /// adds folders to shared roots.
  Future<Directory?> _existingQuarantine(
    String rootId, {
    bool create = false,
  }) async {
    final root = _pathGuard.root(rootId);
    final directory = Directory(
      '${root.canonicalPath}${Platform.pathSeparator}$_quarantineFolder',
    );
    if (!await directory.exists()) {
      if (!create) return null;
      await directory.create();
      await _hideOnWindows(directory);
    }
    return Directory(
      await _pathGuard.resolve(rootId, _quarantineFolder, allowInternal: true),
    );
  }

  File _quarantinePayload(Directory directory, String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.payload');

  File _quarantineRecord(Directory directory, String id) =>
      File('${directory.path}${Platform.pathSeparator}$id.json');

  /// Moves a finished upload out of the shared folder until it is scanned.
  Future<QuarantinedUpload> _quarantine(
    String rootId,
    String relativePath,
    File part, {
    required int size,
    required String? sha256,
    required DeviceIdentity identity,
  }) async {
    final directory = await _quarantineDirectory(rootId);
    final item = QuarantinedUpload(
      id:
          '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
          '${_random.nextInt(1 << 32).toRadixString(16)}',
      root: rootId,
      path: relativePath,
      size: size,
      uploadedAt: DateTime.now().toUtc(),
      status: _scanner == null
          ? QuarantineStatus.held
          : QuarantineStatus.scanning,
      deviceName: identity.name,
      sha256: sha256,
      scanner: _scanner?.name,
    );
    await markFromInternet(part);
    final payload = _quarantinePayload(directory, item.id);
    await part.rename(payload.path);
    await _quarantineRecord(
      directory,
      item.id,
    ).writeAsString(item.encode(), flush: true);
    await _safeAudit(
      action: 'files.upload.quarantine',
      outcome: item.status.name,
      identity: identity,
      rootId: rootId,
      relativePath: relativePath,
      details: <String, Object?>{'size': size, 'sha256': ?sha256},
    );
    _events.add('quarantine');
    if (item.status == QuarantineStatus.scanning) _queueScan(item);
    return item;
  }

  /// Scans run one at a time so a burst of uploads cannot overload the PC.
  void _queueScan(QuarantinedUpload item) {
    _scans = _scans.then((_) => _scan(item)).catchError((Object error) {
      config.log('Upload scan failed: $error');
    });
  }

  Future<void> _scan(QuarantinedUpload item) async {
    final directory = await _quarantineDirectory(item.root);
    final payload = _quarantinePayload(directory, item.id);
    if (!await payload.exists()) return;
    final verdict = await _scanner!.scan(payload);
    if (verdict == ScanVerdict.clean) {
      final path = await _releaseQuarantined(item, by: 'scanner');
      if (path != null) return;
    }
    item.status = verdict == ScanVerdict.threat
        ? QuarantineStatus.blocked
        : QuarantineStatus.held;
    await _quarantineRecord(
      directory,
      item.id,
    ).writeAsString(item.encode(), flush: true);
    await _safeAudit(
      action: 'files.upload.scan',
      outcome: item.status.name,
      rootId: item.root,
      relativePath: item.path,
      details: <String, Object?>{'scanner': ?item.scanner},
    );
    _events.add('quarantine');
  }

  /// Moves a quarantined upload to the folder the phone chose, renaming it
  /// when that name was taken meanwhile. Returns the final path.
  Future<String?> _releaseQuarantined(
    QuarantinedUpload item, {
    required String by,
  }) async {
    final directory = await _quarantineDirectory(item.root);
    final payload = _quarantinePayload(directory, item.id);
    if (!await payload.exists()) return null;
    final lockKey = '${item.root}:${item.path}';
    return _uploadLocks.run(Platform.isWindows ? lockKey.toLowerCase() : lockKey, () async {
      var path = item.path;
      var target = await _pathGuard.resolve(
        item.root,
        path,
        mustExist: false,
        allowRoot: false,
      );
      for (
        var copy = 2;
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound;
        copy++
      ) {
        final dot = item.path.lastIndexOf('.');
        final slash = item.path.lastIndexOf('/');
        path = dot > slash + 1
            ? '${item.path.substring(0, dot)} ($copy)${item.path.substring(dot)}'
            : '${item.path} ($copy)';
        target = await _pathGuard.resolve(
          item.root,
          path,
          mustExist: false,
          allowRoot: false,
        );
      }
      await File(target).parent.create(recursive: true);
      await payload.rename(target);
      final record = _quarantineRecord(directory, item.id);
      if (await record.exists()) await record.delete();
      await _safeAudit(
        action: 'files.upload.release',
        outcome: 'success',
        rootId: item.root,
        relativePath: path,
        details: <String, Object?>{'by': by},
      );
      _events.add('quarantine');
      return path;
    });
  }

  /// Uploads held out of the shared folders, newest first.
  Future<List<QuarantinedUpload>> quarantined() async {
    final items = <QuarantinedUpload>[];
    for (final rootId in _pathGuard.roots.keys) {
      final directory = await _existingQuarantine(rootId);
      if (directory == null) continue;
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          final item = QuarantinedUpload.fromJson(
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
          );
          if (item.root == rootId) items.add(item);
        } on Object {
          // A damaged record leaves its payload for manual cleanup.
        }
      }
    }
    items.sort((a, b) => b.uploadedAt.compareTo(a.uploadedAt));
    return items;
  }

  Future<QuarantinedUpload> _findQuarantined(String rootId, String id) async {
    if (!QuarantinedUpload.idPattern.hasMatch(id)) {
      throw const _ApiException(400, 'invalid_id', 'Invalid upload id.');
    }
    for (final item in await quarantined()) {
      if (item.root == rootId && item.id == id) return item;
    }
    throw const _ApiException(404, 'not_found', 'Held upload was not found.');
  }

  /// Releases an upload no scanner could check. Flagged uploads cannot be
  /// released.
  Future<String> releaseQuarantined(String rootId, String id) async {
    final item = await _findQuarantined(rootId, id);
    if (item.status != QuarantineStatus.held) {
      throw _ApiException(
        409,
        'not_releasable',
        item.status == QuarantineStatus.blocked
            ? '${item.scanner ?? 'The scanner'} found a threat in this file.'
            : 'This file is still being scanned.',
      );
    }
    final path = await _releaseQuarantined(item, by: 'owner');
    if (path == null) {
      throw const _ApiException(404, 'not_found', 'Held upload was not found.');
    }
    return path;
  }

  Future<void> deleteQuarantined(String rootId, String id) async {
    final item = await _findQuarantined(rootId, id);
    final directory = await _quarantineDirectory(rootId);
    final payload = _quarantinePayload(directory, item.id);
    if (await payload.exists()) await payload.delete();
    await _quarantineRecord(directory, item.id).delete();
    await _safeAudit(
      action: 'files.upload.discard',
      outcome: 'success',
      rootId: rootId,
      relativePath: item.path,
    );
    _events.add('quarantine');
  }

  /// Scans that a restart interrupted start again.
  Future<void> _resumeScans() async {
    for (final item in await quarantined()) {
      if (item.status != QuarantineStatus.scanning) continue;
      if (_scanner == null) {
        item.status = QuarantineStatus.held;
        final directory = await _quarantineDirectory(item.root);
        await _quarantineRecord(
          directory,
          item.id,
        ).writeAsString(item.encode(), flush: true);
      } else {
        _queueScan(item);
      }
    }
  }

  /// Waits for queued upload scans, for tests and shutdown.
  Future<void> get scansSettled => _scans;

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
      if (type == FileSystemEntityType.file) 'version': _version(stat),
    };
  }

  /// Changes whenever the file's size or modification time does. Sent as
  /// the download ETag and checked by `If-Match` and change requests.
  static String _version(FileStat stat) =>
      '${stat.size}:${stat.modified.toUtc().microsecondsSinceEpoch}';

  static String? _unquoteTag(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.length >= 2 &&
            trimmed.startsWith('"') &&
            trimmed.endsWith('"')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
  }

  /// Rejects a change made against an older listing of a file, so a phone
  /// never silently moves or trashes a newer version.
  static Future<void> _checkVersion(
    String absolutePath,
    Map<String, dynamic> body,
  ) async {
    final expected = body['version'];
    if (expected == null) return;
    if (expected is! String || expected.length > 64) {
      throw const FormatException('version must be a string.');
    }
    final stat = await FileStat.stat(absolutePath);
    if (stat.type == FileSystemEntityType.file && _version(stat) != expected) {
      throw const _ApiException(
        412,
        'file_changed',
        'The PC file changed. Refresh the folder and try again.',
      );
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
    if (request.contentLength > config.maxJsonBytes) {
      request.response.persistentConnection = false;
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
        request.response.persistentConnection = false;
        throw const _ApiException(
          413,
          'body_too_large',
          'Request body is too large.',
        );
      }
    }
    if (_signed[request] == true &&
        !constantTimeEquals(
          request.headers.value(SignedHeaders.bodyHashHeader) ?? '',
          sha256Hex(bytes),
        )) {
      throw const _ApiException(
        401,
        'invalid_signature',
        'The signed request body does not match.',
      );
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('JSON body must be an object.');
    }
    final identity = _identities[request];
    if (identity != null && value['root'] is String) {
      _checkRoot(identity, value['root'] as String);
    }
    return value;
  }

  Future<void> _handleThumbnail(
    HttpRequest request,
    DeviceIdentity identity,
  ) async {
    final rootId = _requiredQuery(request, 'root');
    final relativePath = _requiredQuery(request, 'path');
    final size = switch (int.tryParse(
      request.uri.queryParameters['size'] ?? '',
    )) {
      final value? when value <= 256 => 256,
      final value? when value <= 512 => 512,
      _ => 1024,
    };
    final file = File(
      await _pathGuard.resolve(rootId, relativePath, allowRoot: false),
    );
    if (!await file.exists()) {
      throw const _ApiException(400, 'not_a_file', 'Path is not a file.');
    }
    if (!ThumbnailCache.supports(relativePath)) {
      throw const _ApiException(
        415,
        'thumbnail_unsupported',
        'Previews are available for common photo formats.',
      );
    }
    final File thumbnail;
    try {
      thumbnail = await _thumbnails.thumbnail(file, size);
    } on FormatException {
      throw const _ApiException(
        415,
        'thumbnail_unsupported',
        'This photo could not be previewed.',
      );
    }
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, 'image/jpeg')
      ..headers.set('Cache-Control', 'private, max-age=86400')
      ..contentLength = await thumbnail.length();
    await request.response.addStream(thumbnail.openRead());
    await request.response.close();
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
      config.log('Could not write audit log: $error');
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
