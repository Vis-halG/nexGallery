import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/local_media_scanner.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';

void main() {
  late Directory workspace;
  late Directory root;
  late Directory state;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nexgallery_runtime_');
    root = await Directory('${workspace.path}/pictures').create();
    state = await Directory('${workspace.path}/state').create();
    await File('${state.path}/roots.txt').writeAsString(root.path);
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  test('pages the timeline and resets paging when filters change', () async {
    final items = List<MediaItem>.generate(251, (index) => _item(root, index));
    final runtime = NexGalleryRuntime(
      platform: TargetPlatform.windows,
      dataDirectory: state.path,
      scanner: _StubScanner(_result(items)),
    );
    try {
      await runtime.initialize();
      expect(runtime.loadState, GalleryLoadState.ready);
      expect(runtime.items, hasLength(120));
      expect(runtime.totalItemCount, 251);
      expect(runtime.hasMoreItems, isTrue);
      expect(runtime.items.first.id, '250');

      runtime.loadMoreItems();
      expect(runtime.items, hasLength(240));
      runtime.loadMoreItems();
      expect(runtime.items, hasLength(251));
      expect(runtime.items.map((item) => item.id).toSet(), hasLength(251));
      expect(runtime.hasMoreItems, isFalse);
      runtime.loadMoreItems();
      expect(runtime.items, hasLength(251));

      runtime.setSearchText('photo-250');
      expect(runtime.items.single.id, '250');
      expect(runtime.totalItemCount, 1);
      runtime.setSearchText('');
      expect(runtime.items, hasLength(120));
      runtime.showKinds(<MediaKind>{MediaKind.video});
      expect(runtime.totalItemCount, 0);
      expect(runtime.loadState, GalleryLoadState.empty);
      runtime.showKinds(<MediaKind>{});
      expect(runtime.items, hasLength(120));
      expect(runtime.loadState, GalleryLoadState.ready);
    } finally {
      runtime.dispose();
    }
  });

  test(
    'folder disconnect and reconnect preserve favorites and albums',
    () async {
      await File('${root.path}/photo.jpg').writeAsBytes(<int>[1, 2]);
      final runtime = NexGalleryRuntime(
        platform: TargetPlatform.windows,
        dataDirectory: state.path,
      );
      try {
        await runtime.initialize();
        final item = runtime.items.single;
        await runtime.toggleFavorite(item);
        await runtime.createAlbum('Family');
        final album = runtime.albums.single;
        await runtime.addToAlbum(item, album.id);

        final offlineRoot = await root.rename('${root.path}.offline');
        await runtime.refresh();
        expect(runtime.items.single.id, item.id);
        expect(runtime.items.single.isAvailable, isFalse);
        expect(runtime.items.single.isFavorite, isTrue);
        expect(runtime.albums.single.itemIds, contains(item.id));
        expect(
          runtime.statusMessage,
          contains('metadata and albums were kept'),
        );
        expect(await runtime.moveToTrash(runtime.items.single), isFalse);
        expect(await runtime.deletePermanently(runtime.items.single), isFalse);

        await offlineRoot.rename(root.path);
        await runtime.refresh();
        expect(runtime.items.single.isAvailable, isTrue);
        expect(runtime.items.single.isFavorite, isTrue);
        expect(runtime.albums.single.itemIds, contains(item.id));
      } finally {
        runtime.dispose();
      }
    },
  );

  for (final cancelled in <bool>[false, true]) {
    test(
      '${cancelled ? 'cancelled' : 'limited'} scan keeps unseen items',
      () async {
        final items = <MediaItem>[_item(root, 1), _item(root, 2)];
        final repository = await MediaCatalogRepository.open(
          databaseFilePath: '${state.path}/catalog.json',
        );
        await repository.upsertAll(items);
        await repository.setFavorite('2', true);
        final album = await repository.createAlbum('Preserved');
        await repository.addToAlbum(album.id, <String>['2']);
        await repository.dispose();

        final runtime = NexGalleryRuntime(
          platform: TargetPlatform.windows,
          dataDirectory: state.path,
          scanner: _StubScanner(
            _result(
              <MediaItem>[items.first],
              cancelled: cancelled,
              limited: !cancelled,
            ),
          ),
        );
        try {
          await runtime.initialize();
          expect(runtime.totalItemCount, 2);
          expect(
            runtime.items.singleWhere((item) => item.id == '2').isFavorite,
            isTrue,
          );
          expect(runtime.albums.single.itemIds, <String>['2']);
          expect(runtime.loadState, GalleryLoadState.ready);
          expect(runtime.isIndexing, isFalse);
        } finally {
          runtime.dispose();
        }
      },
    );
  }

  test(
    'Windows thumbnails keep aspect ratio and release the decode buffer',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder)
          .drawRect(const ui.Rect.fromLTWH(0, 0, 40, 20), ui.Paint());
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 20);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = await File('${root.path}/pixel.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
      final runtime = NexGalleryRuntime(platform: TargetPlatform.windows);
      try {
        final thumbnail = await runtime.loadThumbnail(
          _item(root, 1).copyWith(uri: file.uri.toString()),
          size: 10,
        );
        expect(thumbnail, isNotNull);
        expect(thumbnail, isNotEmpty);
        final codec = await ui.instantiateImageCodec(thumbnail!);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 10);
        expect(frame.image.height, 5);
        frame.image.dispose();
        codec.dispose();
      } finally {
        runtime.dispose();
      }
    },
  );
}

MediaItem _item(Directory root, int index) => MediaItem(
  id: '$index',
  name: 'photo-$index.jpg',
  uri: File('${root.path}/photo-$index.jpg').uri.toString(),
  relativePath: 'photo-$index.jpg',
  kind: MediaKind.image,
  source: MediaSource.pc,
  metadata: MediaMetadata(
    sizeBytes: 10,
    modifiedAt: DateTime.utc(2026, 10, 2),
    takenAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
    attributes: <String, String>{'rootPath': root.path},
  ),
  indexedAt: DateTime.utc(2026, 10, 2),
);

ScanResult _result(
  List<MediaItem> items, {
  bool cancelled = false,
  bool limited = false,
}) => ScanResult(
  items: items,
  issues: const <ScanIssue>[],
  filesVisited: items.length,
  directoriesVisited: 1,
  wasCancelled: cancelled,
  stoppedByLimit: limited,
);

class _StubScanner implements LocalMediaScanner {
  _StubScanner(this.result);
  final ScanResult result;
  @override
  bool get isSupported => true;
  @override
  Future<ScanResult> scan(
    Iterable<String> rootPaths, {
    ScanOptions? options,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async => result;
}
