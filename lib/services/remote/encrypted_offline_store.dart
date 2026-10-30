import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' hide Sha256;
import 'package:path/path.dart' as p;

import '../files/file_tools.dart';
import 'nex_gallery_client.dart';
import 'sha256.dart';

final class OfflineMedia {
  const OfflineMedia(this.file, this.name, this.bytes);
  final File file;
  final String name;
  final int bytes;
}

/// Chunk-authenticated offline media. Even resumable .part files contain only
/// ciphertext; a crash truncates only the last incomplete encrypted frame.
final class EncryptedOfflineStore {
  EncryptedOfflineStore(this.directory, this.key);
  final Directory directory;
  final Future<SecretKey> Function() key;
  static const chunkBytes = 1 << 20;
  static final _magic = utf8.encode('NEXOFF1\n');
  final _cipher = AesGcm.with256bits();

  Future<bool> _isEncrypted(File file) async {
    final input = await file.open();
    try {
      final prefix = await input.read(_magic.length);
      return prefix.length == _magic.length &&
          List.generate(
            _magic.length,
            (i) => prefix[i] == _magic[i],
          ).every((v) => v);
    } finally {
      await input.close();
    }
  }

  Future<_Header> _header(RandomAccessFile input, SecretKey secret) async {
    await input.setPosition(0);
    final prefix = await input.read(_magic.length);
    if (prefix.length != _magic.length ||
        !List.generate(
          _magic.length,
          (i) => prefix[i] == _magic[i],
        ).every((v) => v)) {
      throw const FormatException('Unsupported offline file.');
    }
    final length = await _readLength(input);
    if (length < 28 || length > 65536) {
      throw const FormatException('Invalid offline header.');
    }
    final packet = await input.read(length);
    if (packet.length != length) {
      throw const FormatException('Incomplete offline header.');
    }
    final clear = await _cipher.decrypt(
      SecretBox.fromConcatenation(packet, nonceLength: 12, macLength: 16),
      secretKey: secret,
      aad: _magic,
    );
    final metadata = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    if (metadata['version'] != 1 ||
        metadata['name'] is! String ||
        metadata['bytes'] is! int ||
        (metadata['bytes'] as int) < 0) {
      throw const FormatException('Invalid offline metadata.');
    }
    return _Header(metadata, sha256Hex(packet), await input.position());
  }

  Future<_Header> _writeHeader(
    RandomAccessFile output,
    Map<String, Object?> metadata,
    SecretKey secret,
  ) async {
    final box = await _cipher.encrypt(
      utf8.encode(jsonEncode(metadata)),
      secretKey: secret,
      aad: _magic,
    );
    final packet = box.concatenation();
    await output.writeFrom(_magic);
    await _writeLength(output, packet.length);
    await output.writeFrom(packet);
    await output.flush();
    return _Header(
      Map<String, dynamic>.from(metadata),
      sha256Hex(packet),
      await output.position(),
    );
  }

  Future<void> _append(
    RandomAccessFile output,
    List<int> clear,
    SecretKey secret,
    _Header header,
    int index,
  ) async {
    final box = await _cipher.encrypt(
      clear,
      secretKey: secret,
      aad: utf8.encode('${header.digest}:$index'),
    );
    await _writeLength(output, clear.length);
    await output.writeFrom(box.concatenation());
    await output.flush();
  }

  /// Verifies every saved frame and returns its plaintext offset/count. A torn
  /// final frame can be removed only from a staging file, never a completed one.
  Future<({int bytes, int chunks})> _frames(
    RandomAccessFile input,
    SecretKey secret,
    _Header header, {
    bool repair = false,
    IOSink? output,
  }) async {
    await input.setPosition(header.end);
    final length = await input.length();
    var bytes = 0, index = 0;
    while (await input.position() < length) {
      final start = await input.position();
      if (length - start < 4) {
        if (repair) {
          await input.truncate(start);
          break;
        }
        throw const FormatException('Truncated offline frame.');
      }
      final count = await _readLength(input);
      if (count < 1 ||
          count > chunkBytes ||
          bytes + count > (header.metadata['bytes'] as int)) {
        throw const FormatException('Invalid offline chunk length.');
      }
      if (length - await input.position() < count + 28) {
        if (repair) {
          await input.truncate(start);
          break;
        }
        throw const FormatException('Truncated offline ciphertext.');
      }
      final packet = await input.read(count + 28);
      final clear = await _cipher.decrypt(
        SecretBox.fromConcatenation(packet, nonceLength: 12, macLength: 16),
        secretKey: secret,
        aad: utf8.encode('${header.digest}:$index'),
      );
      output?.add(clear);
      bytes += clear.length;
      index++;
      if (count != chunkBytes && bytes != (header.metadata['bytes'] as int)) {
        throw const FormatException(
          'Only the final offline chunk can be short.',
        );
      }
    }
    return (bytes: bytes, chunks: index);
  }

  Future<void> download(
    NexGalleryRemoteClient client,
    RemoteEntry entry,
    File destination,
    void Function(int, int?) progress,
  ) async {
    if (!p.isWithin(directory.absolute.path, destination.absolute.path)) {
      throw const FormatException(
        'Offline destination must be inside the private cache.',
      );
    }
    final secret = await key();
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      final input = await destination.open();
      try {
        final header = await _header(input, secret);
        final frames = await _frames(input, secret, header);
        if (frames.bytes != header.metadata['bytes']) {
          throw const FormatException('Incomplete offline file.');
        }
        progress(frames.bytes, frames.bytes);
        return;
      } finally {
        await input.close();
      }
    }
    final staging = File('${destination.path}.part');
    // Old pre-encryption partial downloads are regenerable; restart them once.
    if (await staging.exists() && !await _isEncrypted(staging)) {
      await staging.delete();
    }
    final existed = await staging.exists();
    final output = await staging.open(
      mode: existed ? FileMode.append : FileMode.write,
    );
    var closed = false;
    try {
      _Header? header;
      var offset = 0, index = 0;
      if (existed) {
        header = await _header(output, secret);
        if (header.metadata['root'] != entry.root ||
            header.metadata['path'] != entry.path ||
            header.metadata['modified'] !=
                entry.modifiedAt?.toUtc().toIso8601String() ||
            (entry.size != null && header.metadata['bytes'] != entry.size)) {
          throw const FormatException(
            'The PC file changed; cancel this download and keep a new copy.',
          );
        }
        final frames = await _frames(output, secret, header, repair: true);
        offset = frames.bytes;
        index = frames.chunks;
        await output.setPosition(await output.length());
        if (offset == header.metadata['bytes']) {
          progress(offset, offset);
          await output.close();
          closed = true;
          await staging.rename(destination.path);
          return;
        }
      }
      final response = await client.readStream(
        entry,
        range: offset > 0 ? 'bytes=$offset-' : null,
      );
      final total = entry.size ?? response.contentLength;
      if (total < 0) {
        await response.drain<void>();
        throw const FormatException('Unknown offline file size.');
      }
      if (offset > 0 && response.statusCode != 206) {
        await response.drain<void>();
        throw const FormatException(
          'The PC did not honor the offline resume range.',
        );
      }
      if (response.statusCode == 206) {
        final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
            .firstMatch(response.headers.value('content-range') ?? '');
        if (range == null ||
            int.parse(range[1]!) != offset ||
            int.parse(range[3]!) != total) {
          await response.drain<void>();
          throw const FormatException('Invalid offline download range.');
        }
      }
      if (response.statusCode == 416) {
        await response.drain<void>();
        throw const FormatException('Offline resume needs a fresh download.');
      }
      final writer = output;
      try {
        header ??= await _writeHeader(writer, {
          'version': 1,
          'name': safeName(entry.name),
          'bytes': total,
          'root': entry.root,
          'path': entry.path,
          'modified': entry.modifiedAt?.toUtc().toIso8601String(),
        }, secret);
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 45),
        )) {
          buffer.add(chunk);
          while (buffer.length >= chunkBytes) {
            final bytes = buffer.takeBytes();
            if (offset + chunkBytes > total) {
              throw const FormatException(
                'Offline response exceeded its file size.',
              );
            }
            await _append(
              writer,
              Uint8List.sublistView(bytes, 0, chunkBytes),
              secret,
              header,
              index++,
            );
            offset += chunkBytes;
            if (bytes.length > chunkBytes) {
              buffer.add(Uint8List.sublistView(bytes, chunkBytes));
            }
            progress(offset, total);
          }
        }
        if (buffer.isNotEmpty) {
          final bytes = buffer.takeBytes();
          if (offset + bytes.length != total) {
            throw const FormatException('Offline download ended early.');
          }
          await _append(writer, bytes, secret, header, index++);
          offset += bytes.length;
        }
        if (offset != total) {
          throw const FormatException('Incomplete offline download.');
        }
        progress(offset, total);
      } finally {
        /* The outer finally owns the single read/write handle. */
      }
    } finally {
      if (!closed) await output.close();
    }
    await staging.rename(destination.path);
  }

  Future<List<OfflineMedia>> files() async {
    if (!await directory.exists()) return const [];
    await migrateLegacy();
    final secret = await key();
    final result = <OfflineMedia>[];
    await for (final file in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (file is! File || file.path.endsWith('.part')) continue;
      if (!await _isEncrypted(file)) {
        continue; // Legacy files are migrated by the session.
      }
      final input = await file.open();
      try {
        final header = await _header(input, secret);
        result.add(
          OfflineMedia(
            file,
            safeName(header.metadata['name'] as String),
            header.metadata['bytes'] as int,
          ),
        );
      } finally {
        await input.close();
      }
    }
    return result;
  }

  Future<void> migrateLegacy() async {
    if (!await directory.exists()) return;
    final legacy = await directory
        .list(recursive: true, followLinks: false)
        .where(
          (v) =>
              v is File &&
              !v.path.endsWith('.part') &&
              !v.path.endsWith('.nexoffline'),
        )
        .cast<File>()
        .toList();
    for (final source in legacy) {
      if (await _isEncrypted(source)) continue;
      final secret = await key();
      final bytes = await source.length();
      final digest = await Sha256.fileHex(source);
      final target = File(
        p.join(
          directory.path,
          '${sha256Hex(utf8.encode(source.absolute.path)).substring(0, 32)}.nexoffline',
        ),
      );
      if (await target.exists()) {
        final reader = await target.open();
        try {
          final header = await _header(reader, secret);
          if (header.metadata['legacySha256'] != digest) {
            throw const FormatException('Conflicting offline migration.');
          }
          final frames = await _frames(reader, secret, header);
          if (frames.bytes != bytes) {
            throw const FormatException('Incomplete offline migration.');
          }
        } finally {
          await reader.close();
        }
      } else {
        final staging = File('${target.path}.part');
        final writer = await staging.open(mode: FileMode.write);
        final reader = await source.open();
        try {
          final header = await _writeHeader(writer, {
            'version': 1,
            'name': p.basename(source.path),
            'bytes': bytes,
            'legacySha256': digest,
          }, secret);
          var index = 0;
          while (true) {
            final chunk = await reader.read(chunkBytes);
            if (chunk.isEmpty) break;
            await _append(writer, chunk, secret, header, index++);
          }
        } finally {
          await reader.close();
          await writer.close();
        }
        if (await Sha256.fileHex(source) != digest) {
          throw const FormatException(
            'Offline source changed during migration.',
          );
        }
        await staging.rename(target.path);
      }
      await source.delete();
    }
  }

  Future<File> materialize(OfflineMedia media, Directory cache) async {
    final secret = await key();
    await cache.create(recursive: true);
    final target = File(p.join(cache.path, safeName(media.name)));
    final staging = File('${target.path}.part');
    final input = await media.file.open();
    final output = staging.openWrite();
    try {
      final header = await _header(input, secret);
      final frames = await _frames(input, secret, header, output: output);
      if (frames.bytes != header.metadata['bytes']) {
        throw const FormatException('Incomplete offline file.');
      }
      await output.close();
      if (await target.exists()) await target.delete();
      return await staging.rename(target.path);
    } catch (_) {
      await output.close();
      if (await staging.exists()) await staging.delete();
      rethrow;
    } finally {
      await input.close();
    }
  }

  static Future<int> _readLength(RandomAccessFile input) async {
    final bytes = await input.read(4);
    if (bytes.length != 4) {
      throw const FormatException('Truncated offline record.');
    }
    return ByteData.sublistView(bytes).getUint32(0, Endian.big);
  }

  static Future<void> _writeLength(RandomAccessFile output, int length) async {
    final bytes = ByteData(4)..setUint32(0, length, Endian.big);
    await output.writeFrom(bytes.buffer.asUint8List());
  }
}

final class _Header {
  const _Header(this.metadata, this.digest, this.end);
  final Map<String, dynamic> metadata;
  final String digest;
  final int end;
}
