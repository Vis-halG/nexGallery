import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/sha256.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';

/// Real pinned-TLS transfers, with a fresh client resuming both directions.
/// Run --mib=1024 for a longer local soak. All fixtures stay in system temp.
Future<void> main(List<String> arguments) async {
  final argument = arguments.where((v) => v.startsWith('--mib=')).firstOrNull;
  final mib = argument == null ? 64 : int.parse(argument.substring(6));
  if (mib < 8 || mib > 4096) {
    throw const FormatException('Choose 8 to 4096 MiB.');
  }
  final directory = await Directory.systemTemp.createTemp('nex_transfer_soak_');
  NexGalleryServer? server;
  NexGalleryRemoteClient? client;
  final watch = Stopwatch()..start();
  try {
    final shared = await Directory('${directory.path}/shared').create();
    final state = await Directory('${directory.path}/state').create();
    final source = File('${directory.path}/source.mp4');
    final block = Uint8List.fromList(
      List.generate(1 << 20, (i) => (i * 31 + i ~/ 256) % 256),
    );
    final writer = source.openWrite();
    for (var i = 0; i < mib; i++) {
      writer.add(block);
    }
    await writer.close();
    final tls = await TlsIdentity.loadOrCreate(state);
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'pc': shared.path},
        dataDirectory: state,
        port: 0,
        discoveryPort: 0,
        allowWrites: true,
        requireApproval: false,
        requestsPerMinute: 100000,
        securityContext: tls.context,
        certificateFingerprint: tls.fingerprint,
      ),
    );
    await server.start();
    final address = Uri.parse('https://127.0.0.1:${server.boundPort}');
    client = NexGalleryRemoteClient(
      baseUri: address,
      certificateFingerprint: tls.fingerprint,
    );
    await client.pair(
      code: server.createPairingCode().code,
      deviceName: 'Isolated soak fixture',
    );
    NexGalleryRemoteClient reconnect(NexGalleryRemoteClient previous) {
      final next = NexGalleryRemoteClient(
        baseUri: address,
        certificateFingerprint: tls.fingerprint,
        token: previous.token,
        tokenId: previous.tokenId,
        deviceKey: previous.deviceKey,
      );
      previous.close();
      return next;
    }

    final resume = File('${directory.path}/upload-resume.json');
    var interrupted = false;
    try {
      await client.upload(
        root: 'pc',
        remotePath: 'copy.mp4',
        source: source,
        resumeState: resume,
        chunkBytes: 1 << 20,
        onProgress: (sent, total) {
          if (sent >= 3 << 20 && sent < total) throw const _Interrupted();
        },
      );
    } on _Interrupted {
      interrupted = true;
    }
    if (!interrupted || !await resume.exists()) {
      throw StateError('Upload interruption was not checkpointed.');
    }
    final offset =
        (jsonDecode(await resume.readAsString()) as Map)['offset'] as int;
    client = reconnect(client);
    var firstProgress = 0;
    await client.upload(
      root: 'pc',
      remotePath: 'copy.mp4',
      source: source,
      resumeState: resume,
      chunkBytes: 1 << 20,
      onProgress: (sent, _) {
        if (firstProgress == 0) firstProgress = sent;
      },
    );
    if (firstProgress <= offset) {
      throw StateError('Upload did not resume beyond its checkpoint.');
    }
    final entry = (await client.list(root: 'pc')).single;
    final destination = File('${directory.path}/download.mp4');
    interrupted = false;
    try {
      await client.download(
        entry: entry,
        destination: destination,
        onProgress: (received, total) {
          if (received >= 3 << 20 && received < total!) {
            throw const _Interrupted();
          }
        },
      );
    } on _Interrupted {
      interrupted = true;
    }
    final partial = File('${destination.path}.part');
    if (!interrupted || !await partial.exists() || await destination.exists()) {
      throw StateError('Interrupted download was exposed as complete.');
    }
    client = reconnect(client);
    await client.download(entry: entry, destination: destination);
    final expected = await Sha256.fileHex(source);
    if (await Sha256.fileHex(destination) != expected ||
        await Sha256.fileHex(File('${shared.path}/copy.mp4')) != expected) {
      throw StateError('Transferred bytes did not match the source SHA-256.');
    }
    stdout.writeln(
      'PASS: $mib MiB upload/download over pinned TLS, fresh-client resume, SHA-256 equality (${watch.elapsed.inSeconds}s).',
    );
  } finally {
    client?.close();
    await server?.stop(force: true);
    await directory.delete(recursive: true);
  }
}

class _Interrupted implements Exception {
  const _Interrupted();
}
