import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class FilePreview extends StatefulWidget {
  const FilePreview({
    required this.name,
    this.file,
    this.videoUri,
    this.isVideo = false,
    super.key,
  });
  final String name;
  final File? file;
  final Uri? videoUri;
  final bool isVideo;
  @override
  State<FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<FilePreview> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  String? _error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.isVideo) _initialize();
  }

  Future<void> _initialize() async {
    final controller = widget.videoUri != null
        ? VideoPlayerController.networkUrl(widget.videoUri!)
        : VideoPlayerController.file(widget.file!);
    _controller = controller;
    try {
      await controller.initialize();
      if (mounted) {
        setState(() {});
        await controller.play();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'This video could not be played: $error');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller?.pause();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.name)),
    body: _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!),
            ),
          )
        : !widget.isVideo
        ? InteractiveViewer(
            maxScale: 5,
            child: Center(
              child: Image.file(
                widget.file!,
                errorBuilder: (_, _, _) =>
                    const AppText('Preview unavailable for this format.'),
              ),
            ),
          )
        : _controller?.value.isInitialized != true
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              ),
              VideoProgressIndicator(
                _controller!,
                allowScrubbing: true,
                padding: const EdgeInsets.all(16),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: context.tr('Play or pause'),
                    icon: const Icon(Icons.play_circle),
                    onPressed: () async {
                      if (_controller!.value.isPlaying) {
                        await _controller!.pause();
                      } else {
                        await _controller!.play();
                      }
                      if (mounted) setState(() {});
                    },
                  ),
                  PopupMenuButton<double>(
                    tooltip: context.tr('Playback speed'),
                    onSelected: (v) => _controller!.setPlaybackSpeed(v),
                    itemBuilder: (_) => [
                      for (final v in [0.5, 1.0, 1.5, 2.0])
                        PopupMenuItem(value: v, child: Text('${v}x')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
  );
}
