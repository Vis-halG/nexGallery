import 'dart:io';
import 'dart:typed_data';

/// Writes the standard ISO BMFF video-track display matrix. Pixels are preserved;
/// MP4 players apply the rotation at playback, as they do for camera orientation.
Future<void> rotateMp4(File file, int degrees) async {
  if (![0, 90, 180, 270].contains(degrees)) {
    throw const FormatException('Invalid MP4 rotation.');
  }
  if (degrees == 0) return;
  final handle = await file.open(mode: FileMode.append);
  try {
    Future<Uint8List> read(int offset, int bytes) async {
      await handle.setPosition(offset);
      final value = await handle.read(bytes);
      if (value.length != bytes) throw const FormatException('Truncated MP4.');
      return value;
    }

    Future<List<(String, int, int, int)>> atoms(int start, int end) async {
      final values = <(String, int, int, int)>[];
      var offset = start;
      while (offset < end) {
        if (end - offset < 8 || values.length > 10000) {
          throw const FormatException('Invalid MP4 atoms.');
        }
        final header = await read(offset, 8);
        var size = ByteData.sublistView(header).getUint32(0);
        var headerSize = 8;
        if (size == 1) {
          size = ByteData.sublistView(await read(offset + 8, 8)).getUint64(0);
          headerSize = 16;
        }
        if (size == 0) size = end - offset;
        if (size < headerSize || offset + size > end) {
          throw const FormatException('Invalid MP4 atom size.');
        }
        values.add((
          String.fromCharCodes(header.sublist(4)),
          offset + headerSize,
          offset + size,
          headerSize,
        ));
        offset += size;
      }
      return values;
    }

    final top = await atoms(0, await handle.length());
    final movies = top.where((v) => v.$1 == 'moov').toList();
    if (movies.length != 1) {
      throw const FormatException('MP4 movie metadata is missing.');
    }
    var updated = 0;
    for (final track in (await atoms(
      movies.single.$2,
      movies.single.$3,
    )).where((v) => v.$1 == 'trak')) {
      final children = await atoms(track.$2, track.$3);
      final media = children.where((v) => v.$1 == 'mdia').toList();
      if (media.length != 1) continue;
      final handlers = (await atoms(
        media.single.$2,
        media.single.$3,
      )).where((v) => v.$1 == 'hdlr').toList();
      if (handlers.length != 1 ||
          handlers.single.$3 - handlers.single.$2 < 12 ||
          String.fromCharCodes(await read(handlers.single.$2 + 8, 4)) !=
              'vide') {
        continue;
      }
      final headers = children.where((v) => v.$1 == 'tkhd').toList();
      if (headers.length != 1) {
        throw const FormatException('MP4 video track header is missing.');
      }
      final header = headers.single;
      final version = (await read(header.$2, 1)).first;
      if (version != 0 && version != 1) {
        throw const FormatException('Unsupported MP4 track header.');
      }
      final matrix = header.$2 + (version == 0 ? 40 : 52);
      if (matrix + 44 > header.$3) {
        throw const FormatException('Truncated MP4 track header.');
      }
      final dimensions = ByteData.sublistView(await read(matrix + 36, 8));
      final width = dimensions.getUint32(0), height = dimensions.getUint32(4);
      final values = switch (degrees) {
        90 => [0, 65536, 0, -65536, 0, 0, height, 0, 1 << 30],
        180 => [-65536, 0, 0, 0, -65536, 0, width, height, 1 << 30],
        _ => [0, -65536, 0, 65536, 0, 0, 0, width, 1 << 30],
      };
      final data = ByteData(36);
      for (var i = 0; i < 9; i++) {
        data.setInt32(i * 4, values[i]);
      }
      await handle.setPosition(matrix);
      await handle.writeFrom(data.buffer.asUint8List());
      updated++;
    }
    if (updated == 0) throw const FormatException('MP4 has no video track.');
    await handle.flush();
  } finally {
    await handle.close();
  }
}
