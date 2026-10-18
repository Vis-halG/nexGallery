import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';

/// Password-encrypted export of albums, favorites, archive state and `user.*`
/// corrections. Media bytes are never included.
abstract final class OrganizationBackup {
  static const _aad = 'nexGallery-organization-v1';
  static const _magic = 'nexGallery.organization';

  static Future<Uint8List> encrypt(
    CatalogSnapshot snapshot,
    String password, {
    int iterations = 310000,
  }) async {
    if (password.length < 10) {
      throw const FormatException(
        'Use a password with at least 10 characters.',
      );
    }
    final clear = utf8.encode(
      jsonEncode({
        'albums': [
          for (final album in snapshot.albums)
            if (!album.isReadOnly) album.toJson(),
        ],
        'items': {
          for (final item in snapshot.items)
            if (item.isFavorite ||
                item.section == MediaSection.archive ||
                item.metadata.attributes.keys.any((k) => k.startsWith('user.')))
              item.id: {
                'favorite': item.isFavorite,
                'section': item.section.name,
                'attributes': {
                  for (final entry in item.metadata.attributes.entries)
                    if (entry.key.startsWith('user.')) entry.key: entry.value,
                },
              },
        },
      }),
    );
    final cipher = AesGcm.with256bits();
    final salt = cipher.newNonce() + cipher.newNonce();
    final key = await _derive(password, salt, iterations);
    final box = await cipher.encrypt(
      clear,
      secretKey: key,
      aad: utf8.encode(_aad),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': _magic,
          'version': 1,
          'iterations': iterations,
          'salt': base64Encode(salt),
          'box': base64Encode(box.concatenation()),
        }),
      ),
    );
  }

  static Future<
    ({List<MediaAlbum> albums, Map<String, OrganizationRecord> items})
  >
  decrypt(Uint8List backup, String password) async {
    if (backup.length > 64 << 20) {
      throw const FormatException('The backup is too large.');
    }
    final Map<String, dynamic> outer;
    try {
      outer = jsonDecode(utf8.decode(backup)) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException(
        'This is not a nexGallery organization backup.',
      );
    }
    if (outer['format'] != _magic || outer['version'] != 1) {
      throw const FormatException(
        'This is not a nexGallery organization backup.',
      );
    }
    final iterations = outer['iterations'];
    final salt = base64Decode(outer['salt'] as String);
    if (iterations is! int ||
        iterations < 100000 ||
        iterations > 2000000 ||
        salt.length != 24) {
      throw const FormatException('The backup key parameters are invalid.');
    }
    final key = await _derive(password, salt, iterations);
    final List<int> clear;
    try {
      clear = await AesGcm.with256bits().decrypt(
        SecretBox.fromConcatenation(
          base64Decode(outer['box'] as String),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: utf8.encode(_aad),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('Wrong password or damaged backup.');
    }
    final inner = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    final albums = [
      for (final value in inner['albums'] as List)
        MediaAlbum.fromJson(Map<String, Object?>.from(value as Map)),
    ];
    final items = <String, OrganizationRecord>{};
    for (final entry in (inner['items'] as Map).entries) {
      final value = Map<String, Object?>.from(entry.value as Map);
      items[entry.key as String] = (
        favorite: value['favorite'] == true,
        section: MediaSection.values.firstWhere(
          (section) => section.name == value['section'],
          orElse: () => MediaSection.library,
        ),
        attributes: {
          for (final attribute in (value['attributes'] as Map? ?? {}).entries)
            if ('${attribute.key}'.startsWith('user.'))
              '${attribute.key}': '${attribute.value}',
        },
      );
    }
    return (albums: albums, items: items);
  }

  static Future<SecretKey> _derive(
    String password,
    List<int> salt,
    int rounds,
  ) => Isolate.run(() async {
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: rounds,
      bits: 256,
    ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    return SecretKey(await key.extractBytes());
  });
}
