import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sha256.dart';

/// Heights phones may ask for. Videos are never scaled up.
const videoProxyQualities = <int>[360, 720, 1080];

/// Converts a PC video into a smaller MP4 copy.
abstract interface class VideoTranscoder {
  /// For example "h264_nvenc (hardware)".
  String get description;

  /// Writes [output]; reports progress from 0 to 1.
  Future<void> transcode(
    File source,
    File output,
    int height,
    void Function(double progress) onProgress,
  );
}

/// FFmpeg found on this PC. nexGallery does not ship FFmpeg; the owner
/// installs it (for example `winget install ffmpeg`) to enable proxies.
final class FfmpegTranscoder implements VideoTranscoder {
  FfmpegTranscoder(this.executable);

  final String executable;
  String? _encoder;

  @override
  String get description => _encoder == null
      ? 'FFmpeg'
      : '$_encoder${softwareEncoders.contains(_encoder) ? '' : ' (hardware)'}';

  static const hardwareEncoders = [
    'h264_nvenc',
    'h264_qsv',
    'h264_amf',
    'h264_mf',
  ];
  static const softwareEncoders = ['libx264', 'libopenh264'];

  static Future<FfmpegTranscoder?> find({String? configured}) async {
    final candidates = <String>[
      ?configured,
      ?Platform.environment['NEXGALLERY_FFMPEG'],
      if (Platform.isWindows) ...[
        '${Platform.environment['LOCALAPPDATA']}\\Microsoft\\WinGet\\Links\\ffmpeg.exe',
        r'C:\ProgramData\chocolatey\bin\ffmpeg.exe',
        '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}\\ffmpeg\\bin\\ffmpeg.exe',
      ],
      'ffmpeg',
    ];
    for (final candidate in candidates) {
      if (candidate.contains(Platform.pathSeparator) &&
          !await File(candidate).exists()) {
        continue;
      }
      try {
        final result = await Process.run(candidate, [
          '-hide_banner',
          '-version',
        ]).timeout(const Duration(seconds: 10));
        if (result.exitCode == 0) return FfmpegTranscoder(candidate);
      } on Object {
        continue;
      }
    }
    return null;
  }

  /// The first H.264 encoder that really works on this PC: a GPU encoder
  /// when the drivers allow it, otherwise software.
  Future<String> _chooseEncoder() async {
    if (_encoder case final encoder?) return encoder;
    final listed = await Process.run(executable, ['-hide_banner', '-encoders']);
    final available = '${listed.stdout}';
    for (final encoder in [...hardwareEncoders, ...softwareEncoders]) {
      if (!RegExp('\\s$encoder\\s').hasMatch(available)) continue;
      final probe = await Process.run(executable, [
        '-hide_banner',
        '-nostdin',
        '-f',
        'lavfi',
        '-i',
        'color=c=black:s=320x240:d=0.2',
        '-c:v',
        encoder,
        '-f',
        'null',
        '-',
      ]).timeout(const Duration(seconds: 20));
      if (probe.exitCode == 0) return _encoder = encoder;
    }
    return _encoder = 'mpeg4';
  }

  @override
  Future<void> transcode(
    File source,
    File output,
    int height,
    void Function(double progress) onProgress,
  ) async {
    final encoder = await _chooseEncoder();
    final process = await Process.start(
      executable,
      ffmpegProxyArguments(source.path, output.path, height, encoder),
    );
    Duration? duration;
    final errors = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          duration ??= parseFfmpegDuration(line);
          if (errors.length < 4000) errors.writeln(line);
        });
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          final done = parseFfmpegProgress(line);
          final total = duration;
          if (done != null && total != null && total > Duration.zero) {
            onProgress(
              (done.inMicroseconds / total.inMicroseconds).clamp(0.0, 1.0),
            );
          }
        });
    final code = await process.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    if (code != 0) {
      // A GPU encoder can fail on one file; software is the fallback.
      if (!softwareEncoders.contains(encoder) && encoder != 'mpeg4') {
        _encoder = null;
        final software = await _softwareEncoder();
        if (software != null) {
          _encoder = software;
          return transcode(source, output, height, onProgress);
        }
      }
      throw ProcessException(executable, const [], errors.toString(), code);
    }
  }

  Future<String?> _softwareEncoder() async {
    final listed = await Process.run(executable, ['-hide_banner', '-encoders']);
    for (final encoder in softwareEncoders) {
      if (RegExp('\\s$encoder\\s').hasMatch('${listed.stdout}')) {
        return encoder;
      }
    }
    return null;
  }
}

/// Bitrate caps keep each proxy streamable over a typical upload link.
int proxyBitrate(int height) => switch (height) {
  <= 360 => 800000,
  <= 720 => 2500000,
  _ => 5000000,
};

/// A phone-friendly MP4: H.264 video no taller than [height], stereo AAC
/// audio, and the index at the start so playback can begin immediately.
List<String> ffmpegProxyArguments(
  String input,
  String output,
  int height,
  String encoder,
) {
  final bitrate = proxyBitrate(height);
  return [
    '-hide_banner',
    '-nostdin',
    '-y',
    if (FfmpegTranscoder.hardwareEncoders.contains(encoder)) ...[
      '-hwaccel',
      'auto',
    ],
    '-i',
    input,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-vf',
    'scale=-2:min($height\\,ih)',
    '-c:v',
    encoder,
    // Quality-targeted software encoding, capped at the bitrate below.
    if (encoder == 'libx264') ...[
      '-preset',
      'veryfast',
      '-crf',
      '23',
    ] else ...[
      '-b:v',
      '$bitrate',
    ],
    '-maxrate',
    '$bitrate',
    '-bufsize',
    '${bitrate * 2}',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    '-ac',
    '2',
    '-movflags',
    '+faststart',
    '-f',
    'mp4',
    '-progress',
    'pipe:1',
    '-nostats',
    output,
  ];
}

/// Reads `Duration: 00:01:02.50` from FFmpeg's input summary.
Duration? parseFfmpegDuration(String line) {
  final match = RegExp(r'Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d+)')
      .firstMatch(line);
  if (match == null) return null;
  final fraction = match.group(4)!.padRight(6, '0').substring(0, 6);
  return Duration(
    hours: int.parse(match.group(1)!),
    minutes: int.parse(match.group(2)!),
    seconds: int.parse(match.group(3)!),
    microseconds: int.parse(fraction),
  );
}

/// Reads `out_time_us=...` from `-progress` output.
Duration? parseFfmpegProgress(String line) {
  final match = RegExp(r'^out_time_(?:us|ms)=(\d+)$').firstMatch(line.trim());
  return match == null
      ? null
      : Duration(microseconds: int.parse(match.group(1)!));
}

enum ProxyStatus { queued, preparing, ready, failed }

final class ProxyState {
  const ProxyState(this.status, {this.progress = 0, this.file, this.error});

  final ProxyStatus status;
  final double progress;
  final File? file;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.name,
    'progress': progress,
    'error': ?error,
  };
}

final class _ProxyJob {
  _ProxyJob(this.source, this.output, this.height);
  final File source;
  final File output;
  final int height;
  ProxyStatus status = ProxyStatus.queued;
  double progress = 0;
  String? error;
  DateTime? failedAt;
}

/// Prepares and caches proxies, one transcode at a time. The cache is
/// replaceable: the least recently played copies go first once it passes
/// [maxBytes].
final class VideoProxyCache {
  VideoProxyCache(
    this.directory,
    this.transcoder, {
    this.maxBytes = 4 * 1024 * 1024 * 1024,
    this._keepAwake,
  });

  final Directory directory;
  final VideoTranscoder transcoder;
  final int maxBytes;
  final Future<void> Function(Future<void> Function() work)? _keepAwake;
  final _jobs = <String, _ProxyJob>{};
  Future<void> _queue = Future<void>.value();

  /// [version] changes when the original changes, so stale proxies are
  /// never served.
  Future<ProxyState> request(File source, String version, int height) async {
    final key = sha256Hex(
      utf8.encode('${source.absolute.path}|$version|$height'),
    );
    final output = File(
      '${directory.path}${Platform.pathSeparator}$key-${height}p.mp4',
    );
    if (await output.exists()) {
      // Playing a proxy marks it recently used.
      try {
        await output.setLastModified(DateTime.now());
      } on FileSystemException {
        // The copy is still usable.
      }
      _jobs.remove(key);
      return ProxyState(ProxyStatus.ready, progress: 1, file: output);
    }
    final existing = _jobs[key];
    if (existing != null &&
        (existing.status != ProxyStatus.failed ||
            DateTime.now().difference(existing.failedAt!) <
                const Duration(minutes: 10))) {
      return ProxyState(
        existing.status,
        progress: existing.progress,
        error: existing.error,
      );
    }
    final job = _jobs[key] = _ProxyJob(source, output, height);
    _queue = _queue.then((_) => _run(job));
    return const ProxyState(ProxyStatus.queued);
  }

  Future<void> _run(_ProxyJob job) async {
    await directory.create(recursive: true);
    final partial = File('${job.output.path}.part');
    job.status = ProxyStatus.preparing;
    try {
      Future<void> work() => transcoder.transcode(
        job.source,
        partial,
        job.height,
        (value) => job.progress = value,
      );
      await (_keepAwake?.call(work) ?? work());
      await partial.rename(job.output.path);
      job
        ..status = ProxyStatus.ready
        ..progress = 1;
      // The file is the record from now on; a trimmed copy is made again.
      _jobs.removeWhere((_, value) => identical(value, job));
      await _trim();
    } on Object catch (error) {
      job
        ..status = ProxyStatus.failed
        ..failedAt = DateTime.now()
        ..error = error is ProcessException
            ? 'The PC could not convert this video.'
            : '$error';
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _trim() async {
    final files = <File, FileStat>{};
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.mp4')) {
        files[entity] = await entity.stat();
      }
    }
    var total = files.values.fold<int>(0, (sum, stat) => sum + stat.size);
    final oldest = files.entries.toList()
      ..sort((a, b) => a.value.modified.compareTo(b.value.modified));
    for (final entry in oldest) {
      if (total <= maxBytes) break;
      try {
        await entry.key.delete();
        total -= entry.value.size;
      } on FileSystemException {
        // A proxy being played stays until next time.
      }
    }
  }

  /// Waits for queued transcodes, for tests.
  Future<void> get settled => _queue;
}
