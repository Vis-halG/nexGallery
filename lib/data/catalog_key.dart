import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import '../services/remote/protected_file.dart';

/// Windows stores only a DPAPI-wrapped key. Android callers supply Keystore
/// callbacks so the server library never depends on a Flutter platform channel.
abstract final class CatalogKey {
  static const secretName = 'catalogue.aes256.v1';

  static Future<SecretKey> load(
    Directory directory, {
    required bool create,
    Future<String?> Function()? readSecret,
    Future<void> Function(String)? writeSecret,
  }) async {
    final file = File('${directory.path}/catalogue.key');
    final encoded = readSecret != null
        ? await readSecret()
        : await file.exists()
        ? utf8.decode(await ProtectedFile.read(file))
        : null;
    if (encoded != null) {
      final key = base64Decode(encoded);
      if (key.length != 32) {
        throw const FormatException('Invalid catalogue key.');
      }
      return SecretKey(key);
    }
    if (!create) throw StateError('The OS catalogue key is unavailable.');
    if (writeSecret == null && !Platform.isWindows) {
      throw UnsupportedError('An OS secret store is required for encryption.');
    }
    final key = await AesGcm.with256bits().newSecretKey();
    final value = base64Encode(await key.extractBytes());
    if (writeSecret != null) {
      await writeSecret(value);
    } else {
      await ProtectedFile.write(file, utf8.encode(value));
    }
    return key;
  }
}
