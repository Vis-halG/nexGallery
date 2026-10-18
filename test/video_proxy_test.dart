import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:nex_gallery/services/remote/video_proxy.dart';
import 'package:path/path.dart' as p;

final class _FakeTranscoder implements VideoTranscoder {
  final calls = <int>[];
  Completer<void>? gate;
  bool fail = false;

  @override
  String get description => 'fake';

  @override
  Future<void> transcode(
    File source,
    File output,
    int height,
    void Function(double progress) onProgress,
  ) async {
    calls.add(height);
    onProgress(0.5);
    await gate?.future;
    if (fail) throw const ProcessException('ffmpeg', [], 'broken', 1);
    await output.writeAsString('${height}p:${await source.readAsString()}');
  }
}

void main() {
  test('FFmpeg makes a fast-start H.264 MP4 no taller than asked', () {
    final software = ffmpegProxyArguments('in.mkv', 'out.mp4', 720, 'libx264');
    expect(software, containsAllInOrder(['-i', 'in.mkv']));
    expect(software, containsAllInOrder(['-vf', r'scale=-2:min(720\,ih)']));
    expect(software, containsAllInOrder(['-crf', '23', '-maxrate', '2500000']));
    expect(software, containsAllInOrder(['-movflags', '+faststart']));
    expect(software, isNot(contains('-hwaccel')));
    expect(software.last, 'out.mp4');

    final gpu = ffmpegProxyArguments('in.mkv', 'out.mp4', 360, 'h264_nvenc');
    expect(gpu, containsAllInOrder(['-hwaccel', 'auto', '-i']));
    expect(gpu, containsAllInOrder(['-b:v', '800000']));
    expect(gpu, isNot(contains('-crf')));
  });

  test('FFmpeg progress is read from its duration and progress lines', () {
    expect(
      parseFfmpegDuration('  Duration: 00:01:02.50, start: 0.000000'),
      const Duration(minutes: 1, seconds: 2, milliseconds: 500),
    );
    expect(parseFfmpegDuration('Stream #0:0: Video: h264'), isNull);
    expect(
      parseFfmpegProgress('out_time_us=31250000'),
      const Duration(seconds: 31, milliseconds: 250),
    );
    expect(parseFfmpegProgress('progress=continue'), isNull);
  });

  test('the proxy cache drops the least recently played copies', () async {
    final directory = await Directory.systemTemp.createTemp('nex_proxy_lru_');
    addTearDown(() => directory.delete(recursive: true));
    final transcoder = _FakeTranscoder();
    final cache = VideoProxyCache(
      Directory(p.join(directory.path, 'cache')),
      transcoder,
      maxBytes: 30,
    );
    final videos = [
      for (final name in ['a', 'b', 'c'])
        await File(p.join(directory.path, '$name.mp4'))
            .writeAsString(name * 10),
    ];
    final cached = Directory(p.join(directory.path, 'cache'));
    for (final (index, video) in videos.indexed) {
      expect(
        (await cache.request(video, 'v1', 360)).status,
        ProxyStatus.queued,
      );
      await cache.settled;
      // Distinct play times keep the eviction order deterministic.
      await for (final file in cached.list()) {
        if (file is File &&
            (await file.readAsString()).endsWith(
              String.fromCharCode(97 + index),
            )) {
          await file.setLastModified(
            DateTime(2026, 1, 1).add(Duration(hours: index)),
          );
        }
      }
    }
    // Each copy is 15 bytes, so only the two most recent fit.
    expect(
      (await cache.request(videos[0], 'v1', 360)).status,
      ProxyStatus.queued,
    );
    await cache.settled;
    expect(
      (await cache.request(videos[2], 'v1', 360)).status,
      ProxyStatus.ready,
    );
    expect(transcoder.calls.length, 4);
  });

  group('server', () {
    late Directory workspace;
    late Directory shared;
    late NexGalleryServer server;
    late NexGalleryRemoteClient phone;
    late _FakeTranscoder transcoder;

    Future<void> start({VideoTranscoder? video}) async {
      server = await NexGalleryServer.create(
        RemoteServerConfig(
          allowedRoots: {'shared': shared.path},
          dataDirectory: Directory(p.join(workspace.path, 'state')),
          port: 0,
          videoTranscoder: video,
        ),
      );
      await server.start();
      phone = NexGalleryRemoteClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
      );
      final pairing = phone.pair(
        code: server.createPairingCode().code,
        deviceName: 'Phone',
        pollInterval: const Duration(milliseconds: 20),
      );
      while (server.pendingPairings.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await server.approvePairing(
        server.pendingPairings.single.requestId,
        scopes: DeviceScope.readOnly,
      );
      await pairing;
    }

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('nex_proxy_server_');
      shared = await Directory(p.join(workspace.path, 'shared')).create();
      await File(p.join(shared.path, 'trip.mkv')).writeAsString('original');
      await File(p.join(shared.path, 'notes.txt')).writeAsString('text');
      transcoder = _FakeTranscoder();
    });
    tearDown(() async {
      phone.close();
      await server.stop(force: true);
      await workspace.delete(recursive: true);
    });

    RemoteEntry entry(String name) => RemoteEntry(
      root: 'shared',
      path: name,
      name: name,
      type: 'file',
      modifiedAt: null,
    );

    test('a read-only phone streams a prepared 720p copy', () async {
      transcoder.gate = Completer<void>();
      await start(video: transcoder);
      expect((await phone.info()).videoProxy, isTrue);

      final video = entry('trip.mkv');
      expect((await phone.proxyStatus(video, 720)).status, 'queued');
      await expectLater(
        phone.readStream(video, quality: 720),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.code,
            'code',
            'proxy_not_ready',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final preparing = await phone.proxyStatus(video, 720);
      expect(preparing.status, 'preparing');
      expect(preparing.progress, 0.5);

      transcoder.gate!.complete();
      await server.proxiesSettled;
      expect((await phone.proxyStatus(video, 720)).ready, isTrue);
      final full = await phone.readStream(video, quality: 720);
      expect(full.headers.contentType?.mimeType, 'video/mp4');
      expect(await utf8.decodeStream(full), '720p:original');
      final part = await phone.readStream(
        video,
        quality: 720,
        range: 'bytes=5-',
      );
      expect(part.statusCode, 206);
      expect(await utf8.decodeStream(part), 'original');
      expect(transcoder.calls, [720]);
    });

    test('a changed original gets a new copy', () async {
      await start(video: transcoder);
      final video = entry('trip.mkv');
      await phone.proxyStatus(video, 360);
      await server.proxiesSettled;
      await File(p.join(shared.path, 'trip.mkv')).writeAsString('edited cut');
      expect((await phone.proxyStatus(video, 360)).status, 'queued');
      await server.proxiesSettled;
      expect(
        await utf8.decodeStream(await phone.readStream(video, quality: 360)),
        '360p:edited cut',
      );
    });

    test('failures, other files and bad qualities are explained', () async {
      transcoder.fail = true;
      await start(video: transcoder);
      await phone.proxyStatus(entry('trip.mkv'), 720);
      await server.proxiesSettled;
      final failed = await phone.proxyStatus(entry('trip.mkv'), 720);
      expect(failed.failed, isTrue);
      expect(failed.error, contains('could not convert'));
      await expectLater(
        phone.proxyStatus(entry('notes.txt'), 720),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.code,
            'code',
            'not_a_video',
          ),
        ),
      );
      await expectLater(
        phone.proxyStatus(entry('trip.mkv'), 480),
        throwsA(isA<RemoteApiException>()),
      );
    });

    test('without FFmpeg phones are told to stream the original', () async {
      await start(video: null);
      if ((await phone.info()).videoProxy) {
        markTestSkipped('FFmpeg is installed on this PC.');
        return;
      }
      await expectLater(
        phone.proxyStatus(entry('trip.mkv'), 720),
        throwsA(
          isA<RemoteApiException>().having(
            (e) => e.code,
            'code',
            'proxy_unavailable',
          ),
        ),
      );
    });
  });
}
