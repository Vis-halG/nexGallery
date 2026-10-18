import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'model_pack.dart';

/// PaddleOCR v3 English detector and recognizer (Apache-2.0), converted to
/// ONNX by RapidOCR. About 11 MB together.
const textDetectorModel = ModelFile(
  'en_PP-OCRv3_det_infer.onnx',
  'https://huggingface.co/SWHL/RapidOCR/resolve/main/PP-OCRv4/en_PP-OCRv3_det_infer.onnx',
  'f139598bc2af4e4b6fe98dec11574e30edfdd91fc94ac1425c18ace3bd5a866b',
  2423224,
);
const textRecognizerModel = ModelFile(
  'en_PP-OCRv3_rec_infer.onnx',
  'https://huggingface.co/SWHL/RapidOCR/resolve/main/PP-OCRv3/en_PP-OCRv3_rec_infer.onnx',
  'ef7abd8bd3629ae57ea2c28b425c1bd258a871b93fd2fe7c433946ade9b5d9ea',
  8967018,
);

/// PaddleOCR `en_dict.txt` followed by the appended space class. Class 0 of
/// the recognizer output is the CTC blank.
const ocrCharacters =
    '0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`'
    'abcdefghijklmnopqrstuvwxyz{|}~!"#\$%&\'()*+,-./  ';

final class TextBox {
  const TextBox(this.left, this.top, this.right, this.bottom, this.score);
  final int left, top, right, bottom;
  final double score;
  int get width => right - left;
  int get height => bottom - top;
}

final class PreparedPage {
  const PreparedPage(
    this.input,
    this.inputWidth,
    this.inputHeight,
    this.rgb,
    this.width,
    this.height,
  );
  final Float32List input;
  final int inputWidth, inputHeight;

  /// The resized photo as RGB bytes, used for text-line crops.
  final Uint8List rgb;
  final int width, height;
}

/// Finds and reads printed text in photos (signs, receipts, documents)
/// so they can be found by search. Runs entirely on this device.
final class TextEngine {
  TextEngine(Directory directory)
    : pack = ModelPack(directory, const [
        textDetectorModel,
        textRecognizerModel,
      ]);

  final ModelPack pack;
  OrtSession? _detector, _recognizer;

  Future<void> open() async {
    if (_detector != null) return;
    await pack.verify();
    final runtime = OnnxRuntime();
    _detector = await runtime.createSession(pack.file(textDetectorModel).path);
    try {
      _recognizer = await runtime.createSession(
        pack.file(textRecognizerModel).path,
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Recognized lines, top to bottom.
  Future<List<String>> analyze(Uint8List bytes) async {
    await open();
    final page = await _pageInBackground(bytes);
    final map = await runOnnx(_detector!, page.input, [
      1,
      3,
      page.inputHeight,
      page.inputWidth,
    ]);
    final probabilities = map.values.first.values;
    final boxes = await _boxesInBackground(probabilities, page);
    if (boxes.isEmpty) return const [];
    final crops = await _cropsInBackground(page, boxes);
    final lines = <(TextBox, String)>[];
    for (var i = 0; i < boxes.length; i++) {
      final (data, width) = crops[i];
      final output = await runOnnx(_recognizer!, data, [1, 3, 48, width]);
      final tensor = output.values.first;
      final classes = tensor.shape.last;
      final steps = tensor.values.length ~/ classes;
      final (text, confidence) = ctcDecode(tensor.values, steps, classes);
      if (confidence >= 0.5 &&
          RegExp(r'[A-Za-z0-9].*[A-Za-z0-9]').hasMatch(text)) {
        lines.add((boxes[i], text));
      }
    }
    return joinLines(lines);
  }

  Future<void> close() async {
    await _detector?.close();
    await _recognizer?.close();
    _detector = null;
    _recognizer = null;
  }
}

/// Limits the longer side to [maxSide], pads to multiples of 32 and applies
/// the detector's BGR ImageNet normalization.
PreparedPage prepareTextPage(Uint8List bytes, {int maxSide = 960}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('This photo cannot be analyzed.');
  }
  var image = img.bakeOrientation(decoded);
  final longest = math.max(image.width, image.height);
  if (longest > maxSide) {
    final scale = maxSide / longest;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.linear,
    );
  }
  final width = image.width, height = image.height;
  final inputWidth = math.max(32, ((width + 31) ~/ 32) * 32);
  final inputHeight = math.max(32, ((height + 31) ~/ 32) * 32);
  final plane = inputWidth * inputHeight;
  final data = Float32List(3 * plane);
  final rgb = Uint8List(width * height * 3);
  const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final pixel = image.getPixel(x, y);
      final r = pixel.r.toInt(), g = pixel.g.toInt(), b = pixel.b.toInt();
      final offset = (y * width + x) * 3;
      rgb[offset] = r;
      rgb[offset + 1] = g;
      rgb[offset + 2] = b;
      final index = y * inputWidth + x;
      data[index] = (b / 255 - mean[0]) / std[0];
      data[plane + index] = (g / 255 - mean[1]) / std[1];
      data[2 * plane + index] = (r / 255 - mean[2]) / std[2];
    }
  }
  return PreparedPage(data, inputWidth, inputHeight, rgb, width, height);
}

/// DB post-processing with axis-aligned boxes: threshold, 8-connected
/// components, mean-score filter and the standard 1.6 unclip expansion.
List<TextBox> detectTextBoxes(
  Float32List probabilities,
  int width,
  int height, {
  int? validWidth,
  int? validHeight,
  double threshold = 0.3,
  double boxThreshold = 0.6,
  double unclipRatio = 1.6,
  int minSize = 3,
  int maxBoxes = 80,
}) {
  if (probabilities.length != width * height) {
    throw const FormatException('Unexpected text detector output.');
  }
  final maxX = (validWidth ?? width) - 1, maxY = (validHeight ?? height) - 1;
  final visited = Uint8List(width * height);
  final queue = Int32List(width * height);
  final boxes = <TextBox>[];
  for (var start = 0; start < probabilities.length; start++) {
    if (visited[start] != 0 || probabilities[start] <= threshold) continue;
    var head = 0, tail = 0;
    queue[tail++] = start;
    visited[start] = 1;
    var left = width, right = 0, top = height, bottom = 0;
    var sum = 0.0;
    while (head < tail) {
      final index = queue[head++];
      final x = index % width, y = index ~/ width;
      sum += probabilities[index];
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
      for (var dy = -1; dy <= 1; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= height) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx;
          if (nx < 0 || nx >= width) continue;
          final next = ny * width + nx;
          if (visited[next] == 0 && probabilities[next] > threshold) {
            visited[next] = 1;
            queue[tail++] = next;
          }
        }
      }
    }
    final w = right - left + 1, h = bottom - top + 1;
    if (math.min(w, h) < minSize || sum / tail < boxThreshold) continue;
    final distance = w * h * unclipRatio / (2 * (w + h));
    final box = TextBox(
      (left - distance).floor().clamp(0, maxX),
      (top - distance).floor().clamp(0, maxY),
      (right + 1 + distance).ceil().clamp(0, maxX + 1),
      (bottom + 1 + distance).ceil().clamp(0, maxY + 1),
      sum / tail,
    );
    if (box.width >= minSize && box.height >= minSize) boxes.add(box);
  }
  boxes.sort((a, b) {
    final line = (a.top - b.top).abs() < math.min(a.height, b.height) / 2;
    return line ? a.left.compareTo(b.left) : a.top.compareTo(b.top);
  });
  return boxes.take(maxBoxes).toList();
}

/// Crops a text line to height 48 with BGR (x/255 - 0.5) / 0.5 values and
/// zero padding on the right. Returns the tensor and its width.
(Float32List, int) recognizerInput(
  Uint8List rgb,
  int width,
  int height,
  TextBox box, {
  int maxWidth = 1600,
}) {
  final source = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    bytesOffset: rgb.offsetInBytes,
    numChannels: 3,
  );
  var crop = img.copyCrop(
    source,
    x: box.left,
    y: box.top,
    width: math.max(1, box.width),
    height: math.max(1, box.height),
  );
  if (crop.height >= crop.width * 1.5) crop = img.copyRotate(crop, angle: 90);
  final resizedWidth = math.min(
    maxWidth,
    math.max(1, (48 * crop.width / crop.height).ceil()),
  );
  final inputWidth = ((math.max(320, resizedWidth) + 7) ~/ 8) * 8;
  final resized = img.copyResize(
    crop,
    width: resizedWidth,
    height: 48,
    interpolation: img.Interpolation.linear,
  );
  final plane = 48 * inputWidth;
  final data = Float32List(3 * plane);
  for (var y = 0; y < 48; y++) {
    for (var x = 0; x < resizedWidth; x++) {
      final pixel = resized.getPixel(x, y);
      final index = y * inputWidth + x;
      data[index] = pixel.b / 127.5 - 1;
      data[plane + index] = pixel.g / 127.5 - 1;
      data[2 * plane + index] = pixel.r / 127.5 - 1;
    }
  }
  return (data, inputWidth);
}

/// Greedy CTC decoding. Returns the text and its mean character confidence.
(String, double) ctcDecode(List<double> values, int steps, int classes) {
  if (values.length != steps * classes) {
    throw const FormatException('Unexpected text recognizer output.');
  }
  final text = StringBuffer();
  var previous = -1;
  var confidence = 0.0, count = 0;
  for (var t = 0; t < steps; t++) {
    var best = 0;
    var bestValue = values[t * classes];
    for (var c = 1; c < classes; c++) {
      final value = values[t * classes + c];
      if (value > bestValue) {
        bestValue = value;
        best = c;
      }
    }
    if (best != 0 && best != previous && best - 1 < ocrCharacters.length) {
      text.write(ocrCharacters[best - 1]);
      confidence += bestValue;
      count++;
    }
    previous = best;
  }
  return (text.toString().trim(), count == 0 ? 0 : confidence / count);
}

/// Joins boxes on the same line with spaces and lines with newlines.
List<String> joinLines(List<(TextBox, String)> boxes) {
  final lines = <List<(TextBox, String)>>[];
  for (final entry in boxes) {
    final line = lines.isEmpty ? null : lines.last;
    final previous = line?.last.$1;
    if (line != null &&
        previous != null &&
        (entry.$1.top - previous.top).abs() <
            math.min(entry.$1.height, previous.height) / 2) {
      line.add(entry);
    } else {
      lines.add([entry]);
    }
  }
  return [
    for (final line in lines)
      (line..sort((a, b) => a.$1.left.compareTo(b.$1.left)))
          .map((entry) => entry.$2)
          .join(' '),
  ];
}

// Top-level isolate entry points never capture the engine or its sessions.
Future<PreparedPage> _pageInBackground(Uint8List bytes) =>
    Isolate.run(() => prepareTextPage(bytes));

Future<List<TextBox>> _boxesInBackground(
  Float32List probabilities,
  PreparedPage page,
) {
  final width = page.inputWidth, height = page.inputHeight;
  final validWidth = page.width, validHeight = page.height;
  return Isolate.run(
    () => detectTextBoxes(
      probabilities,
      width,
      height,
      validWidth: validWidth,
      validHeight: validHeight,
    ),
  );
}

Future<List<(Float32List, int)>> _cropsInBackground(
  PreparedPage page,
  List<TextBox> boxes,
) {
  final rgb = page.rgb, width = page.width, height = page.height;
  return Isolate.run(
    () => [for (final box in boxes) recognizerInput(rgb, width, height, box)],
  );
}
