import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nex_gallery/data/android_media/android_media_bridge.dart';
import 'package:nex_gallery/services/editing/video_editor.dart';
import 'package:nex_gallery/services/intelligence/face_engine.dart';
import 'package:video_player/video_player.dart';

/// Disposable emulator fixtures: astronaut.png from scikit-image's public-domain
/// NASA sample and butterfly.mp4 from Flutter's video_player example.
/// Grant image/video permissions with adb; select a disposable SAF test folder
/// in the system picker when RUN_SAF_TEST=true.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native face inference and video trim/rotation/mute export', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Native feature validation')),
      ),
    );
    final bridge = AndroidMediaBridge.instance;
    final permission = await bridge.getPermissionStatus();
    if (permission.visualAccess != 'full') await bridge.requestPermissions();
    final directory = Directory(
      '${await bridge.getAppDataPath()}/pending-native-test',
    );
    await directory.create(recursive: true);
    final images = await bridge.queryMedia(mediaType: AndroidMediaType.image);
    final astronaut = images.items.singleWhere(
      (v) => v.displayName == 'nexgallery-astronaut.png',
    );
    final cached = await bridge.copyDocumentToAppCache(astronaut.uri);
    final engine = FaceEngine(Directory('${directory.path}/models'));
    try {
      if (!await engine.installed()) await engine.install((_, _) {});
      final faces = await engine.analyze(await File(cached.path).readAsBytes());
      expect(faces, isNotEmpty);
      expect(faces.first.vector.length, 128);
      expect(
        faces.first.bounds.every((v) => v.isFinite && v >= 0 && v <= 1),
        isTrue,
      );
      final repeat = await engine.analyze(
        await File(cached.path).readAsBytes(),
      );
      expect(
        cosineSimilarity(faces.first.vector, repeat.first.vector),
        greaterThan(0.99),
      );
      debugPrint(
        '[pending-native] YuNet and SFace returned ${faces.length} face(s), stable 128-D embedding',
      );
    } finally {
      await engine.close();
      await File(cached.path).delete();
    }
    final videos = await bridge.queryMedia(mediaType: AndroidMediaType.video);
    final video = videos.items.firstWhere(
      (v) => v.displayName == 'butterfly.mp4',
    );
    final input = File((await bridge.copyDocumentToAppCache(video.uri)).path);
    final output = File('${directory.path}/edited.mp4');
    if (await output.exists()) await output.delete();
    VideoPlayerController? player;
    try {
      await VideoEditor().export(
        input: input,
        output: output,
        startMs: 1000,
        endMs: 3000,
        rotation: 90,
        mute: true,
        compress: true,
      );
      player = VideoPlayerController.file(output);
      await player.initialize();
      expect(
        player.value.duration.inMilliseconds,
        inInclusiveRange(1700, 2300),
      );
      expect(player.value.size.height, greaterThan(player.value.size.width));
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await player.pause();
      expect(player.value.hasError, isFalse);
      final channel = const MethodChannel('com.thenex.nex_gallery/media');
      await expectLater(
        channel.invokeMethod<Object?>('editVideo', {
          'input': '/sdcard/Movies/butterfly.mp4',
          'output': '${directory.path}/unsafe.mp4',
          'startMs': 0,
          'endMs': 1000,
          'rotation': 0,
          'mute': false,
          'compress': false,
        }),
        throwsA(isA<PlatformException>()),
      );
      debugPrint(
        '[pending-native] Android video trim, rotate, mute, 720p and decode passed',
      );
    } finally {
      await player?.dispose();
      await input.delete();
    }
    if (const bool.fromEnvironment('RUN_SAF_TEST')) {
      final selected = await bridge.pickDirectory();
      expect(selected.uri, isNotNull);
      final root = selected.uri!;
      final folder = await bridge.createDirectory(root, 'source');
      final source = File('${directory.path}/hello.txt');
      await source.writeAsString('SAF archive fixture');
      await bridge.exportAppFile(source.path, folder.uri!, name: 'hello.txt');
      await bridge.archiveDocument(folder.uri!, root, 'source.zip');
      final entries = (await bridge.listDirectory(root)).items;
      final zip = entries.singleWhere((v) => v.name == 'source.zip');
      await bridge.archiveDocument(zip.uri, root, 'unpacked', extract: true);
      final extracted = (await bridge.listDirectory(root)).items
          .singleWhere((v) => v.name == 'unpacked');
      final extractedFolder = (await bridge.listDirectory(extracted.uri)).items
          .singleWhere((v) => v.name == 'source');
      final extractedFile = (await bridge.listDirectory(extractedFolder.uri))
          .items
          .singleWhere((v) => v.name == 'hello.txt');
      final read = File(
        (await bridge.copyDocumentToAppCache(extractedFile.uri)).path,
      );
      expect(await read.readAsString(), 'SAF archive fixture');
      await read.delete();
      final copyTarget = await bridge.createDirectory(root, 'copy-target');
      await bridge.copyDocument(folder.uri!, copyTarget.uri!);
      debugPrint(
        '[pending-native] SAF ZIP round trip and recursive copy passed',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
