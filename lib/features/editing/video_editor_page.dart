import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

import '../../core/media_item.dart';
import '../../services/editing/video_editor.dart';
import '../../services/files/file_tools.dart';
import '../../src/gallery_tools.dart';

class VideoEditorPage extends StatefulWidget {
  const VideoEditorPage({required this.tools, required this.item, super.key});
  final GalleryTools tools;
  final MediaItem item;
  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  final _editor = VideoEditor();
  VideoPlayerController? _player;
  File? _input;
  File? _output;
  String? _error;
  bool _busy = false;
  bool _cancelled = false;
  bool _mute = false, _compress = false;
  int _rotation = 0;
  RangeValues _range = const RangeValues(0, 1);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final input = await widget.tools.materialize(widget.item);
      _input = input;
      final player = VideoPlayerController.file(input);
      _player = player;
      await player.initialize();
      if (!mounted) return;
      if (player.value.duration.inMilliseconds <= 0) {
        throw StateError('This video has no editable duration.');
      }
      setState(
        () => _range = RangeValues(
          0,
          player.value.duration.inMilliseconds.toDouble(),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _editor.cancel();
    final player = _player;
    final input = _input, output = _output;
    Future<void>(() async {
      await player?.dispose();
      if (Platform.isAndroid && input != null && await input.exists()) {
        await input.delete();
      }
      if (output != null && await output.exists()) await output.delete();
    });
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _cancelled = false;
      _error = null;
    });
    try {
      await _player!.pause();
      final dir = await widget.tools.toolsDirectory();
      final output = File(p.join(dir.path, 'video-${uniqueId()}.mp4'));
      _output = output;
      await _editor.export(
        input: _input!,
        output: output,
        startMs: _range.start.round(),
        endMs: _range.end.round(),
        rotation: _rotation,
        mute: _mute,
        compress: _compress,
      );
      if (_cancelled) return;
      final saved = await widget.tools.saveVideoCopy(widget.item, output);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Saved edited copy: $saved')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted && !_cancelled) setState(() => _error = e.toString());
    } finally {
      if (_output != null && await _output!.exists()) await _output!.delete();
      _output = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final ready = player?.value.isInitialized == true;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit video'),
          actions: [
            TextButton(
              onPressed: !ready || _busy ? null : _save,
              child: const Text('Save copy'),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) ...[
              const LinearProgressIndicator(),
              const Text('Exporting video…'),
              TextButton(
                onPressed: () async {
                  _cancelled = true;
                  await _editor.cancel();
                },
                child: const Text('Cancel export'),
              ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (!ready && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (ready) ...[
              AspectRatio(
                aspectRatio: player!.value.aspectRatio,
                child: VideoPlayer(player),
              ),
              ValueListenableBuilder(
                valueListenable: player,
                builder: (_, value, _) => IconButton(
                  tooltip: value.isPlaying ? 'Pause preview' : 'Play selection',
                  onPressed: _busy
                      ? null
                      : () async {
                          if (value.isPlaying) {
                            await player.pause();
                          } else {
                            await player.seekTo(
                              Duration(milliseconds: _range.start.round()),
                            );
                            await player.play();
                          }
                        },
                  icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
              ),
              Text(
                'Trim: ${(_range.start / 1000).toStringAsFixed(1)} s – ${(_range.end / 1000).toStringAsFixed(1)} s',
              ),
              RangeSlider(
                min: 0,
                max: player.value.duration.inMilliseconds.toDouble(),
                values: _range,
                onChanged: _busy
                    ? null
                    : (v) {
                        if (v.end - v.start >= 100) setState(() => _range = v);
                      },
                onChangeEnd: (v) =>
                    player.seekTo(Duration(milliseconds: v.start.round())),
              ),
              DropdownButtonFormField<int>(
                initialValue: _rotation,
                decoration: const InputDecoration(labelText: 'Rotate'),
                items: [
                  for (final v in [0, 90, 180, 270])
                    DropdownMenuItem(value: v, child: Text('$v°')),
                ],
                onChanged: _busy ? null : (v) => setState(() => _rotation = v!),
              ),
              SwitchListTile(
                title: const Text('Remove audio'),
                value: _mute,
                onChanged: _busy ? null : (v) => setState(() => _mute = v),
              ),
              SwitchListTile(
                title: const Text('Export at 720p'),
                subtitle: const Text(
                  'Re-encode a smaller-resolution MP4. File size depends on the source.',
                ),
                value: _compress,
                onChanged: _busy ? null : (v) => setState(() => _compress = v),
              ),
              const Text(
                'The preview shows the source video. Edits are applied when you save a copy. Export support depends on the device codecs.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
