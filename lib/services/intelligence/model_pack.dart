import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../remote/sha256.dart';

final class ModelFile {
  const ModelFile(this.name, this.url, this.sha256, this.bytes);
  final String name;
  final String url;
  final String sha256;
  final int bytes;
}

/// An optional, pinned set of model files. Downloads are size-capped and
/// verified by SHA-256 before use; photos are never uploaded.
final class ModelPack {
  const ModelPack(this.directory, this.files);
  final Directory directory;
  final List<ModelFile> files;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.bytes);

  File file(ModelFile model) => File('${directory.path}/${model.name}');

  Future<bool> installed() async {
    for (final model in files) {
      final value = file(model);
      if (!await value.exists() || await value.length() != model.bytes) {
        return false;
      }
    }
    return true;
  }

  Future<void> verify() async {
    for (final model in files) {
      if (await Sha256.fileHex(file(model)) != model.sha256) {
        throw const FormatException(
          'A model file is damaged. Install it again.',
        );
      }
    }
  }

  Future<void> install(
    void Function(int done, int total) progress, {
    bool Function()? shouldStop,
  }) async {
    await directory.create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    var received = 0;
    try {
      for (final model in files) {
        final target = file(model);
        if (await target.exists() &&
            await target.length() == model.bytes &&
            await Sha256.fileHex(target) == model.sha256) {
          received += model.bytes;
          progress(received, totalBytes);
          continue;
        }
        final part = File('${target.path}.part');
        final response = await (await client.getUrl(Uri.parse(model.url)))
            .close()
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          throw HttpException(
            'The model download failed (${response.statusCode}).',
          );
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
            if (modelBytes > model.bytes) {
              throw const FormatException('Model exceeds its expected size.');
            }
            sink.add(chunk);
            received += chunk.length;
            progress(received, totalBytes);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (modelBytes != model.bytes ||
            await Sha256.fileHex(part) != model.sha256) {
          await part.delete();
          throw const FormatException('Model integrity verification failed.');
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<void> remove() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

final class Tensor {
  const Tensor(this.shape, this.values);
  final List<int> shape;
  final Float32List values;
}

/// Runs one float input and returns every output as a flat float tensor.
Future<Map<String, Tensor>> runOnnx(
  OrtSession session,
  Float32List data,
  List<int> shape,
) async {
  final input = await OrtValue.fromList(data, shape);
  final outputs = <String, OrtValue>{};
  try {
    outputs.addAll(await session.run({session.inputNames.first: input}));
    return {
      for (final entry in outputs.entries)
        entry.key: Tensor(
          entry.value.shape,
          Float32List.fromList([
            for (final value in await entry.value.asFlattenedList())
              (value as num).toDouble(),
          ]),
        ),
    };
  } finally {
    await input.dispose();
    for (final value in outputs.values) {
      await value.dispose();
    }
  }
}
