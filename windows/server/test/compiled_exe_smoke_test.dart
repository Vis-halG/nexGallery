import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final executable = File(
    'windows${Platform.pathSeparator}server${Platform.pathSeparator}build'
    '${Platform.pathSeparator}nex_gallery_server.exe',
  ).absolute;
  if (!await executable.exists()) {
    throw StateError(
      'Compile the server first: dart compile exe '
      'windows/server/bin/nex_gallery_server.dart '
      '-o windows/server/build/nex_gallery_server.exe',
    );
  }

  final workspace = await Directory.systemTemp.createTemp(
    'nex_gallery_compiled_server_test_',
  );
  final root = Directory('${workspace.path}${Platform.pathSeparator}root');
  final state = Directory('${workspace.path}${Platform.pathSeparator}state');
  await root.create();
  await state.create();

  final process = await Process.start(executable.path, <String>[
    '--root',
    'media=${root.path}',
    '--data-dir',
    state.path,
    '--port',
    '0',
  ]);
  final errors = StringBuffer();
  final errorSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(errors.write);
  final lines = StreamIterator<String>(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  final client = HttpClient();
  try {
    Uri? baseUri;
    for (var index = 0; index < 20 && await lines.moveNext(); index++) {
      final line = lines.current;
      if (!line.startsWith('{')) continue;
      final value = jsonDecode(line);
      if (value is Map<String, dynamic> && value['serverUrl'] is String) {
        baseUri = Uri.parse(value['serverUrl'] as String);
        break;
      }
    }
    if (baseUri == null) {
      throw StateError('Server emitted no connection payload: $errors');
    }

    final health = await _json(client, baseUri.resolve('/v1/health'));
    _expect(health['status'] == 'ok', 'compiled executable health endpoint');

    final code = await _json(
      client,
      baseUri.resolve('/v1/pair/code'),
      method: 'POST',
    );
    final pairing = await _json(
      client,
      baseUri.resolve('/v1/pair'),
      method: 'POST',
      body: <String, Object?>{
        'code': code['code'],
        'deviceName': 'Compiled executable smoke test',
      },
    );
    final token = pairing['token'] as String;
    final roots = await _json(
      client,
      baseUri.resolve('/v1/roots'),
      token: token,
    );
    final rootItems = roots['roots'] as List<dynamic>;
    _expect(
      rootItems.length == 1 &&
          (rootItems.single as Map<String, dynamic>)['id'] == 'media',
      'compiled executable pairing and authenticated roots',
    );
  } finally {
    client.close(force: true);
    await lines.cancel();
    process.kill(ProcessSignal.sigint);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
    await errorSubscription.cancel();
    await workspace.delete(recursive: true);
  }
}

Future<Map<String, dynamic>> _json(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, Object?>? body,
  String? token,
}) async {
  final request = await client.openUrl(method, uri);
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
  }
  final response = await request.close().timeout(const Duration(seconds: 5));
  final text = await utf8.decoder.bind(response).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw StateError('HTTP ${response.statusCode}: $text');
  }
  return jsonDecode(text) as Map<String, dynamic>;
}

void _expect(bool condition, String label) {
  if (!condition) throw StateError('FAILED: $label');
  stdout.writeln('PASS: $label');
}
