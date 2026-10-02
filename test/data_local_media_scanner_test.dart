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
}
