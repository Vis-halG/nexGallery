import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:nex_gallery/data/android_media/android_media_bridge.dart';
import 'package:nex_gallery/data/device/device_bridge.dart';
import 'package:nex_gallery/services/intelligence/label_engine.dart';
import 'package:nex_gallery/services/intelligence/text_engine.dart';

/// Downloads the optional label and text packs (about 25 MB) and runs them
/// on-device. Needs network access on the test device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Uint8List textImage(List<String> lines) {
    final image = img.Image(width: 900, height: 90 + 80 * lines.length);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var i = 0; i < lines.length; i++) {
      img.drawString(
        image,
        lines[i],
        font: img.arial48,
        x: 40,
        y: 40 + 80 * i,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    return img.encodePng(image);
  }

  testWidgets('optional text and label packs run on device', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Model pack validation'))),
    );
    final root = Directory(
      '${await AndroidMediaBridge.instance.getAppDataPath()}/pack-test',
    );

    final text = TextEngine(Directory('${root.path}/text'));
    try {
      if (!await text.pack.installed()) await text.pack.install((_, _) {});
      final lines = await text.analyze(
        textImage(['NEXGALLERY 2026', 'Private photos']),
      );
      debugPrint('[packs] OCR lines: $lines');
      final joined = lines.join(' ').toUpperCase().replaceAll(' ', '');
      expect(joined, contains('NEXGALLERY'));
      expect(joined, contains('2026'));
      expect(joined, contains('PRIVATE'));
      final blank = img.Image(width: 400, height: 300);
      img.fill(blank, color: img.ColorRgb8(255, 255, 255));
      expect(await text.analyze(img.encodePng(blank)), isEmpty);
    } finally {
      await text.close();
    }

    final labels = LabelEngine(Directory('${root.path}/labels'));
    try {
      if (!await labels.pack.installed()) await labels.pack.install((_, _) {});
      final photo = img.Image(width: 320, height: 240);
      img.fill(photo, color: img.ColorRgb8(30, 120, 200));
      final found = await labels.analyze(img.encodePng(photo));
      debugPrint('[packs] labels for a flat blue image: $found');
      expect(found, isA<List<String>>());
      final images = await AndroidMediaBridge.instance.queryMedia(
        mediaType: AndroidMediaType.image,
      );
      for (final item in images.items.take(3)) {
        final thumbnail = await AndroidMediaBridge.instance.loadThumbnail(
          item.uri,
          size: 384,
        );
        debugPrint(
          '[packs] ${item.displayName}: ${await labels.analyze(thumbnail.bytes)}',
        );
      }
    } finally {
      await labels.close();
    }

    final conditions = await DeviceBridge.instance.conditions();
    final network = await DeviceBridge.instance.network();
    debugPrint(
      '[packs] charging=${conditions.charging} battery=${conditions.batteryPercent} '
      'pause=${conditions.pauseReason()} wifi=${network.wifi} metered=${network.metered}',
    );
    expect(network.connected, isTrue);
  });
}
