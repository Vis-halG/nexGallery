import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'model_pack.dart';

/// MobileNetV2 (ONNX Model Zoo, Apache-2.0), 14 MB.
const labelModel = ModelFile(
  'mobilenetv2-12.onnx',
  'https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-12.onnx',
  'c0c3f76d93fa3fd6580652a45618618a220fced18babf65774ed169de0432ad5',
  13964571,
);

/// Recognizes objects and scenes so photos can be searched by "dog", "beach"
/// or "food". Runs entirely on this device.
final class LabelEngine {
  LabelEngine(Directory directory)
    : pack = ModelPack(directory, const [labelModel]);

  final ModelPack pack;
  OrtSession? _session;
  List<String>? _names;

  Future<void> open() async {
    if (_session != null) return;
    await pack.verify();
    _names ??= (await rootBundle.loadString(
      'assets/models/imagenet_labels.txt',
    )).split('\n').map((line) => line.trim()).toList();
    _session = await OnnxRuntime().createSession(pack.file(labelModel).path);
  }

  Future<List<String>> analyze(Uint8List bytes) async {
    await open();
    final input = await _classifierInputInBackground(bytes);
    final output = await runOnnx(_session!, input, const [1, 3, 224, 224]);
    return labelsFor(output.values.first.values, _names!);
  }

  Future<void> close() async {
    await _session?.close();
    _session = null;
  }
}

/// Resize to 256 on the short side, center-crop 224, ImageNet normalization.
Float32List classifierInput(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('This photo cannot be analyzed.');
  }
  final oriented = img.bakeOrientation(decoded);
  final scale = 256 / math.min(oriented.width, oriented.height);
  final resized = img.copyResize(
    oriented,
    width: math.max(224, (oriented.width * scale).round()),
    height: math.max(224, (oriented.height * scale).round()),
    interpolation: img.Interpolation.linear,
  );
  final left = (resized.width - 224) ~/ 2, top = (resized.height - 224) ~/ 2;
  const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
  final data = Float32List(3 * 224 * 224);
  for (var y = 0; y < 224; y++) {
    for (var x = 0; x < 224; x++) {
      final pixel = resized.getPixel(left + x, top + y);
      final index = y * 224 + x;
      data[index] = (pixel.r / 255 - mean[0]) / std[0];
      data[224 * 224 + index] = (pixel.g / 255 - mean[1]) / std[1];
      data[2 * 224 * 224 + index] = (pixel.b / 255 - mean[2]) / std[2];
    }
  }
  return data;
}

/// Confident ImageNet classes plus the broad gallery category of each.
List<String> labelsFor(
  List<double> logits,
  List<String> names, {
  double minimum = 0.2,
}) {
  if (logits.length != 1000) {
    throw const FormatException('Unexpected classifier output.');
  }
  final highest = logits.reduce(math.max);
  final exp = [for (final value in logits) math.exp(value - highest)];
  final sum = exp.fold<double>(0, (a, b) => a + b);
  final ranked = List<int>.generate(1000, (i) => i)
    ..sort((a, b) => exp[b].compareTo(exp[a]));
  final labels = <String>{};
  var covered = 0.0;
  for (final index in ranked.take(5)) {
    final probability = exp[index] / sum;
    if (probability < minimum && covered > 0) break;
    covered += probability;
    final category = imagenetCategory(index);
    if (probability < minimum) {
      // A spread-out top-5 often still agrees on the broad category.
      if (category != null &&
          _categorySupport(ranked.take(5), exp, sum, category) >= 0.4) {
        labels.add(category);
      }
      break;
    }
    if (category != null) labels.add(category);
    if (index < names.length) labels.add(names[index].toLowerCase());
  }
  return labels.toList();
}

double _categorySupport(
  Iterable<int> indices,
  List<double> exp,
  double sum,
  String category,
) => indices
    .where((index) => imagenetCategory(index) == category)
    .fold(0.0, (total, index) => total + exp[index] / sum);

/// Broad, searchable groups for ImageNet class indices.
String? imagenetCategory(int index) {
  bool any(List<int> values) => values.contains(index);
  bool range(int first, int last) => index >= first && index <= last;
  if (range(0, 6) || range(389, 397)) return 'fish';
  if (range(7, 24) || range(80, 100) || range(127, 146)) return 'bird';
  if (range(33, 68)) return 'reptile';
  if (range(151, 268)) return 'dog';
  if (range(281, 285)) return 'cat';
  if (range(269, 280) ||
      range(286, 297) ||
      range(340, 344) ||
      any([385, 386, 101])) {
    return 'wild animal';
  }
  if (range(300, 326)) return 'insect';
  if (range(330, 332)) return 'rabbit';
  if (any([339, 603])) return 'horse';
  if (range(345, 347)) return 'cattle';
  if (range(365, 382)) return 'monkey';
  if (any([
    407,
    436,
    468,
    511,
    609,
    627,
    656,
    661,
    675,
    717,
    734,
    751,
    817,
    864,
    867,
    581,
  ])) {
    return 'car';
  }
  if (any([444, 671, 870])) return 'bicycle';
  if (any([665, 670])) return 'motorcycle';
  if (any([403, 404, 895, 908])) return 'airplane';
  if (any([466, 547, 565, 705, 820, 829])) return 'train';
  if (any([472, 484, 510, 554, 576, 625, 628, 724, 780, 814, 833, 871, 914])) {
    return 'boat';
  }
  if (range(924, 969) || any([567, 762, 809, 659])) return 'food';
  if (any([970, 972, 979, 980])) return 'mountain';
  if (any([977, 978, 976])) return 'beach';
  if (any([973, 975, 974])) return 'water';
  if (any([985, 986, 738])) return 'flower';
  if (any([
    449,
    483,
    497,
    498,
    580,
    663,
    668,
    698,
    727,
    832,
    839,
    821,
    888,
    437,
  ])) {
    return 'building';
  }
  if (any([921, 917, 916, 922, 446, 549])) return 'document';
  if (any([782, 664, 527, 620, 851, 590, 487])) return 'screen';
  if (any([768, 805, 852, 430, 890, 722, 795, 802, 574])) return 'sports';
  return null;
}

Future<Float32List> _classifierInputInBackground(Uint8List bytes) =>
    Isolate.run(() => classifierInput(bytes));
