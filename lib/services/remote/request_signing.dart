import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// Headers that every signed request carries. The body of large uploads is
/// not signed (TLS protects it and the final SHA-256 is verified); small JSON
/// bodies are bound through [bodyHashHeader].
abstract final class SignedHeaders {
  static const device = 'x-nex-device';
  static const timestamp = 'x-nex-timestamp';
  static const nonce = 'x-nex-nonce';
  static const signature = 'x-nex-signature';
  static const bodyHashHeader = 'x-nex-body-sha256';

  /// Request headers whose values are covered by the signature.
  static const covered = <String>[
    bodyHashHeader,
    'range',
    'x-nex-file-version',
    'x-upload-id',
    'x-upload-offset',
    'x-upload-total',
    'x-upload-complete',
    'x-upload-create-parents',
    'x-content-sha256',
  ];
}

/// The exact bytes a device signs: method, path, raw query, time, nonce,
/// token id and the covered header values, one per line.
List<int> canonicalRequest({
  required String method,
  required String path,
  required String query,
  required String timestamp,
  required String nonce,
  required String tokenId,
  required String? Function(String name) header,
}) => utf8.encode(
  [
    'nexGallery-request-v1',
    method.toUpperCase(),
    path,
    query,
    timestamp,
    nonce,
    tokenId,
    for (final name in SignedHeaders.covered) '$name:${header(name) ?? ''}',
  ].join('\n'),
);

final class DeviceKey {
  DeviceKey._(this._keyPair, this.publicKey);

  final SimpleKeyPair _keyPair;

  /// Base64url Ed25519 public key sent to the PC during pairing.
  final String publicKey;

  static final _algorithm = Ed25519();

  static Future<DeviceKey> generate() async {
    final pair = await _algorithm.newKeyPair();
    return DeviceKey._(pair, await _publicText(pair));
  }

  /// Restores a key from its 32-byte private seed.
  static Future<DeviceKey> fromSeed(String seed) async {
    final bytes = base64Url.decode(base64Url.normalize(seed));
    if (bytes.length != 32) throw const FormatException('Invalid device key.');
    final pair = await _algorithm.newKeyPairFromSeed(bytes);
    return DeviceKey._(pair, await _publicText(pair));
  }

  Future<String> seed() async =>
      base64Url.encode(await _keyPair.extractPrivateKeyBytes());

  Future<String> sign(List<int> message) async {
    final signature = await _algorithm.sign(message, keyPair: _keyPair);
    return base64Url.encode(signature.bytes);
  }

  static Future<String> _publicText(SimpleKeyPair pair) async =>
      base64Url.encode((await pair.extractPublicKey()).bytes);
}

Future<bool> verifyDeviceSignature({
  required String publicKey,
  required String signature,
  required List<int> message,
}) async {
  try {
    final key = base64Url.decode(base64Url.normalize(publicKey));
    final bytes = base64Url.decode(base64Url.normalize(signature));
    if (key.length != 32 || bytes.length != 64) return false;
    return await Ed25519().verify(
      message,
      signature: Signature(
        bytes,
        publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
      ),
    );
  } on FormatException {
    return false;
  }
}

bool isValidPublicKey(String value) {
  try {
    return base64Url.decode(base64Url.normalize(value)).length == 32;
  } on FormatException {
    return false;
  }
}

String randomNonce() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(18, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// Rejects stale timestamps and reused nonces for [window] in each direction.
final class ReplayGuard {
  ReplayGuard({
    this.window = const Duration(minutes: 5),
    this.capacity = 50000,
  });

  final Duration window;
  final int capacity;
  final Map<String, DateTime> _seen = <String, DateTime>{};

  /// Returns null when accepted, otherwise the rejection reason.
  String? check(
    String tokenId,
    String timestamp,
    String nonce, {
    DateTime? now,
  }) {
    final current = (now ?? DateTime.now()).toUtc();
    final millis = int.tryParse(timestamp);
    if (millis == null) return 'invalid_timestamp';
    final sent = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    if (current.difference(sent).abs() > window) return 'stale_request';
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(nonce)) {
      return 'invalid_nonce';
    }
    if (_seen.length >= capacity) {
      _seen.removeWhere((_, expires) => !expires.isAfter(current));
      if (_seen.length >= capacity) return 'replay_cache_full';
    }
    final key = '$tokenId:$nonce';
    final previous = _seen[key];
    if (previous != null && previous.isAfter(current)) {
      return 'replayed_request';
    }
    _seen[key] = current.add(window * 2);
    return null;
  }
}
