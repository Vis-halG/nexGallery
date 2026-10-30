import '../../l10n/app_strings.dart';

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../services/editing/image_editor.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';

class PhotoEditorPage extends StatefulWidget {
  const PhotoEditorPage({
    required this.item,
    required this.model,
    required this.tools,
    super.key,
  });
  final MediaItem item;
  final GalleryModel model;
  final GalleryTools tools;
  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

const _markupColors = <int>[
  0xFFFF3B30,
  0xFFFFCC00,
  0xFF34C759,
  0xFF0A84FF,
  0xFFFFFFFF,
  0xFF000000,
];

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  Uint8List? _source, _preview;
  Size? _previewSize;
  final _text = TextEditingController();
  int _turns = 0, _generation = 0;
  bool _flip = false, _busy = false, _drawing = false;
  double _brightness = 1, _contrast = 1, _saturation = 1, _warmth = 0;
  double _straighten = 0;
  ImageFilter _filter = ImageFilter.none;
  final _strokes = <MarkupStroke>[];
  List<(double, double)>? _activeStroke;
  int _color = _markupColors.first;
  RangeValues _horizontal = const RangeValues(0, 1),
      _vertical = const RangeValues(0, 1);
  String? _error;
  ImageEdit get _edit => ImageEdit(
    quarterTurns: _turns,
    flip: _flip,
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
    warmth: _warmth,
    left: _horizontal.start,
    right: _horizontal.end,
    top: _vertical.start,
    bottom: _vertical.end,
    text: _text.text,
    straighten: _straighten,
    filter: _filter,
    strokes: List.of(_strokes),
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      _source = await widget.model.loadThumbnail(widget.item, size: 1024);
      if (_source == null) {
        throw const FormatException(
          'An editable preview is unavailable for this image.',
        );
      }
      await _render();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _render() async {
    if (_source == null) return;
    final generation = ++_generation;
    final bytes = _source!, edit = _edit;
    try {
      final preview = await Isolate.run(() => editImage(bytes, edit));
      if (mounted && generation == _generation) {
        setState(() {
          _preview = preview;
          _previewSize = _pngSize(preview);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    File? source;
    try {
      source = await widget.tools.materialize(widget.item);
      if (await source.length() > 64 << 20) {
        throw const FormatException('This image is too large for this editor.');
      }
      final bytes = await source.readAsBytes(), edit = _edit;
      final output = await Isolate.run(() => editImage(bytes, edit));
      await widget.tools.saveEditedCopy(widget.item, output);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: AppText('Edited copy saved.')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (Platform.isAndroid && source != null && await source.exists()) {
        await source.delete();
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(VoidCallback update) {
    setState(update);
    _render();
  }

  Widget _slider(
    String name,
    double value,
    double min,
    double max,
    void Function(double) change,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(name)),
          Text(value.toStringAsFixed(2)),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        label: name,
        onChanged: _busy ? null : (v) => setState(() => change(v)),
        onChangeEnd: (_) => _render(),
      ),
    ],
  );

  /// Maps a pointer inside the preview box to normalized image coordinates.
  (double, double)? _normalized(Offset local, Size box) {
    final image = _previewSize;
    if (image == null || image.isEmpty) return null;
    final scale = (box.width / image.width) < (box.height / image.height)
        ? box.width / image.width
        : box.height / image.height;
    final shown = Size(image.width * scale, image.height * scale);
    final origin = Offset(
      (box.width - shown.width) / 2,
      (box.height - shown.height) / 2,
    );
    final x = (local.dx - origin.dx) / shown.width;
    final y = (local.dy - origin.dy) / shown.height;
    if (x < 0 || y < 0 || x > 1 || y > 1) return null;
    return (x, y);
  }

  Widget _previewArea(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * 0.4,
    child: _preview == null
        ? const Center(child: CircularProgressIndicator())
        : LayoutBuilder(
            builder: (context, constraints) {
              final box = constraints.biggest;
              return GestureDetector(
                onPanStart: !_drawing
                    ? null
                    : (details) {
                        final point = _normalized(details.localPosition, box);
                        if (point != null) {
                          setState(() => _activeStroke = [point]);
                        }
                      },
                onPanUpdate: !_drawing
                    ? null
                    : (details) {
                        final point = _normalized(details.localPosition, box);
                        if (point != null && _activeStroke != null) {
                          setState(() => _activeStroke!.add(point));
                        }
                      },
                onPanEnd: !_drawing
                    ? null
                    : (_) {
                        final stroke = _activeStroke;
                        if (stroke == null) return;
                        _change(() {
                          _strokes.add(MarkupStroke(stroke, color: _color));
                          _activeStroke = null;
                        });
                      },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(_preview!, gaplessPlayback: true),
                    if (_activeStroke != null && _previewSize != null)
                      CustomPaint(
                        painter: _StrokePainter(
                          _activeStroke!,
                          _previewSize!,
                          Color(_color),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const AppText('Edit photo'),
      actions: [
        TextButton(
          onPressed: _busy || _source == null ? null : _save,
          child: const AppText('Save copy'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      physics: _drawing ? const NeverScrollableScrollPhysics() : null,
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        _previewArea(context),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _change(() => _turns++),
              icon: const Icon(Icons.rotate_right),
              label: const AppText('Rotate'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _change(() => _flip = !_flip),
              icon: const Icon(Icons.flip),
              label: const AppText('Flip'),
            ),
            FilterChip(
              selected: _drawing,
              avatar: const Icon(Icons.draw_rounded, size: 18),
              label: const AppText('Draw'),
              onSelected: _busy
                  ? null
                  : (value) => setState(() => _drawing = value),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _change(() {
                      _turns = 0;
                      _flip = false;
                      _brightness = _contrast = _saturation = 1;
                      _warmth = 0;
                      _straighten = 0;
                      _filter = ImageFilter.none;
                      _strokes.clear();
                      _horizontal = _vertical = const RangeValues(0, 1);
                      _text.clear();
                    }),
              child: const AppText('Reset'),
            ),
          ],
        ),
        if (_drawing) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (final color in _markupColors)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Semantics(
                    button: true,
                    selected: color == _color,
                    label: 'Markup color',
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = color),
                      child: CircleAvatar(
                        radius: color == _color ? 16 : 13,
                        backgroundColor: Theme.of(context).colorScheme.outline,
                        child: CircleAvatar(
                          radius: color == _color ? 13 : 12,
                          backgroundColor: Color(color),
                        ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              IconButton(
                tooltip: context.tr('Undo last stroke'),
                onPressed: _strokes.isEmpty || _busy
                    ? null
                    : () => _change(_strokes.removeLast),
                icon: const Icon(Icons.undo_rounded),
              ),
            ],
          ),
          const AppText('Draw on the photo with your finger or mouse.'),
        ],
        const SizedBox(height: 16),
        const AppText('Filters'),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final filter in ImageFilter.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: _filter == filter,
                    label: Text(_filterLabel(filter)),
                    onSelected: _busy
                        ? null
                        : (_) => _change(() => _filter = filter),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _slider(
          'Straighten (degrees)',
          _straighten,
          -15,
          15,
          (v) => _straighten = (v * 2).roundToDouble() / 2,
        ),
        const AppText('Horizontal crop'),
        RangeSlider(
          values: _horizontal,
          onChanged: _busy
              ? null
              : (v) {
                  if (v.end - v.start >= 0.05) setState(() => _horizontal = v);
                },
          onChangeEnd: (_) => _render(),
        ),
        const AppText('Vertical crop'),
        RangeSlider(
          values: _vertical,
          onChanged: _busy
              ? null
              : (v) {
                  if (v.end - v.start >= 0.05) setState(() => _vertical = v);
                },
          onChangeEnd: (_) => _render(),
        ),
        _slider('Brightness', _brightness, 0.25, 2, (v) => _brightness = v),
        _slider('Contrast', _contrast, 0, 2, (v) => _contrast = v),
        _slider('Saturation', _saturation, 0, 2, (v) => _saturation = v),
        _slider('Warmth', _warmth, -1, 1, (v) => _warmth = v),
        TextField(
          controller: _text,
          maxLength: 120,
          decoration: InputDecoration(labelText: context.tr('Add text')),
          onSubmitted: (_) => _render(),
        ),
        const AppText(
          'Your original stays unchanged. The edited copy is saved as a PNG.',
        ),
        const SizedBox(height: 24),
      ],
    ),
  );
}

String _filterLabel(ImageFilter filter) => switch (filter) {
  ImageFilter.none => 'Original',
  ImageFilter.vivid => 'Vivid',
  ImageFilter.warm => 'Warm',
  ImageFilter.cool => 'Cool',
  ImageFilter.mono => 'Mono',
  ImageFilter.sepia => 'Sepia',
  ImageFilter.fade => 'Fade',
};

Size? _pngSize(Uint8List png) {
  if (png.length < 24) return null;
  final data = ByteData.sublistView(png);
  return Size(data.getUint32(16).toDouble(), data.getUint32(20).toDouble());
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.points, this.image, this.color);
  final List<(double, double)> points;
  final Size image;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / image.width) < (size.height / image.height)
        ? size.width / image.width
        : size.height / image.height;
    final shown = Size(image.width * scale, image.height * scale);
    final origin = Offset(
      (size.width - shown.width) / 2,
      (size.height - shown.height) / 2,
    );
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.008 * (shown.longestSide)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point =
          origin +
          Offset(points[i].$1 * shown.width, points[i].$2 * shown.height);
      i == 0
          ? path.moveTo(point.dx, point.dy)
          : path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _StrokePainter old) => true;
}
