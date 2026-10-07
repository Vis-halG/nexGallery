import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/features/photos/local_video_player.dart';
import 'package:nex_gallery/features/photos/media_viewer.dart';
import 'package:nex_gallery/features/photos/video_playback_controller.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:video_player/video_player.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('local player rejects remote URLs and unsupported platform sources', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    for (final uri in [
      'https://example.test/video.mp4',
      'http://example.test/video.mp4',
      'content://media/external/video/1',
      'file://other-machine/share/video.mp4',
    ]) {
      expect(
        () => createLocalVideoController(_video(uri: uri)),
        throwsUnsupportedError,
      );
    }
    expect(
      () => createLocalVideoController(_video(available: false)),
      throwsStateError,
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(() => createLocalVideoController(_video()), throwsUnsupportedError);
  });

  test(
    'Android content URIs and local Windows files create platform players',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final android = createLocalVideoController(
        _video(uri: 'content://media/external/video/media/1'),
      );
      expect(android.value.isInitialized, isFalse);
      await android.dispose();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final windows = createLocalVideoController(_video());
      expect(windows.value.isInitialized, isFalse);
      await windows.dispose();
    },
  );

  test(
    'bounded local sidecars parse SRT and VTT and ignore unsafe size',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'nex-video-caption-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final video = File.fromUri(
        directory.uri.resolve('holiday%20%23%20clip.mp4'),
      );
      final srt = File.fromUri(
        directory.uri.resolve('holiday%20%23%20clip.srt'),
      );
      await srt.writeAsString(
        '1\n00:00:01,000 --> 00:00:03,000\nA local subtitle\n',
      );
      final captions = await loadVideoSidecarCaptions(video);
      expect(captions!.captions.single.text, 'A local subtitle');
      expect(captions.captions.single.start, const Duration(seconds: 1));
      expect(await loadVideoSidecarCaptions(video, maximumBytes: 8), isNull);
      await srt.writeAsString('Not a subtitle');
      final vtt = File.fromUri(
        directory.uri.resolve('holiday%20%23%20clip.vtt'),
      );
      await vtt.writeAsString('WEBVTT\n\n00:01.000 --> 00:03.000\nLocal VTT\n');
      expect(
        (await loadVideoSidecarCaptions(video))!.captions.single.text,
        'Local VTT',
      );
    },
  );

  testWidgets(
    'starts paused, resumes locally, plays, seeks and changes speed',
    (tester) async {
      final fixture = _PlayerFixture(resume: const Duration(seconds: 12));
      await tester.pumpWidget(fixture.widget());
      await tester.pump();
      expect(fixture.controller.value.position, const Duration(seconds: 12));
      expect(fixture.controller.playCalls, 0);
      expect(find.byKey(const ValueKey('video-surface')), findsOneWidget);

      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      expect(fixture.controller.value.isPlaying, isTrue);
      expect(find.byTooltip('Pause video'), findsOneWidget);
      expect(fixture.saved.last, const Duration(seconds: 12));

      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('video-seek')),
      );
      slider.onChanged!(30000);
      slider.onChangeEnd!(30000);
      await tester.pump();
      expect(fixture.controller.value.position, const Duration(seconds: 30));
      expect(fixture.saved.last, const Duration(seconds: 30));

      await tester.tap(find.byTooltip('Playback speed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();
      expect(fixture.controller.value.playbackSpeed, 1.5);
      await tester.tap(find.byTooltip('Pause video'));
      await tester.pump();
      expect(fixture.controller.value.isPlaying, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(fixture.controller.disposeCalls, 1);
    },
  );

  testWidgets('completed and invalid resume positions start at beginning', (
    tester,
  ) async {
    for (final resume in [
      const Duration(seconds: 60),
      const Duration(seconds: 59),
      const Duration(seconds: -2),
    ]) {
      final fixture = _PlayerFixture(resume: resume);
      await tester.pumpWidget(fixture.widget(key: UniqueKey()));
      await tester.pump();
      expect(fixture.controller.value.position, Duration.zero);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  });

  testWidgets('leaving the page saves position and releases its decoder', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    await tester.pumpWidget(fixture.widget());
    await tester.pump();
    await tester.tap(find.byTooltip('Play video'));
    await tester.pump();
    fixture.controller.update(position: const Duration(seconds: 25));
    await tester.pumpWidget(fixture.widget(active: false));
    await tester.pump();
    expect(fixture.saved.last, const Duration(seconds: 25));
    expect(fixture.controller.value.isPlaying, isFalse);
    expect(fixture.controller.disposeCalls, 1);
    expect(find.byKey(const ValueKey('video-surface')), findsNothing);
  });

  testWidgets(
    'background lifecycle pauses and persists without autoplay on resume',
    (tester) async {
      final fixture = _PlayerFixture();
      await tester.pumpWidget(fixture.widget());
      await tester.pump();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      fixture.controller.update(position: const Duration(seconds: 23));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(fixture.controller.value.isPlaying, isFalse);
      expect(fixture.saved.last, const Duration(seconds: 23));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fixture.controller.playCalls, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('inactive and unavailable videos allocate no decoder', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    await tester.pumpWidget(fixture.widget(active: false));
    await tester.pump();
    expect(fixture.createCalls, 0);
    await tester.pumpWidget(fixture.widget(item: _video(available: false)));
    await tester.pump();
    expect(fixture.createCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'codec failure offers retry and explicit external player fallback',
    (tester) async {
      final fixture = _PlayerFixture();
      fixture.controller.initializationError = StateError('unsupported codec');
      await tester.pumpWidget(fixture.widget());
      await tester.pump();
      expect(find.text('Retry video'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.text('Open in device player'));
      expect(fixture.openCalls, 1);
      expect(fixture.controller.disposeCalls, 1);
      fixture.controller = _FakeVideoController();
      await tester.tap(find.text('Retry video'));
      await tester.pump();
      expect(find.byTooltip('Play video'), findsOneWidget);
      expect(fixture.createCalls, 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('bounded loading ignores stale completion and releases player', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    fixture.controller.initializationGate = Completer<void>();
    await tester.pumpWidget(fixture.widget());
    await tester.pump();
    expect(find.text('Opening video…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(find.text('Retry video'), findsOneWidget);
    expect(fixture.controller.disposeCalls, 1);
    fixture.controller.initializationGate!.complete();
    await tester.pump();
    expect(find.byKey(const ValueKey('video-surface')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('buffering and command timeouts return usable error controls', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    await tester.pumpWidget(fixture.widget());
    await tester.pump();
    fixture.controller.update(buffering: true);
    await tester.pump(const Duration(seconds: 16));
    await tester.pump();
    expect(find.text('Retry video'), findsOneWidget);
    expect(fixture.controller.disposeCalls, 1);
    fixture.controller = _FakeVideoController()..playGate = Completer<void>();
    await tester.tap(find.text('Retry video'));
    await tester.pump();
    await tester.tap(find.byTooltip('Play video'));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(
      find.text('Playback timed out. Try opening the video again.'),
      findsOneWidget,
    );
    expect(fixture.controller.disposeCalls, 1);
    fixture.controller.playGate!.complete();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'caption controls and completed playback keep local resume correct',
    (tester) async {
      final fixture = _PlayerFixture();
      fixture.controller.hasCaptions = true;
      await tester.pumpWidget(fixture.widget());
      await tester.pump();
      fixture.controller.update(
        caption: const Caption(
          number: 1,
          start: Duration.zero,
          end: Duration(seconds: 3),
          text: 'Local captions',
        ),
      );
      await tester.pump();
      expect(find.text('Local captions'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide subtitles'));
      await tester.pump();
      expect(find.text('Local captions'), findsNothing);
      fixture.controller.update(
        position: const Duration(seconds: 60),
        completed: true,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(fixture.saved.last, Duration.zero);
    },
  );

  testWidgets(
    'controls fit a compact phone and save periodically while playing',
    (tester) async {
      tester.view.physicalSize = const Size(320, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _PlayerFixture();
      fixture.controller.hasCaptions = true;
      await tester.pumpWidget(fixture.widget());
      await tester.pump();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      fixture.controller.update(position: const Duration(seconds: 8));
      await tester.pump(const Duration(seconds: 5));
      expect(fixture.saved.last, const Duration(seconds: 8));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('viewer swipes release videos and retain the photo viewer', (
    tester,
  ) async {
    final first = _video();
    final second = _video().copyWith(id: 'video-2', name: 'second.mp4');
    final photo = _video().copyWith(
      id: 'photo-3',
      name: 'photo.jpg',
      kind: MediaKind.image,
    );
    final model = _ViewerModel([first, second, photo]);
    final created = <String>[];
    final controllers = <_FakeVideoController>[];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaViewer(
          model: model,
          items: model.items,
          initialIndex: 0,
          videoControllerFactory: (item) {
            created.add(item.id);
            final controller = _FakeVideoController();
            controllers.add(controller);
            return controller;
          },
        ),
      ),
    );
    await tester.pump();
    expect(created, ['video-1']);
    await tester.tap(find.byTooltip('Play video'));
    await tester.pump();
    controllers.first.update(position: const Duration(seconds: 14));
    await tester.drag(
      find.byKey(const ValueKey('media-viewer-pages')),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(created, ['video-1', 'video-2']);
    expect(controllers.first.disposeCalls, 1);
    expect(model.positions['video-1'], const Duration(seconds: 14));
    await tester.tap(find.byTooltip('Next item'));
    await tester.pumpAndSettle();
    expect(controllers.last.disposeCalls, 1);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Play video'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    model.dispose();
  });

  testWidgets(
    'authorization loss releases playback and hides cached viewer metadata',
    (tester) async {
      final first = _video().copyWith(
        source: MediaSource.phone,
        name: 'private-video.mp4',
      );
      final second = _video().copyWith(
        id: 'private-2',
        source: MediaSource.phone,
      );
      final model = _ViewerModel([first, second]);
      final controller = _FakeVideoController();
      var decoderCreations = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(
            model: model,
            items: model.items,
            initialIndex: 0,
            videoControllerFactory: (_) {
              decoderCreations++;
              return controller;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Play video'));
      await tester.pump();
      await tester.tap(find.byTooltip('Viewer actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.text('private-video.mp4'), findsWidgets);
      expect(find.text('1024 bytes'), findsOneWidget);
      final priorThumbnailCalls = model.thumbnailCalls;
      model.allowedIds = <String>{};
      model.items.clear();
      model.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(controller.disposeCalls, 1);
      expect(find.byKey(const ValueKey('video-surface')), findsNothing);
      expect(find.text('private-video.mp4'), findsNothing);
      expect(find.text('1024 bytes'), findsNothing);
      expect(find.byTooltip('Viewer actions'), findsNothing);
      expect(find.byTooltip('Favorite'), findsNothing);
      expect(find.text('Media unavailable'), findsOneWidget);
      expect(model.thumbnailCalls, priorThumbnailCalls);
      expect(decoderCreations, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      model.dispose();
    },
  );
}

MediaItem _video({String? uri, bool available = true}) => MediaItem(
  id: 'video-1',
  name: 'local.mp4',
  uri: uri ?? 'file:///C:/Gallery/local.mp4',
  relativePath: 'Gallery',
  kind: MediaKind.video,
  source: MediaSource.pc,
  metadata: MediaMetadata(sizeBytes: 1024, modifiedAt: DateTime.utc(2026)),
  indexedAt: DateTime.utc(2026),
  isAvailable: available,
);

class _PlayerFixture {
  _PlayerFixture({this.resume = Duration.zero});

  final Duration resume;
  _FakeVideoController controller = _FakeVideoController();
  final saved = <Duration>[];
  int createCalls = 0;
  int openCalls = 0;

  Widget widget({bool active = true, MediaItem? item, Key? key}) => MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: LocalVideoPlayer(
        key: key,
        item: item ?? _video(),
        active: active,
        poster: const Center(child: Text('Poster')),
        readPosition: (_) async => resume,
        savePosition: (_, position) async => saved.add(position),
        openExternal: () => openCalls++,
        controllerFactory: (_) {
          createCalls++;
          return controller;
        },
      ),
    ),
  );
}

class _FakeVideoController extends ChangeNotifier
    implements VideoPlaybackController {
  @override
  VideoPlayerValue value = const VideoPlayerValue.uninitialized();
  @override
  bool hasCaptions = false;
  Object? initializationError;
  Completer<void>? initializationGate;
  Completer<void>? playGate;
  int playCalls = 0;
  int disposeCalls = 0;
  bool disposed = false;

  @override
  Widget buildVideo() => const SizedBox(key: ValueKey('video-surface'));

  @override
  Future<void> initialize() async {
    if (initializationGate != null) await initializationGate!.future;
    if (initializationError != null) throw initializationError!;
    if (disposed) return;
    value = const VideoPlayerValue(
      duration: Duration(seconds: 60),
      isInitialized: true,
      size: Size(1920, 1080),
    );
    notifyListeners();
  }

  void update({
    Duration? position,
    bool? playing,
    bool? buffering,
    bool? completed,
    double? speed,
    Caption? caption,
  }) {
    value = value.copyWith(
      position: position,
      isPlaying: playing,
      isBuffering: buffering,
      isCompleted: completed,
      playbackSpeed: speed,
      caption: caption,
    );
    if (!disposed) notifyListeners();
  }

  @override
  Future<void> play() async {
    playCalls++;
    if (playGate != null) await playGate!.future;
    if (!disposed) update(playing: true);
  }

  @override
  Future<void> pause() async => update(playing: false);
  @override
  Future<void> seekTo(Duration position) async => update(position: position);
  @override
  Future<void> setPlaybackSpeed(double speed) async => update(speed: speed);
  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    super.dispose();
  }
}

class _ViewerModel extends ChangeNotifier implements GalleryModel {
  _ViewerModel(this.items);

  @override
  final List<MediaItem> items;
  final positions = <String, Duration>{};
  Set<String>? allowedIds;
  int thumbnailCalls = 0;

  @override
  bool canAccessMedia(MediaItem item) =>
      allowedIds?.contains(item.id) ?? item.isAvailable;

  @override
  Future<Duration> readVideoPosition(MediaItem item) async =>
      positions[item.id] ?? Duration.zero;
  @override
  Future<void> saveVideoPosition(MediaItem item, Duration position) async {
    positions[item.id] = position;
  }

  @override
  Future<Uint8List?> loadThumbnail(MediaItem item, {int size = 384}) async {
    thumbnailCalls++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
