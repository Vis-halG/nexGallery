import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/local_media_scanner.dart';

void main() {
  test('scanner recursively categorizes selected directory files', () async {
    final root = await Directory.systemTemp.createTemp('nex_gallery_scan_');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}${Platform.pathSeparator}Photo.JPG')
        .writeAsBytes(<int>[1, 2, 3]);
    final nested = await Directory(
      '${root.path}${Platform.pathSeparator}nested',
    ).create();
    await File('${nested.path}${Platform.pathSeparator}song.mp3')
        .writeAsBytes(<int>[4, 5]);
    await File('${nested.path}${Platform.pathSeparator}file.unknown')
        .writeAsBytes(<int>[6]);
    await File('${root.path}${Platform.pathSeparator}.hidden.png')
        .writeAsBytes(<int>[7]);

    final progress = <ScanProgress>[];
    final result = await createLocalMediaScanner().scan(
      <String>[root.path],
      options: ScanOptions(progressEveryFiles: 1),
      onProgress: progress.add,
    );

    expect(result.wasCancelled, isFalse);
    expect(result.stoppedByLimit, isFalse);
    expect(result.issues, isEmpty);
    expect(result.items, hasLength(3));
    expect(result.items.map((item) => item.kind).toSet(), <MediaKind>{
      MediaKind.image,
      MediaKind.audio,
      MediaKind.other,
    });
    expect(result.items.every((item) => item.source == MediaSource.pc), isTrue);
    expect(progress.last.itemsFound, 3);
  });

  test('scanner respects cancellation before traversal', () async {
    final token = ScanCancellationToken()..cancel();
    final result = await createLocalMediaScanner().scan(<String>[
      Directory.systemTemp.path,
    ], cancellationToken: token);

    expect(result.wasCancelled, isTrue);
    expect(result.filesVisited, 0);
    expect(result.items, isEmpty);
  });

  test('depth-limited scans report an incomplete result', () async {
    final root = await Directory.systemTemp.createTemp('nex_gallery_depth_');
    addTearDown(() => root.delete(recursive: true));
    final nested = await Directory('${root.path}/nested').create();
    await File('${nested.path}/photo.jpg').writeAsBytes(<int>[1]);
    final result = await createLocalMediaScanner().scan(<String>[
      root.path,
    ], options: ScanOptions(maxDepth: 0));
    expect(result.stoppedByLimit, isTrue);
    expect(result.items, isEmpty);
  });

  test('transfer staging files stay out of the catalogue', () async {
    final root = await Directory.systemTemp.createTemp('nex_gallery_staging_');
    addTearDown(() => root.delete(recursive: true));
    for (final name in <String>[
      'complete.jpg',
      'video.mp4.part',
      '.nexgallery-transfer.json',
    ]) {
      await File('${root.path}/$name').writeAsBytes(<int>[1]);
    }
    final result = await createLocalMediaScanner().scan(<String>[
      root.path,
    ], options: ScanOptions(includeHidden: true));
    expect(result.items.map((item) => item.name), <String>['complete.jpg']);
  });
}
