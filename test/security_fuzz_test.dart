@Tags(['security'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/path_guard.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:path/path.dart' as p;

void main() {
  test('seeded path fuzzing never resolves outside an allowed root or into protocol files', () async {
    final workspace = await Directory.systemTemp.createTemp('nex_path_fuzz_');
    try {
      final root = await Directory('${workspace.path}/shared').create();
      await File('${workspace.path}/private.txt').writeAsString('private');
      final guard = await PathGuard.create({'shared': root.path});
      final canonical = await root.resolveSymbolicLinks();
      final random = Random(20261029);
      final segments = [
        '..',
        '.',
        '',
        'safe',
        'a.jpg',
        '.nexgallery-trash',
        '.nexgallery-quarantine',
        'C:',
        'CON',
        'NUL',
        'x:y',
        '%2e%2e',
        '%252e%252e',
        '\u0000',
        '\u202e',
        'a. ',
        'é',
        'फ़ोटो',
      ];
      for (var i = 0; i < 1500; i++) {
        final input = List.generate(
          1 + random.nextInt(6),
          (_) => segments[random.nextInt(segments.length)],
        ).join(random.nextBool() ? '/' : '\\');
        try {
          final resolved = await guard.resolve(
            'shared',
            input,
            mustExist: false,
          );
          expect(
            p.equals(resolved, canonical) || p.isWithin(canonical, resolved),
            isTrue,
            reason: input,
          );
          final names = p.split(p.relative(resolved, from: canonical));
          expect(
            names.any((v) => v.toLowerCase().startsWith('.nexgallery-')),
            isFalse,
            reason: input,
          );
        } on RemotePathException {
          /* Correct rejection of malformed names. */
        }
      }
    } finally {
      await workspace.delete(recursive: true);
    }
  });

  test('malformed permission values cannot turn into full access', () {
    for (final value in [
      'browse',
      1,
      true,
      {},
      ['unknown'],
      ['browse', 1],
    ]) {
      expect(() => DeviceScope.parse(value), throwsFormatException);
    }
    expect(DeviceScope.parse([]), isEmpty);
    expect(DeviceScope.parse(['browse']), {DeviceScope.browse});
  });

  test('bounded malformed HTTP bodies are rejected without crashing or exposing server state', () async {
    final workspace = await Directory.systemTemp.createTemp('nex_http_fuzz_');
    final root = await Directory('${workspace.path}/shared').create();
    final server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'shared': root.path},
        dataDirectory: Directory('${workspace.path}/server'),
        port: 0,
        discoveryPort: 0,
        maxJsonBytes: 1024,
        requestsPerMinute: 5000,
        pairAttemptsPerMinute: 5000,
        log: (_) {},
      ),
    );
    final http = HttpClient();
    try {
      await server.start();
      final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
      final random = Random(8732);
      final bodies = <List<int>>[
        [],
        [255, 254, 0],
        utf8.encode('['),
        utf8.encode('null'),
        utf8.encode('[]'),
        utf8.encode('{"code":true,"deviceName":[]}'),
        utf8.encode('{"code":"1234","deviceName":"x","publicKey":{}}'),
        utf8.encode(jsonEncode({'code': 'x' * 1100, 'deviceName': 'x'})),
        for (var i = 0; i < 80; i++)
          List.generate(1 + random.nextInt(128), (_) => random.nextInt(256)),
      ];
      for (var caseIndex = 0; caseIndex < bodies.length; caseIndex++) {
        final body = bodies[caseIndex];
        final HttpClientRequest request;
        try {
          request = await http.postUrl(base.resolve('/v1/pair'));
        } catch (error) {
          throw StateError(
            'HTTP fuzz case $caseIndex could not open after the preceding rejection: $error',
          );
        }
        request.headers.contentType = ContentType.json;
        request.contentLength = body.length;
        request.done.ignore();
        request.add(body);
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        expect(response.statusCode, anyOf(400, 401, 413));
        expect(text, isNot(contains(workspace.path)));
        expect(text, isNot(contains('StackTrace')));
      }
      final response = await (await http.getUrl(base.resolve('/v1/health')))
          .close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      expect(server.devices, isEmpty);
    } finally {
      http.close(force: true);
      await server.stop(force: true);
      await workspace.delete(recursive: true);
    }
  });
}
