import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nex_gallery/services/editing/image_editor.dart';
import 'package:nex_gallery/services/vault/vault_store.dart';
import 'package:path/path.dart' as p;

void main() {
  Uint8List solid(int width, int height, img.Color color) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: color);
    return img.encodePng(image);
  }

  group('photo editor', () {
    test('mono and sepia filters change colors predictably', () {
      final red = solid(40, 30, img.ColorRgb8(220, 20, 20));
      final mono = img.decodePng(
        editImage(red, const ImageEdit(filter: ImageFilter.mono)),
      )!;
      final pixel = mono.getPixel(10, 10);
      expect(pixel.r, pixel.g);
      expect(pixel.g, pixel.b);
      final sepia = img.decodePng(
        editImage(red, const ImageEdit(filter: ImageFilter.sepia)),
      )!;
      expect(sepia.getPixel(10, 10).r, greaterThan(sepia.getPixel(10, 10).b));
    });

    test('straighten crops away rotated corners', () {
      final white = solid(400, 300, img.ColorRgb8(255, 255, 255));
      final result = img.decodePng(
        editImage(white, const ImageEdit(straighten: 10)),
      )!;
      expect(result.width, lessThan(400));
      expect(result.height, lessThan(300));
      expect((result.width / result.height), closeTo(400 / 300, 0.02));
      for (final (x, y) in [
        (0, 0),
        (result.width - 1, 0),
        (0, result.height - 1),
        (result.width - 1, result.height - 1),
      ]) {
        expect(result.getPixel(x, y).r, greaterThan(200));
      }
      expect(
        () => editImage(white, const ImageEdit(straighten: 20)),
        throwsFormatException,
      );
    });

    test('markup strokes are drawn in normalized coordinates', () {
      final white = solid(200, 100, img.ColorRgb8(255, 255, 255));
      final result = img.decodePng(
        editImage(
          white,
          const ImageEdit(
            strokes: [
              MarkupStroke(
                [(0.1, 0.5), (0.9, 0.5)],
                color: 0xFF0000FF,
                width: 0.05,
              ),
            ],
          ),
        ),
      )!;
      final center = result.getPixel(100, 50);
      expect(center.b, greaterThan(200));
      expect(center.r, lessThan(60));
      final corner = result.getPixel(2, 2);
      expect(corner.r, 255);
    });

    test('collage arranges photos in a grid and validates count', () {
      final photos = [
        for (final color in [
          img.ColorRgb8(255, 0, 0),
          img.ColorRgb8(0, 255, 0),
          img.ColorRgb8(0, 0, 255),
        ])
          solid(120, 80, color),
      ];
      final collage = img.decodePng(buildCollage(photos, width: 600, gap: 10))!;
      expect(collage.width, 600);
      // Two columns, two rows: 285 px cells plus three gaps.
      expect(collage.height, 2 * 285 + 3 * 10);
      expect(collage.getPixel(150, 150).r, greaterThan(200));
      expect(collage.getPixel(450, 150).g, greaterThan(200));
      expect(collage.getPixel(300, 440).b, greaterThan(200));
      expect(() => buildCollage([photos.first]), throwsFormatException);
    });
  });

  group('vault backup', () {
    late Directory workspace;
    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('nex_vault_backup_');
    });
    tearDown(() async {
      await workspace.delete(recursive: true);
    });

    test('exports encrypted files and re-encrypts them on import', () async {
      final secret = File(p.join(workspace.path, 'diary.txt'));
      await secret.writeAsString('very private words ' * 1000);
      final source = VaultStore(
        Directory(p.join(workspace.path, 'phone-a')),
        iterations: 100000,
      );
      await source.unlock('first password!', create: true);
      await source.add(secret, 'diary.txt');
      final backup = File(p.join(workspace.path, 'backup.nexvault'));
      await source.exportBackup(backup);
      await expectLater(
        source.exportBackup(backup),
        throwsA(isA<FileSystemException>()),
      );

      final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
      expect(archive.files.map((f) => f.name), contains('vault.json'));
      for (final file in archive.files) {
        expect(
          String.fromCharCodes(file.content as List<int>),
          isNot(contains('private words')),
        );
        expect(
          String.fromCharCodes(file.content as List<int>),
          isNot(contains('diary')),
        );
      }

      final target = VaultStore(
        Directory(p.join(workspace.path, 'phone-b')),
        iterations: 100000,
      );
      await target.unlock('second password', create: true);
      final staging = await Directory(p.join(workspace.path, 'staging'))
          .create();
      await expectLater(
        target.importBackup(backup, 'not the password', workspace: staging),
        throwsA(anything),
      );
      expect(target.entries, isEmpty);
      final imported = await target.importBackup(
        backup,
        'first password!',
        workspace: staging,
      );
      expect(imported, 1);
      expect(target.entries.single.name, 'diary.txt');
      final restored = await target.decrypt(
        target.entries.single,
        File(p.join(workspace.path, 'restored.txt')),
      );
      expect(await restored.readAsString(), await secret.readAsString());
      expect(staging.listSync(), isEmpty);

      target.lock();
      await target.unlock('second password');
      expect(target.entries.single.name, 'diary.txt');
    });
  });
}
