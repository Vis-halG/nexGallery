import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/media_item.dart';

/// 64-bit difference hash of a 9x8 grayscale reduction. Visually similar
/// photos have hashes a small Hamming distance apart.
int differenceHash(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('This photo cannot be compared.');
  }
  final small = img.copyResize(
    img.grayscale(img.bakeOrientation(decoded)),
    width: 9,
    height: 8,
    interpolation: img.Interpolation.average,
  );
  var hash = 0;
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 8; x++) {
      hash <<= 1;
      if (small.getPixel(x, y).r < small.getPixel(x + 1, y).r) hash |= 1;
    }
  }
  return hash;
}

int hammingDistance(int a, int b) {
  var value = a ^ b, count = 0;
  while (value != 0) {
    value &= value - 1;
    count++;
  }
  return count;
}

DateTime _date(MediaItem item) =>
    item.metadata.takenAt ?? item.metadata.modifiedAt;

/// Groups look-alike photos: shots taken within [window] of each other whose
/// hashes differ by at most [nearDistance], plus near-identical copies from
/// any time (at most [copyDistance]). Groups are largest-first.
List<List<MediaItem>> groupSimilar(
  Map<MediaItem, int> hashes, {
  Duration window = const Duration(minutes: 30),
  int nearDistance = 10,
  int copyDistance = 3,
}) {
  final items = hashes.keys.toList()
    ..sort((a, b) => _date(a).compareTo(_date(b)));
  final parent = List<int>.generate(items.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  void join(int a, int b) {
    final ra = find(a), rb = find(b);
    if (ra != rb) parent[rb] = ra;
  }

  for (var i = 0; i < items.length; i++) {
    final start = _date(items[i]);
    for (var j = i + 1; j < items.length; j++) {
      if (_date(items[j]).difference(start) > window) break;
      if (hammingDistance(hashes[items[i]]!, hashes[items[j]]!) <=
          nearDistance) {
        join(i, j);
      }
    }
  }
  // Pigeonhole: hashes within 3 bits share at least one exact 16-bit block.
  for (var block = 0; block < 4; block++) {
    final buckets = <int, List<int>>{};
    for (var i = 0; i < items.length; i++) {
      final key = (hashes[items[i]]! >> (block * 16)) & 0xffff;
      (buckets[key] ??= []).add(i);
    }
    for (final bucket in buckets.values) {
      if (bucket.length < 2 || bucket.length > 500) continue;
      for (var x = 0; x < bucket.length; x++) {
        for (var y = x + 1; y < bucket.length; y++) {
          final a = bucket[x], b = bucket[y];
          if (hammingDistance(hashes[items[a]]!, hashes[items[b]]!) <=
              copyDistance) {
            join(a, b);
          }
        }
      }
    }
  }
  final groups = <int, List<MediaItem>>{};
  for (var i = 0; i < items.length; i++) {
    (groups[find(i)] ??= []).add(items[i]);
  }
  return groups.values.where((group) => group.length > 1).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
}

/// The photo to keep from a similar group: favorites, then resolution, then
/// file size.
MediaItem bestShot(List<MediaItem> group) {
  int pixels(MediaItem item) =>
      (item.metadata.width ?? 0) * (item.metadata.height ?? 0);
  return group.reduce((best, item) {
    if (item.isFavorite != best.isFavorite) {
      return item.isFavorite ? item : best;
    }
    if (pixels(item) != pixels(best)) {
      return pixels(item) > pixels(best) ? item : best;
    }
    return item.metadata.sizeBytes > best.metadata.sizeBytes ? item : best;
  });
}
