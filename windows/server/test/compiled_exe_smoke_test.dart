import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nex_gallery/services/remote/agent_config.dart';
import 'package:nex_gallery/services/remote/network_modes.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/owner_client.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';

/// Runs the executables built by `dart run tool/build_server.dart`.
Future<void> main() async {
  final build =
      'windows${Platform.pathSeparator}server'
      '${Platform.pathSeparator}build${Platform.pathSeparator}';
  final cli = File('${build}nex_gallery_server.exe').absolute;
  final agent = File('${build}nexgallery_server.exe').absolute;
  for (final executable in [cli, agent]) {
    if (!await executable.exists()) {
      throw StateError(
        'Build the server first: dart run tool/build_server.dart',
      );
    }
  }
  await _cli(cli);
  await _agent(agent);
}

/// Console mode: the owner approves the phone by typing in the console.
Future<void> _cli(File executable) async {
  final workspace = await Directory.systemTemp.createTemp('nex_cli_exe_test_');
  final root = await Directory('${workspace.path}/root').create();
  final state = await Directory('${workspace.path}/state').create();
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
  try {
    Uri? baseUri;
    String? code;
    while (baseUri == null && await lines.moveNext()) {
      final line = lines.current;
      if (line.startsWith('Pairing code: ')) code = line.substring(14).trim();
      if (!line.startsWith('{')) continue;
      final value = jsonDecode(line) as Map<String, dynamic>;
      baseUri = Uri.parse(value['serverUrl'] as String);
    }
    if (baseUri == null || code == null) {
      throw StateError('Server emitted no connection payload: $errors');
    }
    final phone = NexGalleryRemoteClient(baseUri: baseUri);
    await phone.health();
    _expect(true, 'CLI health endpoint');

    final ticket = await phone.startPairing(
      code: code,
      deviceName: 'Compiled executable smoke test',
    );
    _expect(ticket != null, 'CLI pairing waits for approval');
    while (await lines.moveNext()) {
      if (lines.current.startsWith('PAIRING REQUEST ${ticket!.requestId}')) {
        break;
      }
    }
    _expect(!await phone.checkPairing(ticket!), 'CLI request is pending');
    process.stdin.writeln('approve ${ticket.requestId}');
    await process.stdin.flush();
    while (await lines.moveNext()) {
      if (lines.current.startsWith('APPROVED')) break;
    }
    _expect(await phone.checkPairing(ticket), 'CLI console approval');
    final roots = await phone.roots();
    _expect(
      roots.length == 1 && roots.single.id == 'media',
      'CLI authenticated, signed roots request',
    );
    phone.close();
  } finally {
    process.stdin.writeln('quit');
    await process.stdin.flush();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
    await lines.cancel();
    await errorSubscription.cancel();
    await workspace.delete(recursive: true);
  }
}

/// Background agent: no console, TLS, managed through the owner API.
Future<void> _agent(File executable) async {
  final workspace = await Directory.systemTemp.createTemp('nex_agent_test_');
  final root = await Directory('${workspace.path}/root').create();
  await File('${root.path}/hello.txt').writeAsString('hello from the agent');
  final state = await Directory('${workspace.path}/state').create();
  final identity = await TlsIdentity.loadOrCreate(state);
  final port = await _freePort();
  final config = AgentConfig.file(state);
  await AgentConfig(
    roots: {'shared_1': root.path},
    mode: ServerNetworkMode.thisPc,
    port: port,
  ).write(config);
  final owner = OwnerClient(
    port: port,
    ownerSecret: await loadOrCreateOwnerSecret(state),
    fingerprint: identity.fingerprint,
  );
  // Detached, as the desktop app and the sign-in entry start it.
  await Process.start(executable.path, <String>[
    '--config',
    config.path,
  ], mode: ProcessStartMode.detached);
  try {
    var running = false;
    for (var attempt = 0; !running && attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      running = await owner.isRunning();
    }
    _expect(running, 'agent serves the owner API over pinned TLS');

    final wrongOwner = OwnerClient(
      port: port,
      ownerSecret: 'x' * 43,
      fingerprint: identity.fingerprint,
    );
    try {
      await wrongOwner.createPairingCode();
      _expect(false, 'agent rejects another owner secret');
    } on RemoteApiException catch (error) {
      _expect(error.code == 'owner_required', 'agent rejects a wrong secret');
    } finally {
      wrongOwner.close();
    }

    final code = await owner.createPairingCode();
    final phone = NexGalleryRemoteClient(
      baseUri: Uri.parse('https://127.0.0.1:$port'),
      certificateFingerprint: identity.fingerprint,
    );
    final ticket = await phone.startPairing(
      code: code.code,
      deviceName: 'Agent smoke phone',
    );
    final pending = await owner.pendingPairings();
    _expect(
      pending.single.requestId == ticket!.requestId &&
          pending.single.signedRequests,
      'agent lists the waiting phone for the owner',
    );
    await owner.approve(ticket.requestId, scopes: {'browse', 'download'});
    _expect(await phone.checkPairing(ticket), 'owner approval over the agent');
    final entries = await phone.list(root: 'shared_1', path: '');
    _expect(
      entries.single.name == 'hello.txt',
      'paired phone browses the agent',
    );
    _expect((await owner.devices()).length == 1, 'agent lists paired phones');
    phone.close();

    await owner.shutdown();
    var stopped = false;
    for (var attempt = 0; !stopped && attempt < 40; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      stopped = !await owner.isRunning();
    }
    _expect(stopped, 'agent exits after the owner shutdown request');
    final log = await File('${state.path}/agent.log').readAsString();
    _expect(log.contains('Stopped by shutdown.'), 'agent writes agent.log');
  } finally {
    owner.close();
    // The agent releases its files shortly after exiting.
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await workspace.delete(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }
}

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void _expect(bool condition, String label) {
  if (!condition) throw StateError('FAILED: $label');
  stdout.writeln('PASS: $label');
}
