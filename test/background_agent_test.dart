@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/agent_config.dart';
import 'package:nex_gallery/services/remote/agent_runner.dart';
import 'package:nex_gallery/services/remote/network_modes.dart';
import 'package:nex_gallery/services/remote/owner_client.dart';
import 'package:nex_gallery/services/remote/power.dart';
import 'package:nex_gallery/services/remote/tailscale.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:path/path.dart' as p;

import '../tool/build_server.dart' show setWindowsGuiSubsystem;

/// flutter_test replaces HttpClient with a mock; the agent needs sockets.
final class _RealHttp extends HttpOverrides {}

final class _FakePower implements PowerRequest {
  var held = 0;
  var disposed = false;

  @override
  void acquire() => held++;
  @override
  void release() => held--;
  @override
  void dispose() => disposed = true;
}

late Directory _identityTemplate;

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  setUpAll(() async {
    _identityTemplate = await Directory.systemTemp.createTemp('nex_agent_id_');
    await TlsIdentity.loadOrCreate(_identityTemplate);
  });
  tearDownAll(() => _identityTemplate.delete(recursive: true));

  group('AwakeTracker', () {
    test('holds the PC awake during work and for a grace period', () {
      fakeAsync((async) {
        final power = _FakePower();
        final tracker = AwakeTracker(power, grace: const Duration(seconds: 90));
        var finished = false;
        tracker
            .during(() => Future<void>.delayed(const Duration(seconds: 10)))
            .then((_) => finished = true);
        async.flushMicrotasks();
        expect(power.held, 1);
        expect(tracker.isHeld, isTrue);

        async.elapse(const Duration(seconds: 10));
        expect(finished, isTrue);
        // A paused video resumes within the grace period without a gap.
        async.elapse(const Duration(seconds: 60));
        expect(power.held, 1);
        async.elapse(const Duration(seconds: 31));
        expect(power.held, 0);
        expect(tracker.isHeld, isFalse);

        tracker.dispose();
        expect(power.disposed, isTrue);
      });
    });

    test('overlapping work holds one request; always mode never lets go', () {
      fakeAsync((async) {
        final power = _FakePower();
        final tracker = AwakeTracker(power, grace: Duration.zero);
        tracker.during(() => Future<void>.delayed(const Duration(seconds: 1)));
        tracker.during(() => Future<void>.delayed(const Duration(seconds: 2)));
        async.flushMicrotasks();
        expect(power.held, 1);
        async.elapse(const Duration(seconds: 1));
        expect(power.held, 1);
        async.elapse(const Duration(seconds: 2));
        expect(power.held, 0);

        tracker.setAlways(true);
        expect(power.held, 1);
        tracker.during(() async {});
        async.elapse(const Duration(minutes: 5));
        expect(power.held, 1);
        tracker.setAlways(false);
        async.elapse(const Duration(seconds: 1));
        expect(power.held, 0);
      });
    });
  });

  test('agent configuration keeps every option', () async {
    final directory = await Directory.systemTemp.createTemp('nex_agent_cfg_');
    addTearDown(() => directory.delete(recursive: true));
    final file = AgentConfig.file(directory);
    await const AgentConfig(
      roots: {'shared_1': r'D:\Photos'},
      mode: ServerNetworkMode.privateNetwork,
      allowWrites: true,
      keepAwake: true,
      port: 9000,
    ).write(file);
    final read = await AgentConfig.read(file);
    expect(read.roots, {'shared_1': r'D:\Photos'});
    expect(read.mode, ServerNetworkMode.privateNetwork);
    expect(read.allowWrites, isTrue);
    expect(read.keepAwake, isTrue);
    expect(read.port, 9000);
  });

  group('AgentRunner', () {
    late Directory workspace;
    late Directory state;
    late Directory root;

    setUp(() async {
      HttpOverrides.global = _RealHttp();
      workspace = await Directory.systemTemp.createTemp('nex_agent_run_');
      state = await Directory(p.join(workspace.path, 'state')).create();
      root = await Directory(p.join(workspace.path, 'root')).create();
      for (final name in ['server.crt', 'server.key']) {
        await File(p.join(_identityTemplate.path, name))
            .copy(p.join(state.path, name));
      }
    });
    tearDown(() async {
      HttpOverrides.global = null;
      await workspace.delete(recursive: true);
    });

    Future<OwnerClient> owner(int port) async => OwnerClient(
      port: port,
      ownerSecret: await loadOrCreateOwnerSecret(state),
      fingerprint: (await TlsIdentity.loadOrCreate(state)).fingerprint,
    );

    Future<void> until(bool Function() condition) async {
      for (var i = 0; i < 800 && !condition(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(condition(), isTrue);
    }

    test(
      'waits on loopback for Tailscale, then adds the tailnet address',
      () async {
        if ((await localTailnetAddresses()).isNotEmpty) {
          markTestSkipped('This PC is connected to a real tailnet.');
          return;
        }
        final port = await _freePort();
        final config = AgentConfig.file(state);
        await AgentConfig(
          roots: {'shared_1': root.path},
          mode: ServerNetworkMode.privateNetwork,
          port: port,
        ).write(config);
        var tailscale = const TailscaleStatus(
          installed: true,
          state: 'NeedsLogin',
          addresses: [],
        );
        final runner = AgentRunner(
          config,
          tailscale: () async => tailscale,
          networkCheck: const Duration(milliseconds: 100),
        );
        final exit = runner.run();
        await until(() => runner.server != null);
        expect(runner.server!.boundAddresses.map((a) => a.address), [
          '127.0.0.1',
        ]);
        final client = await owner(port);
        addTearDown(client.close);
        expect(await client.isRunning(), isTrue);

        // 127.0.0.2 stands in for this PC's Tailscale address.
        tailscale = const TailscaleStatus(
          installed: true,
          running: true,
          state: 'Running',
          addresses: ['127.0.0.2'],
        );
        await until(
          () =>
              runner.server?.boundAddresses.any(
                (a) => a.address == '127.0.0.2',
              ) ==
              true,
        );
        expect(await client.isRunning(), isTrue);

        await client.shutdown();
        expect(await exit, 0);
        expect(
          await File(p.join(state.path, 'agent.log')).readAsString(),
          allOf(contains('Network changed'), contains('Stopped by shutdown')),
        );
      },
    );

    test('a second agent for the same user exits at once', () async {
      final port = await _freePort();
      final config = AgentConfig.file(state);
      await AgentConfig(
        roots: {'shared_1': root.path},
        port: port,
        keepAwake: true,
      ).write(config);
      final first = AgentRunner(config);
      final running = first.run();
      await until(() => first.server != null);
      expect(await AgentRunner(config).run(), 0);
      expect(first.server, isNotNull);
      first.stop();
      expect(await running, 0);
    });

    test('a damaged configuration exits with a configuration error', () async {
      final config = AgentConfig.file(state);
      await config.writeAsString('{"version": 99}');
      expect(await AgentRunner(config).run(), 78);
      expect(
        await File(p.join(state.path, 'agent.log')).readAsString(),
        contains('Cannot read'),
      );
    });
  });

  test('the agent build switches the PE subsystem to Windows GUI', () {
    final image = Uint8List(0x200);
    final data = ByteData.sublistView(image)
      ..setUint16(0, 0x5A4D, Endian.little)
      ..setUint32(0x3C, 0x80, Endian.little)
      ..setUint32(0x80, 0x00004550, Endian.little)
      ..setUint16(0x80 + 24 + 68, 3, Endian.little);
    setWindowsGuiSubsystem(image);
    expect(data.getUint16(0x80 + 24 + 68, Endian.little), 2);
    expect(
      () => setWindowsGuiSubsystem(Uint8List(0x200)),
      throwsFormatException,
    );
  });
}
