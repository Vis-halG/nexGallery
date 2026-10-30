import 'dart:convert';
import 'dart:io';

import 'package:nex_gallery/services/remote/video_proxy.dart';

/// Real codec validation, separate from the deterministic fake-transcoder tests.
/// NEXGALLERY_FFMPEG / NEXGALLERY_FFPROBE can point to portable executables.
Future<void> main() async {
  final transcoder = await FfmpegTranscoder.find();
  if (transcoder == null) {
    throw StateError('Install FFmpeg or set NEXGALLERY_FFMPEG.');
  }
  final probe =
      Platform.environment['NEXGALLERY_FFPROBE'] ??
      (transcoder.executable.contains(Platform.pathSeparator)
          ? '${File(transcoder.executable).parent.path}${Platform.pathSeparator}ffprobe${Platform.isWindows ? '.exe' : ''}'
          : 'ffprobe');
  final directory = await Directory.systemTemp.createTemp('nex_real_codec_');
  try {
    final source = File('${directory.path}/source.mp4');
    final seed = await Process.run(transcoder.executable, [
      '-hide_banner',
      '-nostdin',
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=640x480:rate=12',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '2',
      '-c:v',
      'mpeg4',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      source.path,
    ]);
    if (seed.exitCode != 0) {
      throw StateError('Cannot generate codec fixture: ${seed.stderr}');
    }
    final target = File('${directory.path}/proxy.mp4');
    await transcoder.transcode(source, target, 360, (_) {});
    final inspected = await Process.run(probe, [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      target.path,
    ]);
    if (inspected.exitCode != 0) {
      throw StateError('ffprobe failed: ${inspected.stderr}');
    }
    final metadata = jsonDecode('${inspected.stdout}') as Map;
    final streams = metadata['streams'] as List;
    final video = streams.firstWhere((v) => v['codec_type'] == 'video') as Map;
    final audio = streams.firstWhere((v) => v['codec_type'] == 'audio') as Map;
    final duration = double.parse(metadata['format']['duration'] as String);
    if (video['height'] != 360 ||
        video['width'] != 480 ||
        !['h264', 'mpeg4'].contains(video['codec_name']) ||
        audio['codec_name'] != 'aac' ||
        audio['channels'] != 2 ||
        duration < 1.8 ||
        duration > 2.3 ||
        await target.length() == 0) {
      throw StateError(
        'Proxy format, size, audio or duration is incorrect: $metadata',
      );
    }
    final decode = await Process.run(transcoder.executable, [
      '-v',
      'error',
      '-nostdin',
      '-i',
      target.path,
      '-f',
      'null',
      '-',
    ]);
    if (decode.exitCode != 0) {
      throw StateError('Proxy could not be decoded: ${decode.stderr}');
    }
    stdout.writeln(
      'PASS: real ${transcoder.description} transcode, 480x360 MP4, stereo AAC, duration and full decode.',
    );
  } finally {
    await directory.delete(recursive: true);
  }
}
