import 'dart:convert';
import 'dart:io';

import 'nex_gallery_client.dart' show RemoteApiException;
import 'nex_gallery_server.dart' show PairingCode, PairingRequest;
import 'security.dart';
import 'upload_quarantine.dart';
import 'sha256.dart';

/// Manages a background agent over its loopback owner API. Requests carry the
/// per-user owner secret and pin the agent's certificate.
final class OwnerClient {
  OwnerClient({
    required this.port,
    required this.ownerSecret,
    required String fingerprint,
  }) : _fingerprint = fingerprint.toLowerCase(),
       _http = HttpClient(context: SecurityContext(withTrustedRoots: false))
         ..connectionTimeout = const Duration(seconds: 5) {
    _http.badCertificateCallback = (certificate, host, _) =>
        host == '127.0.0.1' &&
        constantTimeEquals(sha256Hex(certificate.der), _fingerprint);
  }

  final int port;
  final String ownerSecret;
  final String _fingerprint;
  final HttpClient _http;

  Future<Map<String, dynamic>> _call(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final request = await _http
        .openUrl(method, Uri.parse('https://127.0.0.1:$port$path'))
        .timeout(const Duration(seconds: 5));
    request.headers.set('x-nex-owner', ownerSecret);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decodeStream(response);
    final value = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('The agent returned invalid JSON.');
    }
    if (response.statusCode >= 300) {
      final error = value['error'] is Map ? value['error'] as Map : value;
      throw RemoteApiException(
        response.statusCode,
        '${error['code'] ?? 'request_failed'}',
        '${error['message'] ?? 'The background server rejected the request.'}',
      );
    }
    return value;
  }

  Future<bool> isRunning() async {
    try {
      final health = await _call('GET', '/v1/health');
      return health['status'] == 'ok';
    } on Object {
      return false;
    }
  }

  Future<PairingCode> createPairingCode() async {
    final value = await _call('POST', '/v1/pair/code');
    return PairingCode(
      code: value['code'] as String,
      expiresAt: DateTime.parse(value['expiresAt'] as String),
    );
  }

  Future<List<PairingRequest>> pendingPairings() async => [
    for (final request
        in (await _call('GET', '/v1/pair/requests'))['requests'] as List)
      PairingRequest.fromJson(Map<String, dynamic>.from(request as Map)),
  ];

  Future<List<DeviceIdentity>> devices() async => [
    for (final device in (await _call('GET', '/v1/tokens'))['devices'] as List)
      DeviceIdentity.fromPublicJson(Map<String, dynamic>.from(device as Map)),
  ];

  Future<void> approve(
    String requestId, {
    required Set<String> scopes,
    List<String>? roots,
  }) => _call(
    'POST',
    '/v1/pair/approve',
    body: {'requestId': requestId, 'scopes': scopes.toList(), 'roots': ?roots},
  );

  Future<void> deny(String requestId) =>
      _call('POST', '/v1/pair/deny', body: {'requestId': requestId});

  Future<void> revoke(String tokenId) =>
      _call('POST', '/v1/owner/revoke', body: {'tokenId': tokenId});

  Future<void> updatePermissions(
    String tokenId, {
    required Set<String> scopes,
    List<String>? roots,
  }) => _call(
    'POST',
    '/v1/tokens/permissions',
    body: {'tokenId': tokenId, 'scopes': scopes.toList(), 'roots': ?roots},
  );

  Future<List<Map<String, Object?>>> audit({int limit = 200}) async => [
    for (final entry
        in (await _call('GET', '/v1/audit?limit=$limit'))['entries'] as List)
      Map<String, Object?>.from(entry as Map),
  ];

  Future<List<QuarantinedUpload>> quarantined() async => [
    for (final item
        in (await _call('GET', '/v1/quarantine'))['uploads'] as List)
      QuarantinedUpload.fromJson(Map<String, dynamic>.from(item as Map)),
  ];

  Future<String> releaseQuarantined(String root, String id) async =>
      (await _call(
            'POST',
            '/v1/quarantine/release',
            body: {'root': root, 'id': id},
          ))['path']
          as String;

  Future<void> deleteQuarantined(String root, String id) =>
      _call('POST', '/v1/quarantine/delete', body: {'root': root, 'id': id});

  Future<void> shutdown() => _call('POST', '/v1/owner/shutdown');

  void close() => _http.close(force: true);
}
