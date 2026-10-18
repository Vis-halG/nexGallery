import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

String safeName(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ') ||
      RegExp(
        r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    throw const FormatException('Choose a valid file or folder name.');
  }
  return name;
}

String uniqueId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((v) => v.toRadixString(16).padLeft(2, '0')).join();

/// Physical operations never overwrite existing data or follow symbolic links.
final class FileTools {
  Future<void> copy(
    String source,
    String destination, {
    bool move = false,
  }) async {
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Only regular files and folders can be copied.',
      );
    }
    final from =
        await (type == FileSystemEntityType.file
                ? File(source).parent
                : Directory(source))
            .resolveSymbolicLinks();
    final parent = await Directory(p.dirname(destination))
        .resolveSymbolicLinks();
    final target = p.join(parent, safeName(p.basename(destination)));
    if (p.equals(p.normalize(source), p.normalize(target)) ||
        (type == FileSystemEntityType.directory &&
            (p.equals(from, parent) || p.isWithin(from, parent)))) {
      throw const FileSystemException(
        'Choose a destination outside the source folder.',
      );
    }
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('An item with this name already exists.');
    }
    if (move) {
      try {
        if (type == FileSystemEntityType.file) {
          await File(source).rename(target);
        } else {
          await Directory(source).rename(target);
        }
        return;
      } on FileSystemException {
        // Cross-volume moves use a completed copy before deleting the source.
      }
    }
    final stage = p.join(parent, '.nexgallery-${uniqueId()}.part');
    try {
      if (type == FileSystemEntityType.file) {
        await File(source).copy(stage);
        await File(stage).rename(target);
      } else {
        await Directory(stage).create();
        var count = 0;
        await for (final entry in Directory(
          source,
        ).list(recursive: true, followLinks: false)) {
          if (++count > 100000) {
            throw const FileSystemException('Folder has too many entries.');
          }
          if (entry is Link) {
            throw const FileSystemException('Symbolic links are not copied.');
          }
          final relative = p.relative(entry.path, from: source);
          final output = p.join(stage, relative);
          if (entry is Directory) {
            await Directory(output).create(recursive: true);
          } else if (entry is File) {
            await File(output).parent.create(recursive: true);
            await entry.copy(output);
          }
        }
        await Directory(stage).rename(target);
      }
      if (move) {
        if (type == FileSystemEntityType.file) {
          await File(source).delete();
        } else {
          await Directory(source).delete(recursive: true);
        }
      }
    } catch (_) {
      final stagedType = await FileSystemEntity.type(stage, followLinks: false);
      if (stagedType == FileSystemEntityType.directory) {
        await Directory(stage).delete(recursive: true);
      }
      if (stagedType == FileSystemEntityType.file) {
        await File(stage).delete();
      }
      rethrow;
    }
  }

  Future<void> createZip(String source, String destination) async {
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('The ZIP destination already exists.');
    }
    if (await FileSystemEntity.type(source, followLinks: false) ==
            FileSystemEntityType.link ||
        p.equals(source, destination) ||
        p.isWithin(source, destination)) {
      throw const FileSystemException(
        'Choose a ZIP destination outside the source.',
      );
    }
    final stage = '$destination.nexgallery-${uniqueId()}.part';
    final encoder = ZipFileEncoder();
    try {
      encoder.create(stage);
      if (await Directory(source).exists()) {
        encoder.addArchiveFile(
          ArchiveFile.directory('${safeName(p.basename(source))}/'),
        );
        var count = 0;
        await for (final entry in Directory(
          source,
        ).list(recursive: true, followLinks: false)) {
          if (++count > 100000) {
            throw const FileSystemException('Too many ZIP entries.');
          }
          if (entry is Link) {
            throw const FileSystemException(
              'Symbolic links cannot be archived.',
            );
          }
          if (entry is File) {
            await encoder.addFile(
              entry,
              p.relative(entry.path, from: p.dirname(source)),
            );
          } else if (entry is Directory) {
            encoder.addArchiveFile(
              ArchiveFile.directory(
                '${p.posix.fromUri(p.toUri(p.relative(entry.path, from: p.dirname(source))))}/',
              ),
            );
          }
        }
      } else {
        await encoder.addFile(File(source), safeName(p.basename(source)));
      }
      await encoder.close();
      await File(stage).rename(destination);
    } catch (_) {
      try {
        await encoder.close();
      } on Object {
        /* already closed */
      }
      if (await File(stage).exists()) await File(stage).delete();
      rethrow;
    }
  }

  /// Extract into a new staging folder, rejecting links, traversal and ZIP bombs.
  Future<void> extractZip(
    String source,
    String destination, {
    int maximumBytes = 20 << 30,
  }) async {
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('Extraction needs a new folder.');
    }
    final parent = await Directory(p.dirname(destination))
        .resolveSymbolicLinks();
    final target = p.join(parent, safeName(p.basename(destination)));
    final stage = p.join(parent, '.nexgallery-${uniqueId()}.part');
    final input = InputFileStream(source);
    try {
      final directory = ZipDirectory()..read(input);
      if (directory.fileHeaders.length > 100000) {
        throw const FormatException('Too many ZIP entries.');
      }
      final rawNames = <String>{};
      for (final header in directory.fileHeaders) {
        if (((header.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
            !rawNames.add(
              header.filename.replaceAll('\\', '/').toLowerCase(),
            )) {
          throw const FormatException(
            'ZIP contains links or repeated entries.',
          );
        }
      }
      input.reset();
      final archive = ZipDecoder().decodeStream(input, verify: true);
      if (archive.length > 100000) {
        throw const FormatException('Too many ZIP entries.');
      }
      var total = 0;
      final names = <String>{};
      for (final entry in archive) {
        final name = entry.name.replaceAll('\\', '/');
        if (entry.isSymbolicLink ||
            name.startsWith('/') ||
            name.contains(':') ||
            name.split('/').any((part) => part == '..') ||
            !names.add(p.normalize(name).toLowerCase())) {
          throw const FormatException('ZIP contains unsafe or repeated paths.');
        }
        for (final part in name.split('/').where((v) => v.isNotEmpty)) {
          safeName(part);
        }
        total += entry.size;
        if (entry.size < 0 || total > maximumBytes) {
          throw const FormatException('ZIP exceeds the extraction limit.');
        }
        final out = p.normalize(p.join(stage, name));
        if (!p.isWithin(stage, out)) {
          throw const FormatException('ZIP entry escapes destination.');
        }
      }
      await Directory(stage).create();
      for (final entry in archive) {
        final out = p.join(stage, entry.name.replaceAll('\\', '/'));
        if (!entry.isFile) {
          await Directory(out).create(recursive: true);
          continue;
        }
        await File(out).parent.create(recursive: true);
        final output = _BoundedZipOutput(out, entry.size);
        try {
          entry.writeContent(output);
          if (output.length != entry.size || output.crc != entry.crc32) {
            throw const FormatException('ZIP content is damaged.');
          }
        } finally {
          await output.close();
        }
      }
      await Directory(stage).rename(target);
    } catch (_) {
      if (await Directory(stage).exists()) {
        await Directory(stage).delete(recursive: true);
      }
      rethrow;
    } finally {
      await input.close();
    }
  }
}

class _BoundedZipOutput extends OutputFileStream {
  _BoundedZipOutput(String path, this.limit)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));
  final int limit;
  int crc = 0;
  @override
  void writeByte(int value) {
    if (length >= limit) {
      throw const FormatException('ZIP expanded beyond its declared size.');
    }
    crc = getCrc32([value], crc);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (this.length + count > limit) {
      throw const FormatException('ZIP expanded beyond its declared size.');
    }
    crc = getCrc32(
      count == bytes.length ? bytes : bytes.sublist(0, count),
      crc,
    );
    super.writeBytes(bytes, length: count);
  }
}
