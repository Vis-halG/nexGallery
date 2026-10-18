import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../files/file_tools.dart';

final class VaultEntry {
  const VaultEntry(this.id, this.name, this.bytes, this.addedAt);
  final String id;
  final String name;
  final int bytes;
  final DateTime addedAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'bytes': bytes,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };
  factory VaultEntry.fromJson(Map<String, dynamic> value) {
    final id = value['id'] as String;
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const FormatException('Invalid vault entry.');
    }
    return VaultEntry(
      id,
      safeName(value['name'] as String),
      value['bytes'] as int,
      DateTime.parse(value['addedAt'] as String),
    );
  }
}

/// Password-derived AES-256-GCM, with authenticated, bounded 1 MB chunks.
/// The encrypted manifest hides names and binds each chunk to its file and index.
final class VaultStore {
  VaultStore(this.directory, {this.iterations = 600000});
  final Directory directory;
  final int iterations;
  static const chunkBytes = 1 << 20;
  final _cipher = AesGcm.with256bits();
  SecretKey? _key;
  List<int>? _salt;
  List<VaultEntry> _entries = [];
  int _generation = 0;
  bool _busy = false;
  bool get unlocked => _key != null;
  List<VaultEntry> get entries => List.unmodifiable(_entries);
  File get _manifest => File(p.join(directory.path, 'vault.json'));

  Future<bool> exists() async {
    final previous = File('${_manifest.path}.previous');
    if (!await _manifest.exists() && await previous.exists()) {
      await previous.rename(_manifest.path);
    }
    return _manifest.exists();
  }

  Future<void> unlock(String password, {bool create = false}) async {
    if (_busy) throw StateError('A vault operation is already running.');
    lock();
    _busy = true;
    final generation = ++_generation;
    try {
      await directory.create(recursive: true);
      if (!await exists()) {
        if (!create) throw StateError('Create a vault first.');
        if (password.length < 10) {
          throw const FormatException(
            'Use a password with at least 10 characters.',
          );
        }
        _salt = _cipher.newNonce() + _cipher.newNonce();
        final key = await _derive(password, _salt!, iterations);
        if (generation != _generation) {
          key.destroy();
          throw StateError('Vault was locked.');
        }
        _key = key;
        _entries = [];
        await _save();
        return;
      }
      if (await _manifest.length() > 16 << 20) {
        throw const FormatException('Vault index is too large.');
      }
      final raw =
          jsonDecode(await _manifest.readAsString()) as Map<String, dynamic>;
      if (raw['version'] != 1) {
        throw const FormatException('Unsupported vault format.');
      }
      final count = raw['iterations'] as int;
      if (count < 100000 || count > 2000000) {
        throw const FormatException('Invalid vault key parameters.');
      }
      final salt = base64Decode(raw['salt'] as String);
      if (salt.length != 24) throw const FormatException('Invalid vault salt.');
      final key = await _derive(password, salt, count);
      try {
        final clear = await _cipher.decrypt(
          _box(raw['box'] as String),
          secretKey: key,
          aad: utf8.encode('nexGallery-vault-v1'),
        );
        final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        if (generation != _generation) throw StateError('Vault was locked.');
        _entries = (decoded['entries'] as List)
            .map(
              (v) => VaultEntry.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList();
        _salt = salt;
        _key = key;
        _storedIterations = count;
      } catch (_) {
        key.destroy();
        rethrow;
      }
    } catch (_) {
      lock();
      rethrow;
    } finally {
      _busy = false;
    }
  }

  int? _storedIterations;
  Future<SecretKey> _derive(String password, List<int> salt, int rounds) =>
      Isolate.run(() async {
        final key = await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: rounds,
          bits: 256,
        ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
        return SecretKey(await key.extractBytes());
      });

  Future<void> _save() async {
    final key = _key;
    if (key == null) throw StateError('Unlock the vault first.');
    final box = await _cipher.encrypt(
      utf8.encode(
        jsonEncode({'entries': _entries.map((v) => v.toJson()).toList()}),
      ),
      secretKey: key,
      aad: utf8.encode('nexGallery-vault-v1'),
    );
    final temporary = File('${_manifest.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'iterations': _storedIterations ?? iterations,
        'salt': base64Encode(_salt!),
        'box': base64Encode(box.concatenation()),
      }),
      flush: true,
    );
    final backup = File('${_manifest.path}.previous');
    if (await backup.exists()) await backup.delete();
    if (await _manifest.exists()) await _manifest.rename(backup.path);
    try {
      await temporary.rename(_manifest.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(_manifest.path);
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  SecretBox _box(String value) => SecretBox.fromConcatenation(
    base64Decode(value),
    nonceLength: 12,
    macLength: 16,
  );

  Future<void> add(
    File source,
    String name, {
    void Function(int, int)? onProgress,
  }) async {
    if (_key == null || _busy) {
      throw StateError('Unlock the vault and wait for the current operation.');
    }
    final key = _key!;
    final generation = _generation;
    final safe = safeName(name);
    _busy = true;
    File? target;
    File? temporary;
    RandomAccessFile? input;
    RandomAccessFile? output;
    try {
      final entry = VaultEntry(
        uniqueId(),
        safe,
        await source.length(),
        DateTime.now().toUtc(),
      );
      target = File(p.join(directory.path, '${entry.id}.vault'));
      temporary = File('${target.path}.part');
      input = await source.open();
      output = await temporary.open(mode: FileMode.write);
      var index = 0;
      var total = 0;
      do {
        final chunk = await input.read(chunkBytes);
        if (total + chunk.length > entry.bytes) {
          throw const FileSystemException(
            'The original changed during encryption.',
          );
        }
        final box = await _cipher.encrypt(
          chunk,
          secretKey: key,
          aad: utf8.encode('${entry.id}:$index:${entry.bytes}'),
        );
        final encrypted = box.concatenation();
        final length = ByteData(4)..setUint32(0, encrypted.length);
        await output.writeFrom(length.buffer.asUint8List());
        await output.writeFrom(encrypted);
        total += chunk.length;
        onProgress?.call(total, entry.bytes);
        if (generation != _generation) throw StateError('Vault was locked.');
        index++;
        if (total == entry.bytes) break;
        if (chunk.isEmpty) {
          throw const FileSystemException(
            'The original changed during encryption.',
          );
        }
      } while (true);
      if (await input.length() != entry.bytes) {
        throw const FileSystemException(
          'The original changed during encryption.',
        );
      }
      await output.flush();
      await output.close();
      output = null;
      await temporary.rename(target.path);
      _entries.add(entry);
      try {
        await _save();
      } catch (_) {
        _entries.remove(entry);
        rethrow;
      }
    } catch (_) {
      if (target != null && await target.exists()) await target.delete();
      rethrow;
    } finally {
      await input?.close();
      await output?.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      _busy = false;
    }
  }

  Future<File> decrypt(VaultEntry entry, File destination) async {
    if (_key == null || _busy || !_entries.any((v) => v.id == entry.id)) {
      throw StateError('Unlock the vault first.');
    }
    if (await destination.exists()) {
      throw const FileSystemException('Export destination exists.');
    }
    _busy = true;
    final key = _key!;
    final generation = _generation;
    RandomAccessFile? input;
    RandomAccessFile? output;
    final temporary = File('${destination.path}.part');
    var complete = false;
    try {
      input = await File(p.join(directory.path, '${entry.id}.vault')).open();
      await temporary.parent.create(recursive: true);
      output = await temporary.open(mode: FileMode.write);
      var index = 0;
      var total = 0;
      do {
        final header = await input.read(4);
        if (header.length != 4) {
          throw const FormatException('Vault file is truncated.');
        }
        final length = ByteData.sublistView(header).getUint32(0);
        if (length < 28 || length > chunkBytes + 28) {
          throw const FormatException('Invalid encrypted chunk.');
        }
        final bytes = await input.read(length);
        if (bytes.length != length) {
          throw const FormatException('Vault file is truncated.');
        }
        final clear = await _cipher.decrypt(
          SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
          secretKey: key,
          aad: utf8.encode('${entry.id}:$index:${entry.bytes}'),
        );
        total += clear.length;
        if (total > entry.bytes || (clear.isEmpty && entry.bytes != 0)) {
          throw const FormatException('Invalid vault content length.');
        }
        await output.writeFrom(clear);
        if (generation != _generation) throw StateError('Vault was locked.');
        index++;
      } while (total < entry.bytes);
      if (await input.position() != await input.length()) {
        throw const FormatException('Vault file has unexpected data.');
      }
      await output.flush();
      await output.close();
      output = null;
      if (generation != _generation) throw StateError('Vault was locked.');
      if (await destination.exists()) {
        throw const FileSystemException('Export destination exists.');
      }
      final result = await temporary.rename(destination.path);
      complete = true;
      return result;
    } finally {
      await input?.close();
      await output?.close();
      _busy = false;
      if (!complete && await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> remove(VaultEntry entry) async {
    if (_key == null || _busy) throw StateError('Unlock the vault first.');
    _busy = true;
    final old = [..._entries];
    try {
      _entries.removeWhere((v) => v.id == entry.id);
      try {
        await _save();
      } catch (_) {
        _entries = old;
        rethrow;
      }
      await File(p.join(directory.path, '${entry.id}.vault')).delete();
    } finally {
      _busy = false;
    }
  }

  /// Writes a recovery ZIP of the manifest and chunk files. Contents stay
  /// encrypted with this vault's password; nothing is decrypted.
  Future<void> exportBackup(File destination) async {
    if (_key == null || _busy) throw StateError('Unlock the vault first.');
    if (await destination.exists()) {
      throw const FileSystemException('Backup destination exists.');
    }
    _busy = true;
    final stage = File('${destination.path}.part');
    final encoder = ZipFileEncoder();
    var open = false;
    try {
      encoder.create(stage.path, level: ZipFileEncoder.store);
      open = true;
      await encoder.addFile(_manifest, 'vault.json');
      for (final entry in _entries) {
        await encoder.addFile(
          File(p.join(directory.path, '${entry.id}.vault')),
          '${entry.id}.vault',
        );
      }
      await encoder.close();
      open = false;
      await stage.rename(destination.path);
    } finally {
      if (open) {
        try {
          await encoder.close();
        } on Object {
          /* already failed */
        }
      }
      if (await stage.exists()) await stage.delete();
      _busy = false;
    }
  }

  /// Re-encrypts every entry of a recovery ZIP into this unlocked vault.
  /// Returns the number of files imported.
  Future<int> importBackup(
    File backup,
    String password, {
    required Directory workspace,
    void Function(int, int)? onProgress,
  }) async {
    if (_key == null || _busy) throw StateError('Unlock the vault first.');
    final unpacked = Directory(p.join(workspace.path, 'import-${uniqueId()}'));
    final clear = Directory(p.join(workspace.path, 'clear-${uniqueId()}'));
    try {
      await FileTools().extractZip(
        backup.path,
        unpacked.path,
        maximumBytes: 64 << 30,
      );
      final source = VaultStore(unpacked, iterations: iterations);
      if (!await source.exists()) {
        throw const FormatException('This is not a nexGallery vault backup.');
      }
      await source.unlock(password);
      try {
        await clear.create(recursive: true);
        var done = 0;
        for (final entry in source.entries) {
          final plain = await source.decrypt(
            entry,
            File(p.join(clear.path, uniqueId())),
          );
          try {
            await add(plain, entry.name);
          } finally {
            if (await plain.exists()) await plain.delete();
          }
          done++;
          onProgress?.call(done, source.entries.length);
        }
        return done;
      } finally {
        source.lock();
      }
    } finally {
      for (final directory in [unpacked, clear]) {
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }

  void lock() {
    _generation++;
    _key?.destroy();
    _key = null;
    _entries = [];
    _salt = null;
  }
}
