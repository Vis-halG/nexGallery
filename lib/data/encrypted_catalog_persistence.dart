import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/catalog_models.dart';
import 'catalog_persistence_base.dart';

/// An authenticated, compressed snapshot. Neither staging files nor backups
/// contain plaintext. The 256-bit key is held by the OS secret store.
final class EncryptedCatalogPersistence implements CloseableCatalogPersistence {
  EncryptedCatalogPersistence(this.filePath, this.key);

  final String filePath;
  final SecretKey key;
  static const maximumBytes = 256 << 20;
  static final _magic = utf8.encode('NEXCAT1\n');
  static final _aad = utf8.encode('nexGallery.catalogue.v1');
  final _cipher = AesGcm.with256bits();
  Future<void> _pending = Future.value();
  bool _closed = false;
  bool _blocked = false;

  Future<T> _enqueue<T>(Future<T> Function() work) {
    if (_closed) return Future.error(StateError('Catalogue is closed.'));
    final result = _pending.then((_) => work());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<CatalogSnapshot> load() => _enqueue(() async {
    try {
      final file = File(filePath);
      final previous = File('$filePath.previous');
      if (!await file.exists() && await previous.exists()) {
        await previous.rename(filePath);
      }
      if (!await file.exists()) return CatalogSnapshot.empty();
      if (await file.length() > maximumBytes) {
        throw const FormatException('Encrypted catalogue is too large.');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length < _magic.length + 28 ||
          !List.generate(
            _magic.length,
            (i) => bytes[i] == _magic[i],
          ).every((v) => v)) {
        throw const FormatException('Invalid encrypted catalogue.');
      }
      final compressed = await _cipher.decrypt(
        SecretBox.fromConcatenation(
          bytes.sublist(_magic.length),
          nonceLength: 12,
          macLength: 16,
        ),
        secretKey: key,
        aad: _aad,
      );
      // Bound decompression before JSON allocation as well as input size.
      final sink = _BoundedBytes(maximumBytes);
      final decoder = gzip.decoder.startChunkedConversion(sink);
      decoder.add(compressed);
      decoder.close();
      final decoded = jsonDecode(utf8.decode(sink.bytes.takeBytes()));
      if (decoded is! Map<String, dynamic> ||
          decoded['schemaVersion'] != CatalogSnapshot.currentSchemaVersion) {
        throw const FormatException('Unsupported encrypted catalogue schema.');
      }
      _blocked = false;
      return CatalogSnapshot.fromJson(decoded);
    } catch (_) {
      _blocked = true;
      rethrow;
    }
  });

  @override
  Future<void> save(CatalogSnapshot snapshot) => _enqueue(() async {
    if (_blocked) throw StateError('A failed load blocks catalogue writes.');
    final json = utf8.encode(jsonEncode(snapshot.toJson()));
    if (json.length > maximumBytes) {
      throw const FormatException(
        'Catalogue exceeds the encrypted size limit.',
      );
    }
    final box = await _cipher.encrypt(
      gzip.encode(json),
      secretKey: key,
      aad: _aad,
    );
    final file = File(filePath);
    await file.parent.create(recursive: true);
    final staging = File('$filePath.$pid.tmp');
    final previous = File('$filePath.previous');
    await staging.writeAsBytes([
      ..._magic,
      ...box.concatenation(),
    ], flush: true);
    if (await previous.exists()) await previous.delete();
    if (await file.exists()) await file.rename(previous.path);
    try {
      await staging.rename(filePath);
    } catch (_) {
      if (!await file.exists() && await previous.exists()) {
        await previous.rename(filePath);
      }
      rethrow;
    }
  });

  @override
  Future<void> close() async {
    _closed = true;
    await _pending;
  }
}

final class _BoundedBytes implements Sink<List<int>> {
  _BoundedBytes(this.limit);
  final int limit;
  final bytes = BytesBuilder(copy: false);
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > limit) {
      throw const FormatException('Decompressed catalogue exceeds the limit.');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
