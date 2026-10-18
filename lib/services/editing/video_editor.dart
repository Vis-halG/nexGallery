import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'mp4_rotation.dart';

final class VideoEditor {
  Process? _process;
  static const _channel = MethodChannel('com.thenex.nex_gallery/media');
  Future<void> export({
    required File input,
    required File output,
    required int startMs,
    required int endMs,
    required int rotation,
    required bool mute,
    required bool compress,
  }) async {
    if (startMs < 0 ||
        endMs <= startMs ||
        ![0, 90, 180, 270].contains(rotation)) {
      throw const FormatException('Invalid video edit.');
    }
    if (await output.exists()) {
      throw const FileSystemException('Export destination already exists.');
    }
    await output.parent.create(recursive: true);
    if (Platform.isAndroid) {
      await _channel.invokeMethod<Object?>('editVideo', {
        'input': input.path,
        'output': output.path,
        'startMs': startMs,
        'endMs': endMs,
        'rotation': rotation,
        'mute': mute,
        'compress': compress,
      });
    } else if (Platform.isWindows) {
      final script = File(p.join(output.parent.path, 'windows_video_edit.ps1'));
      await script.writeAsString(
        await rootBundle.loadString('assets/windows_video_edit.ps1'),
        flush: true,
      );
      final process = await Process.start('powershell.exe', [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-InputPath',
        input.path,
        '-OutputPath',
        output.path,
        '-StartMs',
        '$startMs',
        '-EndMs',
        '$endMs',
        '-Rotation',
        '$rotation',
        '-Mute',
        mute ? '1' : '0',
        '-Compress',
        compress ? '1' : '0',
      ]);
      _process = process;
      final out = process.stdout.drain<void>();
      final errors = process.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final code = await process.exitCode;
      await out;
      final message = await errors;
      _process = null;
      if (code != 0) {
        throw StateError(
          message.trim().isEmpty
              ? 'Windows could not export this video.'
              : message.trim(),
        );
      }
      await rotateMp4(output, rotation);
    } else {
      throw UnsupportedError(
        'Video editing is supported on Android and Windows.',
      );
    }
    if (!await output.exists() || await output.length() == 0) {
      throw StateError('Video export produced no file.');
    }
  }

  Future<void> cancel() async {
    _process?.kill();
    _process = null;
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('cancelVideoEdit');
    }
  }
}
