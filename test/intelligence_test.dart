import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/services/intelligence/label_engine.dart';
import 'package:nex_gallery/services/intelligence/local_analysis.dart';
import 'package:nex_gallery/services/intelligence/offline_places.dart';
import 'package:nex_gallery/services/intelligence/similarity.dart';
import 'package:nex_gallery/services/intelligence/text_engine.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';
import 'package:path/path.dart' as p;

Uint8List _pattern(int seed, {int brighten = 0, int size = 64}) {
  final random = math.Random(seed);
  final image = img.Image(width: size, height: size);
  for (var by = 0; by < 8; by++) {
    for (var bx = 0; bx < 8; bx++) {
      final value = random.nextInt(200);
      img.fillRect(
        image,
        x1: bx * size ~/ 8,
        y1: by * size ~/ 8,
        x2: (bx + 1) * size ~/ 8 - 1,
        y2: (by + 1) * size ~/ 8 - 1,
        color: img.ColorRgb8(
          (value + brighten).clamp(0, 255),
          (value + brighten).clamp(0, 255),
          (value + brighten).clamp(0, 255),
        ),
      );
    }
  }
  return img.encodePng(image);
}

MediaItem _photo(
  String id,
  DateTime date, {
  int width = 100,
  bool favorite = false,
}) => MediaItem(
  id: id,
  name: '$id.jpg',
  uri: 'file:///$id.jpg',
  relativePath: 'Camera',
  kind: MediaKind.image,
  source: MediaSource.phone,
  isFavorite: favorite,
  metadata: MediaMetadata(
    sizeBytes: width,
    modifiedAt: date,
    takenAt: date,
    width: width,
    height: width,
  ),
  indexedAt: date,
);

void main() {
  group('similar photos', () {
    test('difference hash tolerates brightness but not new content', () {
      final original = differenceHash(_pattern(1));
      expect(hammingDistance(original, differenceHash(_pattern(1))), 0);
      expect(
        hammingDistance(original, differenceHash(_pattern(1, brighten: 40))),
        lessThanOrEqualTo(4),
      );
      expect(
        hammingDistance(original, differenceHash(_pattern(2))),
        greaterThan(16),
      );
    });

    test('groups bursts by time and copies across time', () {
      final start = DateTime.utc(2026, 5, 1, 10);
      final a = _photo('a', start);
      final b = _photo('b', start.add(const Duration(seconds: 2)), width: 400);
      final c = _photo('c', start.add(const Duration(days: 300)));
      final d = _photo('d', start.add(const Duration(days: 30)));
      final groups = groupSimilar({
        a: 0x0F0F0F0F0F0F0F0F,
        b: 0x0F0F0F0F0F0F0F0F ^ 0x7F, // 7 bits apart, same burst
        c: 0x0F0F0F0F0F0F0F0F ^ 0x3, // near-identical copy months later
        d: 0x0F0F0F0F0F0F0F0F ^ 0xFFFFF, // look-alike, but not a burst
      });
      expect(groups, hasLength(1));
      expect(groups.single.map((v) => v.id).toSet(), {'a', 'b', 'c'});
      expect(bestShot(groups.single).id, 'b');
      expect(
        bestShot([a, _photo('f', start, width: 50, favorite: true)]).id,
        'f',
      );
    });
  });

  group('offline places', () {
    test('prefers a large nearby city over a closer small town', () {
      final places = OfflinePlaces.parse(
        'C\tIN\tIndia\n'
        'Big City\tIN\t18.520\t73.856\t5000\n'
        'Suburb\tIN\t18.600\t73.900\t20\n'
        'Far Town\tIN\t20.000\t75.000\t100\n',
      );
      expect(places.nearest(18.59, 73.89)!.label, 'Big City, India');
      expect(places.nearest(19.9, 74.95)!.city, 'Far Town');
      expect(places.nearest(0, 0), isNull);
      expect(places.nearest(91, 0), isNull);
    });

    test('bundled GeoNames data names real cities', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final places = await OfflinePlaces.load();
      expect(places.nearest(18.5204, 73.8567)!.label, 'Pune, India');
      expect(places.nearest(48.8566, 2.3522)!.label, 'Paris, France');
      expect(places.nearest(35.6762, 139.6503)!.country, 'Japan');
      expect(places.nearest(-33.8688, 151.2093)!.label, 'Sydney, Australia');
      expect(places.nearest(-40, -140), isNull);
    });
  });

  group('objects and scenes', () {
    test('categories cover common gallery subjects', () {
      expect(imagenetCategory(207), 'dog');
      expect(imagenetCategory(281), 'cat');
      expect(imagenetCategory(963), 'food');
      expect(imagenetCategory(978), 'beach');
      expect(imagenetCategory(817), 'car');
      expect(imagenetCategory(985), 'flower');
      expect(imagenetCategory(500), isNull);
    });

    test('confident results add the category and the class name', () {
      final names = List<String>.generate(1000, (i) => 'class $i');
      final logits = List<double>.filled(1000, 0);
      logits[207] = 12; // dominant: golden retriever range (dog)
      expect(labelsFor(logits, names), ['dog', 'class 207']);

      final spread = List<double>.filled(1000, 0);
      for (final index in [151, 152, 153, 154, 155]) {
        spread[index] = 5.5;
      }
      expect(labelsFor(spread, names), ['dog']);
      expect(() => labelsFor([1, 2], names), throwsFormatException);
    });

    test('classifier input is normalized 3x224x224', () {
      final white = img.Image(width: 640, height: 480);
      img.fill(white, color: img.ColorRgb8(255, 255, 255));
      final input = classifierInput(img.encodePng(white));
      expect(input.length, 3 * 224 * 224);
      expect(input.first, closeTo((1 - 0.485) / 0.229, 1e-3));
      expect(input.last, closeTo((1 - 0.406) / 0.225, 1e-3));
    });
  });

  group('text recognition post-processing', () {
    test('finds separate text regions and expands them', () {
      const width = 64, height = 32;
      final map = Float32List(width * height);
      void block(int left, int top, int right, int bottom) {
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            map[y * width + x] = 0.9;
          }
        }
      }

      block(4, 4, 24, 10);
      block(30, 4, 50, 10);
      block(4, 20, 40, 26);
      block(60, 30, 61, 31); // noise, too small
      final boxes = detectTextBoxes(map, width, height);
      expect(boxes, hasLength(3));
      expect(boxes[0].left, lessThan(4));
      expect(boxes[0].right, greaterThan(24));
      expect(boxes[1].left, greaterThanOrEqualTo(26));
      expect(boxes[2].top, greaterThan(12));
      expect(
        () => detectTextBoxes(Float32List(3), width, height),
        throwsFormatException,
      );
    });

    test('CTC decoding collapses repeats and blanks', () {
      const classes = ocrCharacters.length + 1;
      int index(String character) => ocrCharacters.indexOf(character) + 1;
      final steps = ['H', 'H', '', 'i', '', '!', '!', ''];
      final values = <double>[];
      for (final step in steps) {
        final row = List<double>.filled(classes, 0.01);
        row[step.isEmpty ? 0 : index(step)] = 0.9;
        values.addAll(row);
      }
      final (text, confidence) = ctcDecode(values, steps.length, classes);
      expect(text, 'Hi!');
      expect(confidence, closeTo(0.9, 1e-6));
      expect(ocrCharacters.length, 96);
    });

    test('pages and crops have model-ready shapes', () {
      final photo = img.Image(width: 1000, height: 500);
      img.fill(photo, color: img.ColorRgb8(255, 255, 255));
      final page = prepareTextPage(img.encodePng(photo));
      expect(page.width, 960);
      expect(page.height, 480);
      expect(page.inputWidth % 32, 0);
      expect(page.inputHeight % 32, 0);
      expect(page.input.length, 3 * page.inputWidth * page.inputHeight);
      final (crop, cropWidth) = recognizerInput(
        page.rgb,
        page.width,
        page.height,
        const TextBox(10, 10, 410, 50, 0.9),
      );
      expect(cropWidth, 480);
      expect(crop.length, 3 * 48 * cropWidth);
      expect(crop.first, closeTo(1, 1e-6));
      final (short, shortWidth) = recognizerInput(
        page.rgb,
        page.width,
        page.height,
        const TextBox(10, 10, 110, 50, 0.9),
      );
      expect(shortWidth, 320);
      expect(short[47 * shortWidth + 100], closeTo(1, 1e-6));
      expect(short[47 * shortWidth + shortWidth - 1], 0); // right padding
      final lines = joinLines([
        (const TextBox(100, 0, 150, 20, 1), 'world'),
        (const TextBox(0, 2, 90, 22, 1), 'Hello'),
        (const TextBox(0, 40, 90, 60, 1), 'Next'),
      ]);
      expect(lines, ['Hello world', 'Next']);
    });
  });

  test(
    'places scan reads GPS, names the city and respects corrections',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final workspace = await Directory.systemTemp.createTemp('nex_places_');
      try {
        final root = await Directory(p.join(workspace.path, 'pics')).create();
        final photo = img.Image(width: 16, height: 16);
        photo.exif.gpsIfd[1] = img.IfdValueAscii('N');
        photo.exif.gpsIfd[2] = _dms(18, 1, 31, 1, 1320, 100);
        photo.exif.gpsIfd[3] = img.IfdValueAscii('E');
        photo.exif.gpsIfd[4] = _dms(73, 1, 51, 1, 2400, 100);
        await File(p.join(root.path, 'trip.jpg'))
            .writeAsBytes(img.encodeJpg(photo));
        await File(p.join(root.path, 'plain.jpg'))
            .writeAsBytes(img.encodeJpg(img.Image(width: 16, height: 16)));
        final state = await Directory(p.join(workspace.path, 'state')).create();
        final store = GalleryPreferencesStore(state.path);
        await store.save(GalleryPreferences(roots: [root.path]));
        await store.close();
        final runtime = NexGalleryRuntime(
          platform: TargetPlatform.windows,
          dataDirectory: state.path,
        );
        try {
          await runtime.initialize();
          final analysis = LocalAnalysis(
            Directory(p.join(state.path, 'analysis')),
            runtime,
            runtime,
          );
          await analysis.scanPlaces((_, _) {});
          MediaItem named(String name) =>
              runtime.localItems.firstWhere((item) => item.name == name);
          expect(
            named('trip.jpg').metadata.attributes['analysis.place'],
            'Pune, India',
          );
          expect(named('trip.jpg').metadata.latitude, closeTo(18.5203, 1e-3));
          expect(
            named('plain.jpg').metadata.attributes['analysis.place'],
            isNull,
          );

          await runtime.correctMetadata(
            named('trip.jpg'),
            location: (48.8566, 2.3522),
          );
          await analysis.scanPlaces((_, _) {});
          expect(
            named('trip.jpg').metadata.attributes['analysis.place'],
            'Paris, France',
          );

          await runtime.correctMetadata(named('trip.jpg'), clearLocation: true);
          await analysis.scanPlaces((_, _) {});
          expect(
            named('trip.jpg').metadata.attributes['analysis.place'],
            isNull,
          );
          expect(named('trip.jpg').metadata.latitude, isNull);

          final paused = LocalAnalysis(
            Directory(p.join(state.path, 'analysis-2')),
            runtime,
            runtime,
            pauseCheck: () async => 'The phone is too warm.',
          );
          await expectLater(
            paused.scanPlaces((_, _) {}),
            throwsA(isA<AnalysisPaused>()),
          );
        } finally {
          runtime.dispose();
        }
      } finally {
        await workspace.delete(recursive: true);
      }
    },
  );
}

/// Degrees, minutes and seconds as one EXIF rational triple.
img.IfdValueRational _dms(int d, int dd, int m, int md, int s, int sd) =>
    img.IfdValueRational(d, dd)
      ..value.addAll([
        img.IfdValueRational(m, md).value.single,
        img.IfdValueRational(s, sd).value.single,
      ]);
