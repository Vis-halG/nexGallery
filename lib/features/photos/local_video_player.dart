import '../../l10n/app_strings.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import 'video_playback_controller.dart';

class LocalVideoPlayer extends StatefulWidget {
  const LocalVideoPlayer({
    required this.item,
    required this.active,
    required this.poster,
    required this.readPosition,
    required this.savePosition,
    required this.openExternal,
    this.controllerFactory = createLocalVideoController,
    this.initializationTimeout = const Duration(seconds: 15),
    this.operationTimeout = const Duration(seconds: 5),
    super.key,
  });

  final MediaItem item;
  final bool active;
  final Widget poster;
  final Future<Duration> Function(MediaItem) readPosition;
  final Future<void> Function(MediaItem, Duration) savePosition;
  final VoidCallback openExternal;
  final VideoPlaybackControllerFactory controllerFactory;
  final Duration initializationTimeout;
  final Duration operationTimeout;

  @override
  State<LocalVideoPlayer> createState() => _LocalVideoPlayerState();
}

class _LocalVideoPlayerState extends State<LocalVideoPlayer>
    with WidgetsBindingObserver {
  VideoPlaybackController? _controller;
  Timer? _saveTimer;
  Timer? _bufferingTimer;
  int _generation = 0;
  bool _ready = false;
  bool _commandPending = false;
  bool _showCaptions = true;
  bool _foreground = true;
  String? _error;
  String? _commandError;
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (widget.active && widget.item.isAvailable) unawaited(_initialize());
  }

  @override
  void didUpdateWidget(LocalVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final replaced =
        oldWidget.item.id != widget.item.id ||
        oldWidget.item.uri != widget.item.uri;
    if (replaced || !widget.active || !widget.item.isAvailable) {
      _release(item: oldWidget.item, save: true);
    }
    if (widget.active && widget.item.isAvailable && _controller == null) {
      if (replaced || !oldWidget.active || !oldWidget.item.isAvailable) {
        unawaited(_initialize());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (mounted) setState(() {});
    final controller = _controller;
    if (!_foreground && controller != null && _ready) {
      unawaited(_pauseAndSave(controller));
    }
  }

  Future<void> _pauseAndSave(VideoPlaybackController controller) async {
    try {
      await controller.pause().timeout(widget.operationTimeout);
    } on Object {
      // Do not leave a failing decoder playing while the app is inactive.
      if (identical(controller, _controller)) {
        _release(save: true);
        if (mounted) setState(() => _error = 'Playback was interrupted.');
      }
    }
    await _save(widget.item, controller);
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    _error = null;
    _commandError = null;
    _ready = false;
    VideoPlaybackController? controller;
    try {
      controller = widget.controllerFactory(widget.item);
      _controller = controller;
      controller.addListener(_changed);
      await controller.initialize().timeout(widget.initializationTimeout);
      if (!_isCurrent(controller, generation)) return;
      if (!controller.value.isInitialized || controller.value.hasError) {
        throw StateError('Video decoder could not read this file.');
      }
      Duration position;
      try {
        position = await widget
            .readPosition(widget.item)
            .timeout(widget.operationTimeout);
      } on Object {
        position = Duration.zero;
      }
      if (!_isCurrent(controller, generation)) return;
      final duration = controller.value.duration;
      // Completed videos start from the beginning instead of resuming at end.
      if (position > Duration.zero &&
          duration > const Duration(seconds: 2) &&
          position < duration - const Duration(seconds: 2)) {
        await controller.seekTo(position).timeout(widget.operationTimeout);
      }
      if (!_isCurrent(controller, generation)) return;
      setState(() => _ready = true);
      _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_ready && controller!.value.isPlaying) {
          unawaited(_save(widget.item, controller));
        }
      });
      // Opening a gallery item prepares its first frame; playback starts only
      // through the explicit Play control.
      if (!_foreground) {
        await controller.pause().timeout(widget.operationTimeout);
      }
      _changed();
    } on Object {
      if (!mounted || generation != _generation) return;
      _release();
      setState(() {
        _error = 'This video could not be opened with this device’s codecs.';
      });
    }
  }

  bool _isCurrent(VideoPlaybackController controller, int generation) =>
      mounted &&
      widget.active &&
      generation == _generation &&
      identical(controller, _controller);

  void _changed() {
    final controller = _controller;
    if (!mounted || controller == null) return;
    if (controller.value.hasError) {
      _release(save: true);
      setState(() => _error = 'Playback failed. Try another device player.');
      return;
    }
    if (_ready && controller.value.isBuffering) {
      _bufferingTimer ??= Timer(widget.initializationTimeout, () {
        if (!mounted || !identical(controller, _controller)) return;
        _release(save: true);
        setState(
          () => _error = 'Playback stalled. Try opening the video again.',
        );
      });
    } else {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
    }
    setState(() {});
  }

  Future<void> _save(MediaItem item, VideoPlaybackController controller) async {
    if (!controller.value.isInitialized) return;
    final value = controller.value;
    final position =
        value.isCompleted ||
            (value.duration > Duration.zero && value.position >= value.duration)
        ? Duration.zero
        : value.position;
    try {
      await widget
          .savePosition(item, position)
          .timeout(widget.operationTimeout);
    } on Object {
      // Playback remains usable if its small local resume record cannot save.
    }
  }

  void _release({MediaItem? item, bool save = false}) {
    ++_generation;
    _saveTimer?.cancel();
    _saveTimer = null;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    final controller = _controller;
    _controller = null;
    _ready = false;
    _commandPending = false;
    _dragPosition = null;
    if (controller == null) return;
    controller.removeListener(_changed);
    if (save) unawaited(_save(item ?? widget.item, controller));
    unawaited(_disposeController(controller));
  }

  Future<void> _disposeController(VideoPlaybackController controller) async {
    try {
      await controller.pause().timeout(widget.operationTimeout);
    } on Object {
      // Dispose still runs if the platform pause command fails.
    }
    try {
      await controller.dispose().timeout(widget.operationTimeout);
    } on Object {
      // Decoder/plugin errors are represented in the viewer, never unhandled.
    }
  }

  Future<void> _command(
    Future<void> Function(VideoPlaybackController) command,
  ) async {
    final controller = _controller;
    if (!_ready || controller == null || _commandPending) return;
    setState(() {
      _commandPending = true;
      _commandError = null;
    });
    try {
      await command(controller).timeout(widget.operationTimeout);
      await _save(widget.item, controller);
    } on TimeoutException {
      if (mounted && identical(controller, _controller)) {
        _release(save: true);
        setState(
          () => _error = 'Playback timed out. Try opening the video again.',
        );
      }
    } on Object {
      if (mounted && identical(controller, _controller)) {
        setState(() => _commandError = 'This playback control is unavailable.');
      }
    } finally {
      if (mounted && identical(controller, _controller)) {
        setState(() {
          _commandPending = false;
          _dragPosition = null;
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release(save: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.item.isAvailable || !widget.active) return widget.poster;
    final controller = _controller;
    final value = controller?.value;
    if (_error != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.poster,
          Center(
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: () {
                          setState(() => _error = null);
                          unawaited(_initialize());
                        },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const AppText('Retry video'),
                      ),
                      OutlinedButton.icon(
                        onPressed: widget.openExternal,
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const AppText('Open in device player'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (!_ready || controller == null || value == null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          widget.poster,
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  semanticsLabel: 'Loading local video',
                ),
                SizedBox(height: 12),
                AppText(
                  'Opening video…',
                  style: TextStyle(color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final maximum = value.duration.inMilliseconds.toDouble();
    final position = (_dragPosition ?? value.position.inMilliseconds.toDouble())
        .clamp(0.0, maximum > 0 ? maximum : 1.0);
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: value.aspectRatio > 0
                      ? value.aspectRatio
                      : 16 / 9,
                  child: controller.buildVideo(),
                ),
              ),
              if (value.isBuffering)
                const Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Buffering local video',
                  ),
                ),
              if (_showCaptions && value.caption.text.isNotEmpty)
                Positioned(
                  bottom: 12,
                  left: 12,
                  right: 12,
                  child: Text(
                    value.caption.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      backgroundColor: Colors.black87,
                      fontSize: 18,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Slider(
          key: const ValueKey('video-seek'),
          value: position,
          max: maximum > 0 ? maximum : 1,
          semanticFormatterCallback: (position) =>
              '${_time(Duration(milliseconds: position.round()))} of ${_time(value.duration)}',
          onChanged: maximum > 0 && !_commandPending
              ? (position) => setState(() => _dragPosition = position)
              : null,
          onChangeEnd: (position) => _command(
            (controller) =>
                controller.seekTo(Duration(milliseconds: position.round())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              IconButton(
                tooltip: value.isPlaying ? 'Pause video' : 'Play video',
                color: Colors.white,
                onPressed: _commandPending || !_foreground
                    ? null
                    : () => _command((controller) async {
                        if (controller.value.isPlaying) {
                          await controller.pause();
                        } else {
                          if (controller.value.position >=
                              controller.value.duration) {
                            await controller.seekTo(Duration.zero);
                          }
                          await controller.play();
                        }
                      }),
                icon: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              Expanded(
                child: Text(
                  '${_time(Duration(milliseconds: position.round()))} / ${_time(value.duration)}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
              if (controller.hasCaptions)
                IconButton(
                  tooltip: _showCaptions ? 'Hide subtitles' : 'Show subtitles',
                  color: Colors.white,
                  onPressed: () =>
                      setState(() => _showCaptions = !_showCaptions),
                  icon: Icon(
                    _showCaptions
                        ? Icons.closed_caption_rounded
                        : Icons.closed_caption_off_rounded,
                  ),
                ),
              PopupMenuButton<double>(
                tooltip: context.tr('Playback speed'),
                enabled: !_commandPending,
                initialValue: value.playbackSpeed,
                onSelected: (speed) => _command(
                  (controller) => controller.setPlaybackSpeed(speed),
                ),
                itemBuilder: (_) => [
                  for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                    PopupMenuItem(value: speed, child: Text('${speed}x')),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${value.playbackSpeed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_commandError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _commandError!,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
      ],
    );
  }
}

String _time(Duration value) {
  final seconds = value.inSeconds;
  final minutes = (seconds ~/ 60).toString();
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}
