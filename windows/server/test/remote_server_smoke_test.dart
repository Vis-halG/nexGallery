import 'dart:convert';
import 'dart:io';

import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/path_guard.dart';
import 'package:nex_gallery/services/remote/sha256.dart';

Future<void> main() async {
  _expect(
    sha256Hex(utf8.encode('abc')) ==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'SHA-256 known vector',
  );

  final workspace = await Directory.systemTemp.createTemp(
    'nex_gallery_server_test_',
  );
  final root = Directory('${workspace.path}${Platform.pathSeparator}root');
  final outside = Directory(
    '${workspace.path}${Platform.pathSeparator}outside',
  );
  final data = Directory('${workspace.path}${Platform.pathSeparator}state');
  await root.create();
  await outside.create();
  await File('${outside.path}${Platform.pathSeparator}private.txt')
      .writeAsString('private');

  final guard = await PathGuard.create(<String, String>{'media': root.path});
  await _expectThrows(
    () => guard.resolve('media', '../outside/private.txt'),
    'parent traversal is rejected',
  );
  final link = Link('${root.path}${Platform.pathSeparator}outside-link');
  try {
    await link.create(outside.path);
    await _expectThrows(
      () => guard.resolve('media', 'outside-link/private.txt'),
      'symlink escape is rejected',
    );
  } on FileSystemException {
    // Creating symlinks can require a Windows developer-mode permission. The
    // traversal test still runs on every machine.
  }
  await _expectThrows(
    () => NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: <String, String>{'media': root.path},
        dataDirectory: Directory(
          '${root.path}${Platform.pathSeparator}.private-server-state',
        ),
        port: 0,
      ),
    ),
    'private server state cannot be exposed by an allowed root',
  );

  final server = await NexGalleryServer.create(
    RemoteServerConfig(
      allowedRoots: <String, String>{'media': root.path},
      dataDirectory: data,
      port: 0,
      maxUploadChunkBytes: 16,
    ),
  );
  final client = HttpClient();
  NexGalleryRemoteClient? remoteClient;
  await server.start();
  final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
  try {
    final health = await _request(client, base.resolve('/v1/health'));
    _expect(
      health.status == 200 && health.json['tls'] == false,
      'health endpoint',
    );

    final codeResponse = await _request(
      client,
      base.resolve('/v1/pair/code'),
      method: 'POST',
    );
    _expect(codeResponse.status == 201, 'loopback pairing-code API');
    final code = codeResponse.json['code'] as String;
    final pairing = await _request(
      client,
      base.resolve('/v1/pair'),
      method: 'POST',
      jsonBody: <String, Object?>{
        'code': code,
        'deviceName': 'Integration phone',
      },
    );
    _expect(pairing.status == 201, 'pairing succeeds');
    final token = pairing.json['token'] as String;
    final tokenId =
        (pairing.json['device'] as Map<String, dynamic>)['tokenId'] as String;
    final auth = <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer $token',
    };
    final apiClient = NexGalleryRemoteClient(baseUri: base, token: token);
    remoteClient = apiClient;

    final reused = await _request(
      client,
      base.resolve('/v1/pair'),
      method: 'POST',
      jsonBody: <String, Object?>{'code': code, 'deviceName': 'Second phone'},
    );
    _expect(reused.status == 401, 'pairing code is one-time');
    final tokenStore = await File(
      '${data.path}${Platform.pathSeparator}tokens.json',
    ).readAsString();
    _expect(!tokenStore.contains(token), 'raw bearer token is not persisted');

    final unauthenticated = await _request(client, base.resolve('/v1/roots'));
    _expect(unauthenticated.status == 401, 'protected endpoint requires token');
    final caseInsensitiveBearer = await _request(
      client,
      base.resolve('/v1/roots'),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'bearer $token',
      },
    );
    _expect(
      caseInsensitiveBearer.status == 200,
      'bearer authentication scheme is case-insensitive',
    );

    final folder = await _request(
      client,
      base.resolve('/v1/folders'),
      method: 'POST',
      headers: auth,
      jsonBody: <String, Object?>{'root': 'media', 'path': 'Album'},
    );
    _expect(folder.status == 201, 'folder creation');

    final content = utf8.encode('hello remote world');
    final firstChunk = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=sample.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'upload-test-01',
        'x-upload-offset': '0',
        'x-upload-total': '${content.length}',
        'x-upload-complete': 'false',
      },
      rawBody: content.sublist(0, 6),
    );
    _expect(
      firstChunk.status == 202 && firstChunk.json['nextOffset'] == 6,
      'first resumable chunk',
    );
    final finalChunk = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=sample.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'upload-test-01',
        'x-upload-offset': '6',
        'x-upload-total': '${content.length}',
        'x-upload-complete': 'true',
        'x-content-sha256': sha256Hex(content),
      },
      rawBody: content.sublist(6),
    );
    _expect(
      finalChunk.status == 201 &&
          finalChunk.json['sha256'] == sha256Hex(content),
      'checksum-verified atomic upload finalize',
    );

    final changedTotalFirst = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=changed-total.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'changed-total-01',
        'x-upload-offset': '0',
        'x-upload-total': '10',
        'x-upload-complete': 'false',
      },
      rawBody: utf8.encode('abc'),
    );
    final changedTotalFinal = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=changed-total.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'changed-total-01',
        'x-upload-offset': '3',
        'x-upload-total': '3',
        'x-upload-complete': 'true',
      },
      rawBody: const <int>[],
    );
    _expect(
      changedTotalFirst.status == 202 && changedTotalFinal.status == 409,
      'resumable upload total cannot change between chunks',
    );
    final wrongOffset = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=changed-total.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'changed-total-01',
        'x-upload-offset': '1',
        'x-upload-total': '10',
        'x-upload-complete': 'false',
      },
      rawBody: const <int>[],
    );
    _expect(
      wrongOffset.status == 409 &&
          ((wrongOffset.json['error'] as Map<String, dynamic>)['details']
                  as Map<String, dynamic>)['expectedOffset'] ==
              3,
      'resumable upload rejects a stale offset',
    );

    final tooLargeChunk = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=too-large.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'too-large-01',
        'x-upload-offset': '0',
        'x-upload-total': '17',
        'x-upload-complete': 'true',
      },
      rawBody: List<int>.filled(17, 1),
    );
    final rolledBackPart = File(
      '${root.path}${Platform.pathSeparator}'
      'too-large.txt.too-large-01.17.part',
    );
    final rolledBackPartExists = await rolledBackPart.exists();
    _expect(
      tooLargeChunk.status == 413 &&
          !await File('${root.path}${Platform.pathSeparator}too-large.txt')
              .exists() &&
          (!rolledBackPartExists || await rolledBackPart.length() == 0),
      'oversized streamed chunk is rolled back',
    );

    final invalidComplete = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=invalid-complete.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'invalid-complete-01',
        'x-upload-offset': '0',
        'x-upload-total': '0',
        'x-upload-complete': 'yes',
      },
      rawBody: const <int>[],
    );
    _expect(
      invalidComplete.status == 400,
      'upload completion header is strict',
    );

    final checksumMismatch = await _request(
      client,
      base.resolve('/v1/upload?root=media&path=bad-checksum.txt'),
      method: 'PUT',
      headers: <String, String>{
        ...auth,
        'x-upload-id': 'bad-checksum-01',
        'x-upload-offset': '0',
        'x-upload-total': '3',
        'x-upload-complete': 'true',
        'x-content-sha256': List<String>.filled(64, '0').join(),
      },
      rawBody: utf8.encode('bad'),
    );
    _expect(
      checksumMismatch.status == 422 &&
          !await File('${root.path}${Platform.pathSeparator}bad-checksum.txt')
              .exists(),
      'checksum mismatch is rejected without a destination file',
    );

    final range = await _request(
      client,
      base.resolve('/v1/download?root=media&path=sample.txt'),
      headers: <String, String>{...auth, HttpHeaders.rangeHeader: 'bytes=6-11'},
    );
    _expect(
      range.status == 206 && range.text == 'remote',
      'HTTP range download',
    );
    final suffixRange = await _request(
      client,
      base.resolve('/v1/download?root=media&path=sample.txt'),
      headers: <String, String>{...auth, HttpHeaders.rangeHeader: 'bytes=-5'},
    );
    _expect(
      suffixRange.status == 206 && suffixRange.text == 'world',
      'HTTP suffix range download',
    );
    final invalidRange = await _request(
      client,
      base.resolve('/v1/download?root=media&path=sample.txt'),
      headers: <String, String>{
        ...auth,
        HttpHeaders.rangeHeader: 'bytes=${content.length}-',
      },
    );
    _expect(
      invalidRange.status == 416 &&
          invalidRange.headers.value(HttpHeaders.contentRangeHeader) ==
              'bytes */${content.length}',
      'unsatisfied HTTP range reports the current length',
    );
    final traversal = await _request(
      client,
      base.resolve('/v1/download?root=media&path=..%2Foutside%2Fprivate.txt'),
      headers: auth,
    );
    _expect(traversal.status == 400, 'encoded parent traversal is rejected');

    final partialDestination = File(
      '${workspace.path}${Platform.pathSeparator}partial-download.txt',
    );
    await File('${partialDestination.path}.part')
        .writeAsBytes(content.sublist(0, 6));
    await apiClient.download(
      entry: RemoteEntry(
        root: 'media',
        path: 'sample.txt',
        name: 'sample.txt',
        type: 'file',
        modifiedAt: null,
        size: content.length,
      ),
      destination: partialDestination,
    );
    _expect(
      await partialDestination.readAsBytes().then(_bytesEqual(content)),
      'remote client resumes a partial range download',
    );

    final completeDestination = File(
      '${workspace.path}${Platform.pathSeparator}complete-download.txt',
    );
    await File('${completeDestination.path}.part').writeAsBytes(content);
    await apiClient.download(
      entry: RemoteEntry(
        root: 'media',
        path: 'sample.txt',
        name: 'sample.txt',
        type: 'file',
        modifiedAt: null,
        size: content.length,
      ),
      destination: completeDestination,
    );
    _expect(
      await completeDestination.readAsBytes().then(_bytesEqual(content)),
      'remote client finalizes an already complete partial file',
    );

    final clientSource = File(
      '${workspace.path}${Platform.pathSeparator}client-upload-source.txt',
    );
    await clientSource.writeAsString('client checksum upload');
    await apiClient.upload(
      root: 'media',
      remotePath: 'client-upload.txt',
      source: clientSource,
      chunkBytes: 5,
    );
    _expect(
      await File('${root.path}${Platform.pathSeparator}client-upload.txt')
              .readAsString() ==
          'client checksum upload',
      'remote client uploads chunks with final checksum verification',
    );
    await _expectThrows(
      () => apiClient.upload(
        root: 'media',
        remotePath: 'never-created.txt',
        source: clientSource,
        chunkBytes: 0,
      ),
      'remote client rejects a non-positive upload chunk size',
    );
    await _expectRemoteError(
      () => apiClient.download(
        entry: const RemoteEntry(
          root: 'media',
          path: 'missing.txt',
          name: 'missing.txt',
          type: 'file',
          modifiedAt: null,
        ),
        destination: File(
          '${workspace.path}${Platform.pathSeparator}missing.txt',
        ),
      ),
      status: 404,
      code: 'invalid_path',
      label: 'remote client decodes the server error envelope',
    );

    final listing = await _request(
      client,
      base.resolve('/v1/list?root=media&path='),
      headers: auth,
    );
    final entries = listing.json['entries'] as List<dynamic>;
    _expect(
      listing.status == 200 &&
          entries.any(
            (entry) => (entry as Map<String, dynamic>)['name'] == 'sample.txt',
          ),
      'metadata listing',
    );

    final search = await _request(
      client,
      base.resolve('/v1/search?root=media&path=&q=sample'),
      headers: auth,
    );
    _expect(
      search.status == 200 &&
          (search.json['results'] as List<dynamic>).length == 1,
      'bounded metadata search',
    );

    final moved = await _request(
      client,
      base.resolve('/v1/move'),
      method: 'POST',
      headers: auth,
      jsonBody: <String, Object?>{
        'root': 'media',
        'sourcePath': 'sample.txt',
        'destinationPath': 'Album/moved.txt',
      },
    );
    _expect(moved.status == 200, 'rename/move');

    final trashed = await _request(
      client,
      base.resolve('/v1/trash'),
      method: 'POST',
      headers: auth,
      jsonBody: <String, Object?>{'root': 'media', 'path': 'Album/moved.txt'},
    );
    _expect(
      trashed.status == 200 && trashed.json['recoverable'] == true,
      'recoverable trash',
    );
    final trashListing = await _request(
      client,
      base.resolve('/v1/trash?root=media'),
      headers: auth,
    );
    _expect(
      trashListing.status == 200 &&
          (trashListing.json['items'] as List<dynamic>).length == 1,
      'recoverable trash listing',
    );
    final restored = await _request(
      client,
      base.resolve('/v1/trash/restore'),
      method: 'POST',
      headers: auth,
      jsonBody: <String, Object?>{
        'root': 'media',
        'trashId': trashed.json['trashId'],
      },
    );
    _expect(restored.status == 200, 'trash restore');
    _expect(
      await File(
            '${root.path}${Platform.pathSeparator}Album${Platform.pathSeparator}moved.txt',
          ).readAsString() ==
          'hello remote world',
      'restored file content',
    );

    final thumbnail = await _request(
      client,
      base.resolve('/v1/thumbnail?root=media&path=Album/moved.txt'),
      headers: auth,
    );
    _expect(
      thumbnail.status == 501 &&
          (thumbnail.json['error'] as Map<String, dynamic>)['code'] ==
              'thumbnail_not_supported',
      'thumbnail has explicit unsupported response',
    );

    final revoke = await _request(
      client,
      base.resolve('/v1/tokens/revoke'),
      method: 'POST',
      headers: auth,
      jsonBody: <String, Object?>{'tokenId': tokenId},
    );
    _expect(revoke.status == 200, 'token revocation');
    final afterRevoke = await _request(
      client,
      base.resolve('/v1/roots'),
      headers: auth,
    );
    _expect(afterRevoke.status == 401, 'revoked token no longer authenticates');

    final audit = File('${data.path}${Platform.pathSeparator}audit.jsonl');
    _expect(
      await audit.exists() && (await audit.readAsLines()).length >= 8,
      'audit log',
    );
  } finally {
    remoteClient?.close();
    client.close(force: true);
    await server.stop(force: true);
    await workspace.delete(recursive: true);
  }

  stdout.writeln('All nexGallery remote server integration checks passed.');
}

bool Function(List<int>) _bytesEqual(List<int> expected) => (actual) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
};

Future<_Response> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const <String, String>{},
  Map<String, Object?>? jsonBody,
  List<int>? rawBody,
}) async {
  final request = await client.openUrl(method, uri);
  headers.forEach(request.headers.set);
  if (jsonBody != null) {
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(jsonBody)));
  } else if (rawBody != null) {
    request.headers.contentType = ContentType.binary;
    request.contentLength = rawBody.length;
    request.add(rawBody);
  }
  final response = await request.close();
  final bytes = await response.fold<List<int>>(<int>[], (value, chunk) {
    value.addAll(chunk);
    return value;
  });
  return _Response(response.statusCode, response.headers, bytes);
}

final class _Response {
  const _Response(this.status, this.headers, this.bytes);

  final int status;
  final HttpHeaders headers;
  final List<int> bytes;

  String get text => utf8.decode(bytes);
  Map<String, dynamic> get json => jsonDecode(text) as Map<String, dynamic>;
}

void _expect(bool condition, String label) {
  if (!condition) {
    throw StateError('FAILED: $label');
  }
  stdout.writeln('PASS: $label');
}

Future<void> _expectThrows(
  Future<Object?> Function() action,
  String label,
) async {
  try {
    await action();
  } catch (_) {
    stdout.writeln('PASS: $label');
    return;
  }
  throw StateError('FAILED: $label');
}

Future<void> _expectRemoteError(
  Future<Object?> Function() action, {
  required int status,
  required String code,
  required String label,
}) async {
  try {
    await action();
  } on RemoteApiException catch (error) {
    if (error.statusCode == status && error.code == code) {
      stdout.writeln('PASS: $label');
      return;
    }
    throw StateError(
      'FAILED: $label (HTTP ${error.statusCode}, ${error.code})',
    );
  }
  throw StateError('FAILED: $label');
}
