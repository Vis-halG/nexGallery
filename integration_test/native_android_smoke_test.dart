import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/android_media/android_media_bridge.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/src/app.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';
import 'package:video_player/video_player.dart';

/// Run on a disposable emulator with nexgallery-smoke.png and
/// nexgallery-smoke.mp4 seeded through MediaStore, and grant visual permissions
/// using adb. This intentionally exercises the real native bridge, SQLite
/// assets and video codec rather than mocking platform channels.
///
/// Seeding without FFmpeg: push a 96x64 PNG to /sdcard/Pictures, record the
/// video on the emulator while the screen moves (a static screen gives one
/// frame and no video size), then rescan:
///
///     adb shell "screenrecord --time-limit 4 --size 640x1422
///       /sdcard/Movies/nexgallery-smoke.mp4 & for i in 1 2 3 4 5 6 7 8; do
///       input swipe 500 1800 500 700 150; done; wait"
///     adb shell content call --uri content://media --method scan_volume
///       --arg external_primary
///
/// The test uninstalls the app at the end, so install the debug APK and grant
/// READ_MEDIA_IMAGES and READ_MEDIA_VIDEO again before each run.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native Android gallery, SQLite and video smoke', (tester) async {
    expect(Platform.isAndroid, isTrue);
    final bridge = AndroidMediaBridge.instance;
    expect(bridge.isSupported, isTrue);
    final permission = await _waitForVisualAccess(bridge);
    expect(permission.sdkInt, greaterThanOrEqualTo(33));
    final appData = await bridge.getAppDataPath();
    expect(appData, startsWith('/data/'));

    final images = await bridge.queryMedia(mediaType: AndroidMediaType.image);
    final videos = await bridge.queryMedia(mediaType: AndroidMediaType.video);
    final image = images.items.singleWhere(
      (item) => item.displayName == 'nexgallery-smoke.png',
    );
    final video = videos.items.singleWhere(
      (item) => item.displayName == 'nexgallery-smoke.mp4',
    );
    expect(image.uri.scheme, 'content');
    expect(image.width, 96);
    expect(image.height, 64);
    expect(video.durationMilliseconds, greaterThan(0));
    final imageThumbnail = await bridge.loadThumbnail(image.uri, size: 128);
    final videoThumbnail = await bridge.loadThumbnail(video.uri, size: 128);
    expect(imageThumbnail.bytes, isNotEmpty);
    expect(videoThumbnail.bytes, isNotEmpty);
    debugPrint('[native-smoke] MediaStore image/video and thumbnails passed');

    final directory = Directory('$appData/native-smoke/runtime');
    await directory.create(recursive: true);
    final runtime = NexGalleryRuntime(dataDirectory: directory.path);
    VideoPlayerController? player;
    try {
      await runtime.initialize();
      expect(runtime.errorMessage, isNull);
      expect(runtime.loadState, GalleryLoadState.ready);
      final photoItem = runtime.items.singleWhere(
        (item) => item.name == 'nexgallery-smoke.png',
      );
      final videoItem = runtime.items.singleWhere(
        (item) => item.name == 'nexgallery-smoke.mp4',
      );
      expect(photoItem.source, MediaSource.phone);
      if (!photoItem.isFavorite) await runtime.toggleFavorite(photoItem);
      const albumName = 'Native smoke';
      if (!runtime.albums.any((album) => album.name == albumName)) {
        await runtime.createAlbum(albumName);
      }
      final album = runtime.albums.singleWhere(
        (album) => album.name == albumName,
      );
      await runtime.addToAlbum(photoItem, album.id);
      await runtime.saveVideoPosition(
        videoItem,
        const Duration(milliseconds: 200),
      );

      final catalogueFile = File('${directory.path}/catalog.sqlite');
      expect(await catalogueFile.exists(), isTrue);
      final header = await catalogueFile.open();
      try {
        expect(
          String.fromCharCodes(await header.read(16)),
          'SQLite format 3\u0000',
        );
      } finally {
        await header.close();
      }
      final reopened = await MediaCatalogRepository.open(
        databaseFilePath: catalogueFile.path,
      );
      try {
        expect(reopened.itemById(photoItem.id)?.isFavorite, isTrue);
        expect(reopened.albumById(album.id)?.itemIds, contains(photoItem.id));
        expect(reopened.itemById(videoItem.id)?.uri, video.uri.toString());
      } finally {
        await reopened.dispose();
      }
      debugPrint(
        '[native-smoke] Native SQLite reopen preserved favorites and album',
      );

      player = VideoPlayerController.contentUri(video.uri);
      await player.initialize().timeout(const Duration(seconds: 30));
      expect(player.value.isInitialized, isTrue);
      expect(player.value.hasError, isFalse);
      expect(player.value.duration, greaterThan(Duration.zero));
      expect(player.value.size.width, greaterThan(0));
      await player.seekTo(const Duration(milliseconds: 200));
      await player.setPlaybackSpeed(1.25);
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await player.pause();
      expect(player.value.hasError, isFalse);
      expect(await player.position, isNotNull);
      debugPrint('[native-smoke] Android video decode/play/seek/speed passed');
      await player.dispose();
      player = null;

      await tester.pumpWidget(NexGalleryApp(model: runtime));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('nexgallery-smoke.png'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      final screenshotFile = File('$appData/native-smoke/native-startup.png');
      await screenshotFile.writeAsBytes(
        await binding.takeScreenshot('native-startup'),
        flush: true,
      );
      binding.reportData = <String, Object>{
        'sdkInt': permission.sdkInt,
        'visualAccess': permission.visualAccess,
        'imageCount': images.items.length,
        'videoCount': videos.items.length,
        'sqliteFile': catalogueFile.path,
        'mediaStoreAndThumbnails': true,
        'sqliteOrganizationReopen': true,
        'videoDecodePlaySeekSpeed': true,
        'appStartup': true,
        'screenshotFile': screenshotFile.path,
      };
      debugPrint(
        '[native-smoke] App startup passed on API ${permission.sdkInt}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      await player?.dispose();
      runtime.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<AndroidMediaPermissionStatus> _waitForVisualAccess(
  AndroidMediaBridge bridge,
) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    final permission = await bridge.getPermissionStatus(
      mediaTypes: const <AndroidMediaType>{
        AndroidMediaType.image,
        AndroidMediaType.video,
      },
    );
    if (permission.visualAccess == 'full') return permission;
    if (stopwatch.elapsed > const Duration(seconds: 45)) {
      fail(
        'Grant READ_MEDIA_IMAGES and READ_MEDIA_VIDEO to the disposable test app with adb before running the native smoke.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
