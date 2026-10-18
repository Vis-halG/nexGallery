import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

enum ImageFilter { none, vivid, warm, cool, mono, sepia, fade }

/// One freehand markup stroke in coordinates normalized to the edited image.
final class MarkupStroke {
  const MarkupStroke(
    this.points, {
    this.color = 0xFFFF3B30,
    this.width = 0.008,
  });
  final List<(double, double)> points;
  final int color;

  /// Width as a fraction of the image's longer side.
  final double width;
}

final class ImageEdit {
  const ImageEdit({
    this.quarterTurns = 0,
    this.flip = false,
    this.brightness = 1,
    this.contrast = 1,
    this.saturation = 1,
    this.warmth = 0,
    this.left = 0,
    this.top = 0,
    this.right = 1,
    this.bottom = 1,
    this.text = '',
    this.straighten = 0,
    this.filter = ImageFilter.none,
    this.strokes = const [],
  });
  final int quarterTurns;
  final bool flip;
  final double brightness,
      contrast,
      saturation,
      warmth,
      left,
      top,
      right,
      bottom;
  final String text;

  /// Small rotation in degrees (-15..15); the result is cropped to hide corners.
  final double straighten;
  final ImageFilter filter;
  final List<MarkupStroke> strokes;
}

Uint8List editImage(Uint8List bytes, ImageEdit edit) {
  var image = _decode(bytes);
  if (edit.left < 0 ||
      edit.top < 0 ||
      edit.right > 1 ||
      edit.bottom > 1 ||
      edit.right <= edit.left ||
      edit.bottom <= edit.top) {
    throw const FormatException('The crop rectangle is invalid.');
  }
  if (edit.straighten.abs() > 15) {
    throw const FormatException('Straighten by at most 15 degrees.');
  }
  if (edit.straighten != 0) image = _straighten(image, edit.straighten);
  image = img.copyCrop(
    image,
    x: (image.width * edit.left).floor(),
    y: (image.height * edit.top).floor(),
    width: (image.width * (edit.right - edit.left)).round().clamp(
      1,
      image.width,
    ),
    height: (image.height * (edit.bottom - edit.top)).round().clamp(
      1,
      image.height,
    ),
  );
  if (edit.quarterTurns % 4 != 0) {
    image = img.copyRotate(image, angle: 90 * (edit.quarterTurns % 4));
  }
  if (edit.flip) image = img.flipHorizontal(image);
  image = _applyFilter(image, edit.filter);
  image = img.adjustColor(
    image,
    brightness: edit.brightness,
    contrast: edit.contrast,
    saturation: edit.saturation,
  );
  if (edit.warmth != 0) {
    for (final pixel in image) {
      pixel.r = (pixel.r + edit.warmth * 24).clamp(0, 255);
      pixel.b = (pixel.b - edit.warmth * 24).clamp(0, 255);
    }
  }
  _drawStrokes(image, edit.strokes);
  if (edit.text.trim().isNotEmpty) {
    img.drawString(
      image,
      edit.text.trim(),
      font: image.width >= 1200 ? img.arial48 : img.arial24,
      x: 12,
      y: 12,
      color: img.ColorRgb8(255, 255, 255),
    );
  }
  // Export rendered pixels; do not silently copy original GPS into a new PNG.
  image.exif = img.ExifData();
  return img.encodePng(image);
}

img.Image _decode(Uint8List bytes) {
  final decoder = img.findDecoderForData(bytes);
  final info = decoder?.startDecode(bytes);
  if (info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width * info.height > 32000000) {
    throw const FormatException(
      'This image format or size cannot be edited here.',
    );
  }
  final image = decoder!.decodeFrame(0);
  if (image == null) {
    throw const FormatException('The image could not be decoded.');
  }
  return img.bakeOrientation(image);
}

/// Rotates, then crops the largest centered rectangle without empty corners.
img.Image _straighten(img.Image image, double degrees) {
  final radians = degrees.abs() * math.pi / 180;
  final w = image.width.toDouble(), h = image.height.toDouble();
  final rotated = img.copyRotate(
    image,
    angle: degrees,
    interpolation: img.Interpolation.linear,
  );
  final cos = math.cos(radians), sin = math.sin(radians);
  // Largest axis-aligned rectangle of the original aspect inside the rotation.
  final scale = math.min(w / (w * cos + h * sin), h / (w * sin + h * cos));
  final cropW = (w * scale).floor().clamp(1, rotated.width);
  final cropH = (h * scale).floor().clamp(1, rotated.height);
  return img.copyCrop(
    rotated,
    x: ((rotated.width - cropW) / 2).floor(),
    y: ((rotated.height - cropH) / 2).floor(),
    width: cropW,
    height: cropH,
  );
}

img.Image _applyFilter(img.Image image, ImageFilter filter) {
  switch (filter) {
    case ImageFilter.none:
      return image;
    case ImageFilter.vivid:
      return img.adjustColor(image, saturation: 1.35, contrast: 1.12);
    case ImageFilter.warm:
      for (final pixel in image) {
        pixel.r = (pixel.r * 1.08 + 10).clamp(0, 255);
        pixel.b = (pixel.b * 0.9).clamp(0, 255);
      }
      return image;
    case ImageFilter.cool:
      for (final pixel in image) {
        pixel.r = (pixel.r * 0.92).clamp(0, 255);
        pixel.b = (pixel.b * 1.08 + 10).clamp(0, 255);
      }
      return image;
    case ImageFilter.mono:
      return img.grayscale(image);
    case ImageFilter.sepia:
      return img.sepia(image);
    case ImageFilter.fade:
      for (final pixel in image) {
        pixel.r = (pixel.r * 0.85 + 30).clamp(0, 255);
        pixel.g = (pixel.g * 0.85 + 30).clamp(0, 255);
        pixel.b = (pixel.b * 0.85 + 30).clamp(0, 255);
      }
      return img.adjustColor(image, saturation: 0.8);
  }
}

void _drawStrokes(img.Image image, List<MarkupStroke> strokes) {
  final longest = math.max(image.width, image.height);
  for (final stroke in strokes) {
    final color = img.ColorRgba8(
      (stroke.color >> 16) & 0xff,
      (stroke.color >> 8) & 0xff,
      stroke.color & 0xff,
      (stroke.color >> 24) & 0xff,
    );
    final thickness = (stroke.width * longest).clamp(1, 64).toDouble();
    final points = [
      for (final (x, y) in stroke.points)
        (
          (x.clamp(0, 1) * (image.width - 1)).round(),
          (y.clamp(0, 1) * (image.height - 1)).round(),
        ),
    ];
    if (points.length == 1) {
      img.fillCircle(
        image,
        x: points.first.$1,
        y: points.first.$2,
        radius: (thickness / 2).ceil(),
        color: color,
      );
    }
    for (var i = 1; i < points.length; i++) {
      img.drawLine(
        image,
        x1: points[i - 1].$1,
        y1: points[i - 1].$2,
        x2: points[i].$1,
        y2: points[i].$2,
        color: color,
        thickness: thickness,
        antialias: true,
      );
    }
  }
}

/// Square-cell grid collage. Each photo is center-cropped to fill its cell.
Uint8List buildCollage(
  List<Uint8List> photos, {
  int width = 2048,
  int gap = 12,
  bool dark = false,
}) {
  if (photos.length < 2 || photos.length > 9) {
    throw const FormatException('Choose 2 to 9 photos for a collage.');
  }
  final columns = photos.length <= 2
      ? 2
      : photos.length <= 4
      ? 2
      : 3;
  final rows = (photos.length / columns).ceil();
  final cell = ((width - gap * (columns + 1)) / columns).floor();
  final canvas = img.Image(
    width: width,
    height: rows * cell + gap * (rows + 1),
  );
  img.fill(
    canvas,
    color: dark ? img.ColorRgb8(18, 18, 18) : img.ColorRgb8(250, 250, 250),
  );
  for (var index = 0; index < photos.length; index++) {
    final photo = _decode(photos[index]);
    final side = math.min(photo.width, photo.height);
    final square = img.copyResize(
      img.copyCrop(
        photo,
        x: (photo.width - side) ~/ 2,
        y: (photo.height - side) ~/ 2,
        width: side,
        height: side,
      ),
      width: cell,
      height: cell,
      interpolation: img.Interpolation.average,
    );
    // Center a short last row.
    final row = index ~/ columns;
    final inRow = row == rows - 1 ? photos.length - row * columns : columns;
    final offset = (width - inRow * cell - (inRow - 1) * gap) ~/ 2;
    img.compositeImage(
      canvas,
      square,
      dstX: offset + (index % columns) * (cell + gap),
      dstY: gap + row * (cell + gap),
    );
  }
  return img.encodePng(canvas);
}
