import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'sha256.dart';

final class DeviceIdentity {
  const DeviceIdentity({
    required this.id,
    required this.name,
    required this.tokenId,
    required this.createdAt,
    this.lastUsedAt,
  });

  final String id;
  final String name;
  final String tokenId;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  Map<String, Object?> toPublicJson() => <String, Object?>{
    'deviceId': id,
    'deviceName': name,
    'tokenId': tokenId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toUtc().toIso8601String(),
  };
}

final class IssuedToken {
  const IssuedToken({required this.token, required this.identity});

  final String token;
  final DeviceIdentity identity;
}

/// Persistent bearer-token store. Only salted SHA-256 token hashes are stored.
/// The raw token is returned once during pairing and cannot be recovered later.
final class DeviceTokenStore {
  DeviceTokenStore(this.file);

  final File file;
  final Random _random = Random.secure();
  final List<_StoredToken> _tokens = <_StoredToken>[];
  Future<void> _queue = Future<void>.value();

  Future<void> load() async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) {
      return;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> || decoded['tokens'] is! List) {
      throw const FormatException('Invalid token store.');
    }
    _tokens
      ..clear()
      ..addAll(
        (decoded['tokens'] as List<Object?>)
            .whereType<Map<String, dynamic>>()
            .map(_StoredToken.fromJson),
      );
  }

  Future<IssuedToken> issue(String requestedName) => _serialize(() async {
    final name = _cleanDeviceName(requestedName);
    final rawToken = _randomText(32);
    final salt = _randomText(18);
    final now = DateTime.now().toUtc();
    final stored = _StoredToken(
      deviceId: _randomText(12),
      deviceName: name,
      tokenId: _randomText(9),
      salt: salt,
      hash: sha256Hex(utf8.encode('$salt:$rawToken')),
      createdAt: now,
      lastUsedAt: null,
    );
    _tokens.add(stored);
    await _save();
    return IssuedToken(token: rawToken, identity: stored.identity);
  });

  Future<DeviceIdentity?> authenticate(String rawToken) async {
    if (rawToken.length < 20 || rawToken.length > 256) {
      return null;
    }
    _StoredToken? match;
    for (final token in _tokens) {
      final candidate = sha256Hex(utf8.encode('${token.salt}:$rawToken'));
      if (constantTimeEquals(candidate, token.hash)) {
        match = token;
      }
    }
    if (match == null) {
      return null;
    }
    final current = match;
    final now = DateTime.now().toUtc();
    // Limit disk writes while still keeping useful activity metadata.
    if (current.lastUsedAt == null ||
        now.difference(current.lastUsedAt!).inMinutes >= 10) {
      await _serialize(() async {
        current.lastUsedAt = now;
        await _save();
      });
    }
    return current.identity;
  }

  List<DeviceIdentity> list() =>
      _tokens.map((token) => token.identity).toList(growable: false);

  Future<bool> revoke(String tokenId) => _serialize(() async {
    final before = _tokens.length;
    _tokens.removeWhere((token) => token.tokenId == tokenId);
    if (_tokens.length == before) {
      return false;
    }
    await _save();
    return true;
  });

  Future<void> _save() async {
    final temporary = File('${file.path}.tmp');
    final data = <String, Object?>{
      'version': 1,
      'tokens': _tokens.map((token) => token.toJson()).toList(),
    };
    await temporary.writeAsString(jsonEncode(data), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await temporary.rename(file.path);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  String _randomText(int byteCount) {
    final bytes = List<int>.generate(byteCount, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String _cleanDeviceName(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'[\x00-\x1f]'), '');
    if (normalized.isEmpty || normalized.length > 80) {
      throw const FormatException('Device name must be 1 to 80 characters.');
    }
    return normalized;
  }
}

final class _StoredToken {
  _StoredToken({
    required this.deviceId,
    required this.deviceName,
    required this.tokenId,
    required this.salt,
    required this.hash,
    required this.createdAt,
    required this.lastUsedAt,
  });

  factory _StoredToken.fromJson(Map<String, dynamic> json) => _StoredToken(
    deviceId: json['deviceId'] as String,
    deviceName: json['deviceName'] as String,
    tokenId: json['tokenId'] as String,
    salt: json['salt'] as String,
    hash: json['hash'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    lastUsedAt: json['lastUsedAt'] == null
        ? null
        : DateTime.parse(json['lastUsedAt'] as String).toUtc(),
  );

  final String deviceId;
  final String deviceName;
  final String tokenId;
  final String salt;
  final String hash;
  final DateTime createdAt;
  DateTime? lastUsedAt;

  DeviceIdentity get identity => DeviceIdentity(
    id: deviceId,
    name: deviceName,
    tokenId: tokenId,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'deviceId': deviceId,
    'deviceName': deviceName,
    'tokenId': tokenId,
    'salt': salt,
    'hash': hash,
    'createdAt': createdAt.toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };
}

final class AuditLog {
  AuditLog(this.file);

  final File file;
  Future<void> _queue = Future<void>.value();

  Future<void> record({
    required String action,
    required String outcome,
    String? deviceId,
    String? remoteAddress,
    String? rootId,
    String? relativePath,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    final entry = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'action': action,
      'outcome': outcome,
      'deviceId': ?deviceId,
      'remoteAddress': ?remoteAddress,
      'rootId': ?rootId,
      'path': ?relativePath,
      if (details.isNotEmpty) 'details': details,
    };
    _queue = _queue
        .catchError((_) {
          // A transient logging failure must not permanently poison later writes.
        })
        .then((_) async {
          await file.parent.create(recursive: true);
          await file.writeAsString(
            '${jsonEncode(entry)}\n',
            mode: FileMode.append,
            flush: true,
          );
        });
    return _queue;
  }
}

final class FixedWindowRateLimiter {
  FixedWindowRateLimiter({required this.limit, required this.window});

  final int limit;
  final Duration window;
  final Map<String, _RateWindow> _windows = <String, _RateWindow>{};

  bool allow(String key) {
    final now = DateTime.now();
    final current = _windows[key];
    if (current == null || now.difference(current.startedAt) >= window) {
      _windows[key] = _RateWindow(now, 1);
      if (_windows.length > 2048) {
        _windows.removeWhere(
          (_, value) => now.difference(value.startedAt) >= window,
        );
      }
      return true;
    }
    current.count += 1;
    return current.count <= limit;
  }
}

final class _RateWindow {
  _RateWindow(this.startedAt, this.count);

  final DateTime startedAt;
  int count;
}
