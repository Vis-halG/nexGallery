import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import '../remote/sha256.dart';

const faceModels = <(String, String, int)>[
  (
    'face_detection_yunet_2023mar.onnx',
    '8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4',
    232589,
  ),
  (
    'face_recognition_sface_2021dec.onnx',
    '0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79',
    38696353,
  ),
];

final class FaceEmbedding {
  const FaceEmbedding(this.bounds, this.vector);
  final List<double> bounds;
  final List<double> vector;
}

/// YuNet detection, five-point alignment and SFace identity embeddings.
/// Models are optional; inference never sends photo bytes off the device.
final class FaceEngine {
  FaceEngine(this.directory);
  final Directory directory;
  OrtSession? _detector, _recognizer;

  Future<bool> installed() async {
    for (final model in faceModels) {
      final file = File('${directory.path}/${model.$1}');
      if (!await file.exists() || await file.length() != model.$3) return false;
    }
    return true;
  }

  Future<void> install(
    void Function(int, int) progress, {
    bool Function()? shouldStop,
  }) async {
    await directory.create(recursive: true);
    final client = HttpClient();
    var received = 0;
    final total = faceModels.fold<int>(0, (a, v) => a + v.$3);
    try {
      for (final model in faceModels) {
        final group = model.$1.startsWith('face_detection')
            ? 'face_detection_yunet'
            : 'face_recognition_sface';
        final file = File('${directory.path}/${model.$1}');
        final part = File('${file.path}.part');
        final request = await client.getUrl(
          Uri.parse(
            'https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/$group/${model.$1}',
          ),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if (response.statusCode != 200) {
          throw const HttpException('The model download failed.');
        }
        final sink = part.openWrite();
        var modelBytes = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 30),
          )) {
            if (shouldStop?.call() == true) {
              throw StateError('Model download stopped.');
            }
            modelBytes += chunk.length;
            if (modelBytes > model.$3) {
              throw const FormatException('Model exceeds its expected size.');
            }
            sink.add(chunk);
            received += chunk.length;
            progress(received, total);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (modelBytes != model.$3 || await Sha256.fileHex(part) != model.$2) {
          await part.delete();
          throw const FormatException('Model integrity verification failed.');
        }
        if (await file.exists()) await file.delete();
        await part.rename(file.path);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> open() async {
    if (_detector != null) return;
    for (final model in faceModels) {
      if (await Sha256.fileHex(File('${directory.path}/${model.$1}')) !=
          model.$2) {
        throw const FormatException(
          'The face pack is damaged. Install it again.',
        );
      }
    }
    final runtime = OnnxRuntime();
    _detector = await runtime.createSession(
      '${directory.path}/${faceModels[0].$1}',
    );
    try {
      _recognizer = await runtime.createSession(
        '${directory.path}/${faceModels[1].$1}',
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<List<FaceEmbedding>> analyze(Uint8List bytes) async {
    await open();
    final prepared = await Isolate.run(() => prepareFaceImage(bytes));
    final output = await _run(_detector!, prepared.$2, [1, 3, 640, 640]);
    final faces = decodeFaceDetections(output);
    final result = <FaceEmbedding>[];
    for (final face in faces) {
      final tensor = await Isolate.run(
        () => alignedFaceTensor(prepared.$1, face),
      );
      final embedding = await _run(_recognizer!, tensor, [1, 3, 112, 112]);
      final vector = embedding.values.first;
      final norm = math.sqrt(vector.fold<double>(0, (a, v) => a + v * v));
      if (norm <= 0 || !norm.isFinite) continue;
      result.add(
        FaceEmbedding([
          (face[0] / prepared.$3.$1).clamp(0, 1),
          (face[1] / prepared.$3.$2).clamp(0, 1),
          (face[2] / prepared.$3.$1).clamp(0, 1),
          (face[3] / prepared.$3.$2).clamp(0, 1),
        ], vector.map((v) => v / norm).toList()),
      );
    }
    return result;
  }

  Future<Map<String, List<double>>> _run(
    OrtSession session,
    Float32List data,
    List<int> shape,
  ) async {
    final input = await OrtValue.fromList(data, shape);
    final outputs = <String, OrtValue>{};
    try {
      outputs.addAll(await session.run({session.inputNames.first: input}));
      final result = <String, List<double>>{};
      for (final e in outputs.entries) {
        final values = <double>[];
        void flatten(Object? v) {
          if (v is num) {
            values.add(v.toDouble());
          } else if (v is List) {
            for (final n in v) {
              flatten(n);
            }
          }
        }

        flatten(await e.value.asList());
        result[e.key] = values;
      }
      return result;
    } finally {
      await input.dispose();
      for (final value in outputs.values) {
        await value.dispose();
      }
    }
  }

  Future<void> close() async {
    await _detector?.close();
    await _recognizer?.close();
    _detector = null;
    _recognizer = null;
  }
}

(Uint8List, Float32List, (int, int)) prepareFaceImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('This photo cannot be analyzed.');
  }
  final oriented = img.bakeOrientation(decoded);
  final scale = 640 / math.max(oriented.width, oriented.height);
  final resized = img.copyResize(
    oriented,
    width: (oriented.width * scale).round().clamp(1, 640),
    height: (oriented.height * scale).round().clamp(1, 640),
    interpolation: img.Interpolation.linear,
  );
  final image = img.Image(width: 640, height: 640);
  for (final pixel in resized) {
    image.setPixel(pixel.x, pixel.y, pixel);
  }
  final data = Float32List(3 * 640 * 640);
  for (final pixel in image) {
    final index = pixel.y * 640 + pixel.x;
    data[index] = pixel.b.toDouble();
    data[640 * 640 + index] = pixel.g.toDouble();
    data[2 * 640 * 640 + index] = pixel.r.toDouble();
  }
  return (img.encodePng(image), data, (resized.width, resized.height));
}

List<List<double>> decodeFaceDetections(Map<String, List<double>> output) {
  final candidates = <List<double>>[];
  for (final stride in [8, 16, 32]) {
    final cls = output['cls_$stride'],
        obj = output['obj_$stride'],
        box = output['bbox_$stride'],
        kps = output['kps_$stride'];
    final columns = 640 ~/ stride;
    if (cls == null ||
        obj == null ||
        box == null ||
        kps == null ||
        cls.length != columns * columns ||
        obj.length != cls.length ||
        box.length != cls.length * 4 ||
        kps.length != cls.length * 10) {
      throw const FormatException('Unexpected YuNet model outputs.');
    }
    for (var i = 0; i < cls.length; i++) {
      final score = math.sqrt(cls[i].clamp(0, 1) * obj[i].clamp(0, 1));
      if (!score.isFinite || score < 0.9) continue;
      final x = i % columns, y = i ~/ columns;
      final w = math.exp(box[i * 4 + 2]) * stride,
          h = math.exp(box[i * 4 + 3]) * stride;
      if (w < 16 || h < 16 || !w.isFinite || !h.isFinite) continue;
      candidates.add([
        (x + box[i * 4]) * stride - w / 2,
        (y + box[i * 4 + 1]) * stride - h / 2,
        w,
        h,
        for (var n = 0; n < 5; n++) ...[
          (kps[i * 10 + n * 2] + x) * stride,
          (kps[i * 10 + n * 2 + 1] + y) * stride,
        ],
        score,
      ]);
    }
  }
  candidates.sort((a, b) => b[14].compareTo(a[14]));
  final result = <List<double>>[];
  for (final box in candidates.take(5000)) {
    final overlap = result.any((other) {
      final w = math.max(
        0,
        math.min(box[0] + box[2], other[0] + other[2]) -
            math.max(box[0], other[0]),
      );
      final h = math.max(
        0,
        math.min(box[1] + box[3], other[1] + other[3]) -
            math.max(box[1], other[1]),
      );
      final intersection = w * h;
      return intersection /
              (box[2] * box[3] + other[2] * other[3] - intersection) >
          0.3;
    });
    if (!overlap) result.add(box);
    if (result.length >= 50) break;
  }
  return result;
}

Float32List alignedFaceTensor(Uint8List bytes, List<double> face) {
  final image = img.decodePng(bytes)!;
  const target = [
    (38.2946, 51.6963),
    (73.5318, 51.5014),
    (56.0252, 71.7366),
    (41.5493, 92.3655),
    (70.7299, 92.2041),
  ];
  double sx = 0, sy = 0, dx = 0, dy = 0;
  for (var i = 0; i < 5; i++) {
    sx += face[4 + i * 2] / 5;
    sy += face[5 + i * 2] / 5;
    dx += target[i].$1 / 5;
    dy += target[i].$2 / 5;
  }
  double numeratorA = 0, numeratorB = 0, denominator = 0;
  for (var i = 0; i < 5; i++) {
    final x = face[4 + i * 2] - sx,
        y = face[5 + i * 2] - sy,
        u = target[i].$1 - dx,
        v = target[i].$2 - dy;
    numeratorA += x * u + y * v;
    numeratorB += x * v - y * u;
    denominator += x * x + y * y;
  }
  if (denominator <= 1e-8) {
    throw const FormatException('Face landmarks are degenerate.');
  }
  final a = numeratorA / denominator, b = numeratorB / denominator;
  final tx = dx - a * sx + b * sy,
      ty = dy - b * sx - a * sy,
      det = a * a + b * b;
  if (det <= 1e-8) throw const FormatException('Face alignment failed.');
  final data = Float32List(3 * 112 * 112);
  for (var y = 0; y < 112; y++) {
    for (var x = 0; x < 112; x++) {
      final sourceX = (a * (x - tx) + b * (y - ty)) / det,
          sourceY = (-b * (x - tx) + a * (y - ty)) / det;
      if (sourceX < 0 ||
          sourceY < 0 ||
          sourceX >= image.width - 1 ||
          sourceY >= image.height - 1) {
        continue;
      }
      final pixel = image.getPixelInterpolate(
            sourceX,
            sourceY,
            interpolation: img.Interpolation.linear,
          ),
          index = y * 112 + x;
      data[index] = pixel.r.toDouble();
      data[112 * 112 + index] = pixel.g.toDouble();
      data[2 * 112 * 112 + index] = pixel.b.toDouble();
    }
  }
  return data;
}

double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return -1;
  double dot = 0, aa = 0, bb = 0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  return aa > 0 && bb > 0 ? dot / math.sqrt(aa * bb) : -1;
}
