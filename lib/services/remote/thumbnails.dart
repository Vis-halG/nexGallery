import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'sha256.dart';

/// Server-side JPEG previews, cached by path, file version and size. Only the
/// newest [maxEntries] previews are kept.
final class ThumbnailCache {
  ThumbnailCache(
    this.directory, {
    this.maxEntries = 4000,
    this.maxSourceBytes = 64 << 20,
  });

  final Directory directory;
  final int maxEntries;
  final int maxSourceBytes;
  int _writes = 0;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  static final _formats = RegExp(
    r'\.(jpe?g|png|gif|webp|bmp|tiff?)$',
    caseSensitive: false,
  );

  static bool supports(String path) => _formats.hasMatch(path);

  Future<File> thumbnail(File source, int size) async {
    final stat = await source.stat();
    if (stat.size > maxSourceBytes) {
      throw const FormatException('The photo is too large to preview.');
    }
    final key = sha256Hex(
      utf8.encode(
        '${source.absolute.path}|${stat.size}|'
        '${stat.modified.toUtc().microsecondsSinceEpoch}|$size',
      ),
    );
    final cached = File('${directory.path}${Platform.pathSeparator}$key.jpg');
    if (await cached.exists()) return cached;
    await _acquire();
    try {
      if (await cached.exists()) return cached;
      final bytes = await source.readAsBytes();
      final preview = await Isolate.run(() => renderThumbnail(bytes, size));
      await directory.create(recursive: true);
      final part = File('${cached.path}.part');
      await part.writeAsBytes(preview, flush: true);
      await part.rename(cached.path);
      if (++_writes % 50 == 0) unawaited(_prune());
      return cached;
    } finally {
      _release();
    }
  }

  // At most two decodes run at once to bound memory use.
  Future<void> _acquire() async {
    if (_running < 2) {
      _running++;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    await turn.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  Future<void> _prune() async {
    try {
      final files = await directory
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.jpg'))
          .cast<File>()
          .toList();
      if (files.length <= maxEntries) return;
      final dated = <(File, DateTime)>[
        for (final file in files) (file, (await file.stat()).modified),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _) in dated.take(files.length - maxEntries)) {
        await file.delete();
      }
    } on FileSystemException {
      // Pruning is best-effort; a later write tries again.
    }
  }
}

/// Decodes, orients and shrinks a photo so its longer side is [size].
Uint8List renderThumbnail(Uint8List bytes, int size) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null || info.width * info.height > 80000000) {
    throw const FormatException('This photo cannot be previewed.');
  }
  final decoded = decoder!.decodeFrame(0);
  if (decoded == null) throw const FormatException('Unreadable photo.');
  final image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  final scaled = longest <= size
      ? image
      : img.copyResize(
          image,
          width: image.width >= image.height ? size : null,
          height: image.height > image.width ? size : null,
          interpolation: img.Interpolation.average,
        );
  return img.encodeJpg(scaled, quality: 80);
}
