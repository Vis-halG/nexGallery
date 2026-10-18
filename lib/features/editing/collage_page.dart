import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../services/editing/image_editor.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';

/// Builds a grid collage from 2-9 photos and saves it as a new image.
class CollagePage extends StatefulWidget {
  const CollagePage({
    required this.model,
    required this.tools,
    required this.items,
    super.key,
  });

  final GalleryModel model;
  final GalleryTools tools;
  final List<MediaItem> items;

  @override
  State<CollagePage> createState() => _CollagePageState();
}

class _CollagePageState extends State<CollagePage> {
  List<Uint8List>? _photos;
  Uint8List? _preview;
  bool _dark = false;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final photos = <Uint8List>[];
      for (final item in widget.items.take(9)) {
        final bytes = await widget.model.loadThumbnail(item, size: 1024);
        if (bytes != null) photos.add(bytes);
      }
      if (photos.length < 2) {
        throw const FormatException('At least two photos must be available.');
      }
      _photos = photos;
      await _render();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _render() async {
    final photos = _photos!, dark = _dark;
    final preview = await Isolate.run(
      () => buildCollage(photos, width: 1024, gap: 6, dark: dark),
    );
    if (mounted) setState(() => _preview = preview);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final photos = _photos!, dark = _dark;
      final output = await Isolate.run(
        () => buildCollage(photos, width: 2048, dark: dark),
      );
      await widget.tools.saveEditedCopy(widget.items.first, output);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Collage saved.')));
        Navigator.pop(context);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Collage'),
      actions: [
        TextButton(
          onPressed: _busy || _preview == null ? null : _save,
          child: const Text('Save'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_preview != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(_preview!, gaplessPlayback: true),
          ),
        SwitchListTile.adaptive(
          title: const Text('Dark background'),
          value: _dark,
          onChanged: _busy || _photos == null
              ? null
              : (value) {
                  setState(() => _dark = value);
                  _render();
                },
        ),
        Text(
          '${widget.items.length} photos. The collage is saved as a new PNG; your photos are unchanged.',
        ),
      ],
    ),
  );
}
