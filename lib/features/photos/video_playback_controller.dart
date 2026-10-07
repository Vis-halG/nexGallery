import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../../core/media_item.dart';

/// The presentation adapter makes decoder lifecycle and failures testable
/// without requiring a platform texture in a widget test.
abstract interface class VideoPlaybackController implements Listenable {
  VideoPlayerValue get value;
  bool get hasCaptions;
  Widget buildVideo();
  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setPlaybackSpeed(double speed);
  Future<void> dispose();
}

typedef VideoPlaybackControllerFactory = VideoPlaybackController Function(
  MediaItem item,
);

/// Only catalogue-local content may be played. Network streaming is a separate
/// authenticated feature and must never be inferred from an arbitrary URI.
VideoPlaybackController createLocalVideoController(MediaItem item) {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.windows)) {
    throw UnsupportedError('Local playback supports Android and Windows.');
  }
  if (!item.isAvailable || item.kind != MediaKind.video) {
    throw StateError('The original video is unavailable.');
  }
  final uri = Uri.tryParse(item.uri);
  if (uri == null) throw const FormatException('Invalid video location.');
  if (uri.scheme == 'content' &&
      defaultTargetPlatform == TargetPlatform.android) {
    return _PlatformVideoController(VideoPlayerController.contentUri(uri));
  }
  if (uri.scheme != 'file' || uri.host.isNotEmpty) {
    throw UnsupportedError('Only local video files can be played here.');
  }
  final file = File.fromUri(uri);
  return _PlatformVideoController(
    VideoPlayerController.file(file),
    sidecarVideo: file,
  );
}

/// Load a same-basename SRT or WebVTT sidecar, with bounded reads. Captions are
/// optional: unreadable or malformed captions must not prevent video playback.
Future<ClosedCaptionFile?> loadVideoSidecarCaptions(
  File video, {
  int maximumBytes = 1 << 20,
}) async {
  final filename = video.uri.pathSegments.last;
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return null;
  final stem = filename.substring(0, dot);
  for (final extension in ['srt', 'vtt']) {
    final file = File.fromUri(
      video.parent.uri.resolveUri(Uri(path: '$stem.$extension')),
    );
    try {
      if (!await file.exists() || await file.length() > maximumBytes) continue;
      // The stream limit also bounds a file that grows after the length check.
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, maximumBytes + 1)) {
        bytes.addAll(chunk);
        if (bytes.length > maximumBytes) break;
      }
      if (bytes.length > maximumBytes) continue;
      final text = utf8.decode(bytes);
      final captions = extension == 'srt'
          ? SubRipCaptionFile(text)
          : WebVTTCaptionFile(text);
      if (captions.captions.isNotEmpty) return captions;
    } on Object {
      // A sidecar is optional and stays local.
    }
  }
  return null;
}

final class _PlatformVideoController implements VideoPlaybackController {
  _PlatformVideoController(this._controller, {this.sidecarVideo});

  final VideoPlayerController _controller;
  final File? sidecarVideo;
  bool _hasCaptions = false;

  @override
  VideoPlayerValue get value => _controller.value;
  @override
  bool get hasCaptions => _hasCaptions;
  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);
  @override
  Widget buildVideo() => VideoPlayer(_controller);
  @override
  Future<void> initialize() async {
    await _controller.initialize();
    if (sidecarVideo != null) {
      final captions = await loadVideoSidecarCaptions(sidecarVideo!)
          .timeout(const Duration(seconds: 2), onTimeout: () => null);
      if (captions != null) {
        await _controller.setClosedCaptionFile(Future.value(captions));
        _hasCaptions = true;
      }
    }
  }

  @override
  Future<void> play() => _controller.play();
  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);
  @override
  Future<void> setPlaybackSpeed(double speed) =>
      _controller.setPlaybackSpeed(speed);
  @override
  Future<void> dispose() => _controller.dispose();
}
