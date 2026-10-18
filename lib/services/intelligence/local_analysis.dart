import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';
import '../files/file_tools.dart';
import '../remote/sha256.dart';
import 'face_engine.dart';
import 'label_engine.dart';
import 'offline_places.dart';
import 'similarity.dart';
import 'text_engine.dart';

final class LocalFace {
  LocalFace({
    required this.id,
    required this.itemId,
    required this.personId,
    required this.vector,
    required this.bounds,
  });
  final String id, itemId;
  String personId;
  final List<double> vector, bounds;
  Map<String, Object?> toJson() => {
    'id': id,
    'itemId': itemId,
    'personId': personId,
    'vector': vector,
    'bounds': bounds,
  };
  factory LocalFace.fromJson(Map<String, dynamic> v) => LocalFace(
    id: v['id'] as String,
    itemId: v['itemId'] as String,
    personId: v['personId'] as String,
    vector: (v['vector'] as List).map((v) => (v as num).toDouble()).toList(),
    bounds: (v['bounds'] as List).map((v) => (v as num).toDouble()).toList(),
  );
}

/// Thrown when device conditions ask a scan to wait.
final class AnalysisPaused implements Exception {
  const AnalysisPaused(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

final class LocalAnalysis {
  LocalAnalysis(this.directory, this.tools, this.model, {this.pauseCheck});
  final Directory directory;
  final GalleryTools tools;
  final GalleryModel model;

  /// Returns a reason when heavy work should pause (heat, battery, memory).
  final Future<String?> Function()? pauseCheck;
  final faces = <LocalFace>[];
  final names = <String, String>{};
  final signatures = <String, String>{};
  final hashes = <String, String>{};

  /// Perceptual hashes by file signature, as 16-digit hex.
  final perceptual = <String, String>{};
  bool cancelled = false;
  late final engine = FaceEngine(Directory('${directory.path}/face-models'));
  late final labels = LabelEngine(Directory('${directory.path}/label-models'));
  late final text = TextEngine(Directory('${directory.path}/text-models'));
  File get _index => File('${directory.path}/analysis.json');
  List<MediaItem> get items => tools.localItems
      .where((v) => v.isAvailable && v.section != MediaSection.trash)
      .toList();
  List<MediaItem> get _photos =>
      items.where((v) => v.kind == MediaKind.image).toList();
  String _signature(MediaItem item) =>
      '${item.id}:${item.metadata.sizeBytes}:${item.metadata.modifiedAt.toUtc().microsecondsSinceEpoch}';

  final _pending = <String, MediaMetadata Function(MediaMetadata)>{};

  Future<void> load() async {
    final previous = File('${_index.path}.previous');
    if (!await _index.exists() && await previous.exists()) {
      await previous.rename(_index.path);
    }
    if (!await _index.exists()) return;
    if (await _index.length() > 64 << 20) {
      throw const FormatException('The analysis index is too large.');
    }
    final value =
        jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
    if (value['version'] != 1) {
      throw const FormatException('Unsupported analysis index.');
    }
    faces.clear();
    names.clear();
    signatures.clear();
    hashes.clear();
    perceptual.clear();
    faces.addAll(
      (value['faces'] as List).map(
        (v) => LocalFace.fromJson(Map<String, dynamic>.from(v as Map)),
      ),
    );
    names.addAll(Map<String, String>.from(value['names'] as Map));
    signatures.addAll(Map<String, String>.from(value['signatures'] as Map));
    hashes.addAll(Map<String, String>.from(value['hashes'] as Map));
    perceptual.addAll(
      Map<String, String>.from(value['perceptual'] as Map? ?? const {}),
    );
  }

  Future<void> save() async {
    await directory.create(recursive: true);
    final temp = File('${_index.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'version': 1,
        'faces': faces.map((v) => v.toJson()).toList(),
        'names': names,
        'signatures': signatures,
        'hashes': hashes,
        'perceptual': perceptual,
      }),
      flush: true,
    );
    final backup = File('${_index.path}.previous');
    if (await backup.exists()) await backup.delete();
    if (await _index.exists()) await _index.rename(backup.path);
    try {
      await temp.rename(_index.path);
    } catch (_) {
      if (await backup.exists()) await backup.rename(_index.path);
      rethrow;
    }
    if (await backup.exists()) await backup.delete();
  }

  Future<void> _checkPause(int count) async {
    if (count % 8 != 0 || pauseCheck == null) return;
    final reason = await pauseCheck!();
    if (reason != null) throw AnalysisPaused(reason);
  }

  void _queue(MediaItem item, MediaMetadata Function(MediaMetadata) update) {
    final previous = _pending[item.id];
    _pending[item.id] = previous == null
        ? update
        : (metadata) => update(previous(metadata));
  }

  Future<void> _flush() async {
    if (_pending.isEmpty) return;
    final batch = Map.of(_pending);
    _pending.clear();
    await tools.annotateAll(batch);
  }

  /// A renamed or moved photo keeps its faces, names and indexes: records
  /// stored under its earlier ids move to its current id.
  bool adoptMovedItems() {
    var changed = false;
    for (final item in items) {
      final earlier = item.metadata.attributes['analysis.movedFrom'];
      if (earlier == null) continue;
      for (final oldId in earlier.split(',')) {
        if (oldId.isEmpty || oldId == item.id) continue;
        for (var i = 0; i < faces.length; i++) {
          final face = faces[i];
          if (face.itemId != oldId) continue;
          faces[i] = LocalFace(
            id: face.id,
            itemId: item.id,
            personId: face.personId,
            vector: face.vector,
            bounds: face.bounds,
          );
          changed = true;
        }
        String rename(String value) => value.replaceAll(oldId, item.id);
        for (final map in [signatures, hashes, perceptual]) {
          final moved = [
            for (final key in map.keys)
              if (key.contains(oldId)) key,
          ];
          for (final key in moved) {
            final value = map.remove(key)!;
            map[rename(key)] = map == signatures ? rename(value) : value;
            changed = true;
          }
        }
      }
    }
    return changed;
  }

  /// Runs [analyze] over [photos], skipping unchanged files recorded under
  /// [key]. Results are saved in batches so large libraries stay fast.
  Future<void> _scan(
    String key,
    List<MediaItem> photos,
    void Function(int, int) progress,
    Future<void> Function(MediaItem photo) analyze, {
    String Function(MediaItem photo)? version,
  }) async {
    cancelled = false;
    adoptMovedItems();
    var count = 0;
    try {
      for (final photo in photos) {
        if (cancelled) break;
        await _checkPause(count);
        final signature = '$key:${photo.id}';
        final current = version?.call(photo) ?? _signature(photo);
        if (signatures[signature] != current) {
          try {
            await analyze(photo);
          } on FormatException {
            // Unsupported or damaged images are skipped, not fatal.
          }
          if (!model.canAccessMedia(photo)) continue;
          signatures[signature] = current;
          if (_pending.length >= 25) {
            await _flush();
            await save();
          }
        }
        progress(++count, photos.length);
      }
    } finally {
      await _flush();
      await save();
    }
  }

  Future<void> scanPeople(void Function(int, int) progress) async {
    cancelled = false;
    adoptMovedItems();
    final photos = _photos;
    final authorized = {for (final v in photos) v.id};
    var count = 0;
    try {
      await engine.open();
      for (final photo in photos) {
        if (cancelled) break;
        await _checkPause(count);
        if (signatures[photo.id] != _signature(photo)) {
          final bytes = await model.loadThumbnail(photo, size: 1024);
          if (bytes == null) {
            progress(++count, photos.length);
            continue;
          }
          final embeddings = await engine.analyze(bytes);
          if (cancelled || !model.canAccessMedia(photo)) break;
          faces.removeWhere((v) => v.itemId == photo.id);
          for (final embedding in embeddings) {
            LocalFace? nearest;
            var best = 0.55;
            for (final face in faces.where(
              (v) => authorized.contains(v.itemId) && v.itemId != photo.id,
            )) {
              final score = cosineSimilarity(face.vector, embedding.vector);
              if (score > best &&
                  !faces.any(
                    (v) => v.itemId == photo.id && v.personId == face.personId,
                  )) {
                best = score;
                nearest = face;
              }
            }
            faces.add(
              LocalFace(
                id: uniqueId(),
                itemId: photo.id,
                personId: nearest?.personId ?? uniqueId(),
                vector: embedding.vector,
                bounds: embedding.bounds,
              ),
            );
          }
          signatures[photo.id] = _signature(photo);
          if (count % 10 == 0) await save();
        }
        progress(++count, photos.length);
      }
    } finally {
      await save();
      await engine.close();
    }
  }

  Future<void> namePerson(String id, String name) async {
    names[id] = name.trim();
    await save();
    await _annotatePeople(
      items.where(
        (v) => faces.any((f) => f.itemId == v.id && f.personId == id),
      ),
    );
  }

  Future<void> _annotatePeople(Iterable<MediaItem> media) async {
    for (final item in media) {
      final people = faces
          .where((f) => f.itemId == item.id)
          .map((f) => names[f.personId] ?? '')
          .where((v) => v.isNotEmpty)
          .toSet()
          .join(', ');
      _queue(
        item,
        (metadata) => metadata.copyWith(
          attributes: {...metadata.attributes, 'analysis.people': people},
        ),
      );
    }
    await _flush();
  }

  Future<void> merge(String source, String target) async {
    for (final face in faces.where((v) => v.personId == source)) {
      face.personId = target;
    }
    names.remove(source);
    await save();
    await namePerson(target, names[target] ?? '');
  }

  Future<void> split(LocalFace face) async {
    face.personId = uniqueId();
    await save();
    await _annotatePeople(items.where((v) => v.id == face.itemId));
  }

  Future<void> reset() async {
    faces.clear();
    names.clear();
    signatures.removeWhere((key, _) => !key.contains(':'));
    await save();
    for (final item in items) {
      _queue(
        item,
        (metadata) => metadata.copyWith(
          attributes: {...metadata.attributes}..remove('analysis.people'),
        ),
      );
    }
    await _flush();
  }

  /// Removes object labels and recognized text from the catalogue.
  Future<void> resetSearchIndex() async {
    signatures.removeWhere(
      (key, _) => key.startsWith('labels:') || key.startsWith('text:'),
    );
    await save();
    for (final item in items) {
      _queue(
        item,
        (metadata) => metadata.copyWith(
          attributes: {...metadata.attributes}
            ..remove('analysis.labels')
            ..remove('analysis.text'),
        ),
      );
    }
    await _flush();
  }

  Future<List<List<MediaItem>>> duplicates(
    void Function(int, int) progress,
  ) async {
    cancelled = false;
    final bySize = <int, List<MediaItem>>{};
    for (final item in items) {
      (bySize[item.metadata.sizeBytes] ??= []).add(item);
    }
    final candidates = bySize.values
        .where((v) => v.length > 1)
        .expand((v) => v)
        .toList();
    final groups = <String, List<MediaItem>>{};
    var count = 0;
    for (final item in candidates) {
      if (cancelled) break;
      await _checkPause(count);
      final signature = _signature(item);
      var hash = hashes[signature];
      if (hash == null) {
        final file = await tools.materialize(item);
        try {
          hash = await Sha256.fileHex(file);
          hashes[signature] = hash;
        } finally {
          if (Platform.isAndroid && await file.exists()) await file.delete();
        }
      }
      if (!model.canAccessMedia(item)) continue;
      (groups['${item.metadata.sizeBytes}:$hash'] ??= []).add(item);
      progress(++count, candidates.length);
    }
    await save();
    return groups.values.where((v) => v.length > 1).toList();
  }

  /// Look-alike photos (bursts and edited copies) using perceptual hashes of
  /// small thumbnails.
  Future<List<List<MediaItem>>> similar(
    void Function(int, int) progress,
  ) async {
    cancelled = false;
    final photos = _photos;
    final hashed = <MediaItem, int>{};
    var count = 0;
    try {
      for (final photo in photos) {
        if (cancelled) break;
        await _checkPause(count);
        final signature = _signature(photo);
        var value = perceptual[signature];
        if (value == null) {
          final bytes = await model.loadThumbnail(photo, size: 256);
          if (bytes != null) {
            try {
              final hash = await _hashInBackground(bytes);
              value = hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
              perceptual[signature] = value;
            } on FormatException {
              // Undecodable thumbnails are skipped.
            }
          }
        }
        if (value != null && model.canAccessMedia(photo)) {
          hashed[photo] = int.parse(value, radix: 16).toSigned(64);
        }
        progress(++count, photos.length);
      }
    } finally {
      await save();
    }
    return _groupInBackground(hashed);
  }

  Future<void> scanLabels(void Function(int, int) progress) async {
    try {
      await labels.open();
      await _scan('labels', _photos, progress, (photo) async {
        final bytes = await model.loadThumbnail(photo, size: 384);
        if (bytes == null) return;
        final found = await labels.analyze(bytes);
        _queue(
          photo,
          (metadata) => metadata.copyWith(
            attributes: {
              ...metadata.attributes,
              'analysis.labels': found.join(', '),
            },
          ),
        );
      });
    } finally {
      await labels.close();
    }
  }

  Future<void> scanText(void Function(int, int) progress) async {
    try {
      await text.open();
      await _scan('text', _photos, progress, (photo) async {
        final bytes = await model.loadThumbnail(photo, size: 1280);
        if (bytes == null) return;
        final lines = await text.analyze(bytes);
        var joined = lines.join(' / ');
        if (joined.length > 2000) joined = joined.substring(0, 2000);
        _queue(
          photo,
          (metadata) => metadata.copyWith(
            attributes: {...metadata.attributes, 'analysis.text': joined},
          ),
        );
      });
    } finally {
      await text.close();
    }
  }

  /// Reads JPEG GPS, then names the nearest city from the bundled offline
  /// database. User corrections and "no location" choices are respected.
  Future<void> scanPlaces(void Function(int, int) progress) async {
    final places = await OfflinePlaces.load();
    await _scan(
      'gps',
      _photos,
      progress,
      (item) async {
        final attributes = item.metadata.attributes;
        if (attributes[userNoLocationKey] == 'true') {
          _queue(
            item,
            (metadata) => metadata.copyWith(
              attributes: {...metadata.attributes}..remove('analysis.place'),
            ),
          );
          return;
        }
        var latitude = item.metadata.latitude,
            longitude = item.metadata.longitude;
        if ((latitude == null || longitude == null) &&
            RegExp(r'\.jpe?g$', caseSensitive: false).hasMatch(item.name)) {
          final file = await tools.materialize(item);
          try {
            if (await file.length() <= 32 << 20) {
              final bytes = await file.readAsBytes();
              final gps = await _gpsInBackground(bytes);
              latitude = gps?.$1;
              longitude = gps?.$2;
            }
          } finally {
            if (Platform.isAndroid && await file.exists()) await file.delete();
          }
        }
        if (latitude == null || longitude == null) return;
        final place = places.nearest(latitude, longitude)?.label;
        final lat = latitude, lon = longitude;
        _queue(
          item,
          (metadata) => metadata.copyWith(
            latitude: lat,
            longitude: lon,
            attributes: {...metadata.attributes, 'analysis.place': ?place},
          ),
        );
      },
      version: (item) {
        // Corrections change coordinates without changing the file.
        final attributes = item.metadata.attributes;
        return '${_signature(item)}:${attributes[userLatitudeKey]}:'
            '${attributes[userLongitudeKey]}:${attributes[userNoLocationKey]}';
      },
    );
  }
}

(double, double)? readGps(Uint8List bytes) {
  final exif = img.decodeJpgExif(bytes);
  if (exif == null) return null;
  final gps = exif.gpsIfd;
  final lat = gps[2], lon = gps[4];
  if (lat == null || lon == null) return null;
  double degrees(img.IfdValue value) =>
      value.toDouble(0) + value.toDouble(1) / 60 + value.toDouble(2) / 3600;
  final latitude =
      degrees(lat) * (gps[1]?.toString().startsWith('S') == true ? -1 : 1);
  final longitude =
      degrees(lon) * (gps[3]?.toString().startsWith('W') == true ? -1 : 1);
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    return null;
  }
  return (latitude, longitude);
}

// Isolate entry points stay top-level so closures never capture the analysis
// object, its tools or the model (which cannot be sent between isolates).
Future<int> _hashInBackground(Uint8List bytes) =>
    Isolate.run(() => differenceHash(bytes));

Future<List<List<MediaItem>>> _groupInBackground(Map<MediaItem, int> hashes) =>
    Isolate.run(() => groupSimilar(hashes));

Future<(double, double)?> _gpsInBackground(Uint8List bytes) =>
    Isolate.run(() => readGps(bytes));
