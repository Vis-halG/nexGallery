@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/features/remote/qr_view.dart';
import 'package:nex_gallery/features/remote/remote_page.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/pairing_payload.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:nex_gallery/services/remote/tailscale.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:nex_gallery/src/server_controller.dart';
import 'package:path/path.dart' as p;

const _status = '''
{
  "BackendState": "Running",
  "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"],
  "Self": {
    "HostName": "desk",
    "DNSName": "desk.tail1234.ts.net.",
    "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"]
  },
  "Peer": {
    "nodekey:a": {
      "HostName": "pixel", "OS": "android", "Online": true,
      "CurAddr": "203.0.113.5:41641", "Relay": "blr",
      "TailscaleIPs": ["100.80.1.2"]
    },
    "nodekey:b": {
      "HostName": "tablet", "Online": true, "CurAddr": "", "Relay": "fra",
      "TailscaleIPs": ["100.80.1.3"]
    },
    "nodekey:c": {
      "HostName": "old-laptop", "Online": false, "CurAddr": "", "Relay": "",
      "TailscaleIPs": ["100.80.1.4"]
    }
  }
}
''';

/// flutter_test replaces HttpClient with a mock; pairing needs real sockets.
final class _RealHttp extends HttpOverrides {}

/// RSA identity generation is slow in pure Dart, so tests share one.
late Directory _identityTemplate;

Future<Directory> _serverState(Directory parent) async {
  final state = await Directory(p.join(parent.path, 'server')).create();
  for (final name in ['server.crt', 'server.key']) {
    await File(p.join(_identityTemplate.path, name))
        .copy(p.join(state.path, name));
  }
  return state;
}

void main() {
  setUpAll(() async {
    _identityTemplate = await Directory.systemTemp.createTemp(
      'nex_tls_template_',
    );
    await TlsIdentity.loadOrCreate(_identityTemplate);
  });
  tearDownAll(() async {
    await _identityTemplate.delete(recursive: true);
  });

  test('Tailscale status shows addresses and direct or relayed peers', () {
    final status = parseTailscaleStatus(_status);
    expect(status.running, isTrue);
    expect(status.selfName, 'desk');
    expect(status.dnsName, 'desk.tail1234.ts.net');
    expect(status.ipv4, ['100.101.102.103']);
    expect(status.peerFor('100.80.1.2')!.connection, 'direct');
    expect(status.peerFor('100.80.1.3')!.connection, 'relay');
    expect(status.peerFor('100.80.1.3')!.relay, 'fra');
    expect(status.peerFor('100.80.1.4')!.connection, 'idle');
    expect(isTailnetAddress('100.64.0.1'), isTrue);
    expect(isTailnetAddress('100.127.255.254'), isTrue);
    expect(isTailnetAddress('100.128.0.1'), isFalse);
    expect(isTailnetAddress('192.168.1.10'), isFalse);
    expect(isTailnetAddress('fd7a:115c:a1e0::5'), isTrue);
    expect(
      parseTailscaleStatus('{"BackendState":"NeedsLogin"}').running,
      isFalse,
    );
  });

  test('pairing links round-trip and reject unsafe content', () {
    final fingerprint = 'ab' * 32;
    final link = PairingPayload(
      name: 'Desk PC',
      addresses: [
        Uri.parse('https://192.168.1.20:8732'),
        Uri.parse('https://100.101.102.103:8732'),
      ],
      code: '12345678',
      fingerprint: fingerprint,
    ).encode();
    final parsed = PairingPayload.parse(link);
    expect(parsed.name, 'Desk PC');
    expect(parsed.addresses, hasLength(2));
    expect(parsed.code, '12345678');
    expect(parsed.fingerprint, fingerprint);
    expect(
      () => PairingPayload.parse('https://example.com'),
      throwsFormatException,
    );
    expect(
      () => PairingPayload.parse(
        'nexgallery://pair?v=1&u=http://1.2.3.4:1&c=12345678&f=$fingerprint',
      ),
      throwsFormatException,
    );
    expect(
      () => PairingPayload.parse(
        'nexgallery://pair?v=1&u=https://1.2.3.4:1&c=12&f=$fingerprint',
      ),
      throwsFormatException,
    );
  });

  group('desktop controller', () {
    late Directory workspace;
    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('nex_desktop_');
    });
    tearDown(() async {
      await workspace.delete(recursive: true);
    });

    test(
      'approves a phone, remembers settings and refuses missing Tailscale',
      () async {
        final shared = await Directory(p.join(workspace.path, 'Photos'))
            .create();
        await File(p.join(shared.path, 'a.txt')).writeAsString('a');
        final state = await _serverState(workspace);
        final controller = DesktopServerController(
          dataDirectory: state,
          port: 0,
          tailscaleReader: () async => TailscaleStatus.notInstalled,
        );
        final client = <NexGalleryRemoteClient>[];
        try {
          await controller.start(sharedPaths: [shared.path], allowWrites: true);
          expect(controller.isRunning, isTrue, reason: controller.error);
          final link = PairingPayload.parse(controller.pairingLink!);
          expect(link.fingerprint, controller.fingerprint);
          final phone = HttpOverrides.runWithHttpOverrides(
            () => NexGalleryRemoteClient(
              baseUri: link.addresses.first,
              certificateFingerprint: link.fingerprint,
            ),
            _RealHttp(),
          );
          client.add(phone);
          final pairing = phone.pair(
            code: link.code,
            deviceName: 'Pixel',
            pollInterval: const Duration(milliseconds: 20),
          );
          while (controller.pendingPairings.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          final firstCode = controller.pairingCode!.code;
          await controller.approve(
            controller.pendingPairings.single.requestId,
            scopes: DeviceScope.readOnly,
          );
          await pairing;
          expect(controller.pairingCode!.code, isNot(firstCode));
          expect(controller.devices.single.name, 'Pixel');
          expect((await phone.list(root: 'shared_1')).single.name, 'a.txt');
          final audit = await controller.readAudit();
          expect(audit.map((e) => e['action']), contains('pair.approve'));

          await controller.revoke(controller.devices.single.tokenId);
          expect(controller.devices, isEmpty);
          await controller.setAutoStart(true);
          await controller.stop();

          final restored = DesktopServerController(
            dataDirectory: state,
            port: 0,
            tailscaleReader: () async => TailscaleStatus.notInstalled,
          );
          await restored.load();
          expect(restored.sharedPaths, [shared.absolute.path]);
          expect(restored.allowWrites, isTrue);
          expect(restored.isRunning, isTrue);
          await restored.stop();
          await restored.start(
            sharedPaths: [shared.path],
            mode: ServerNetworkMode.privateNetwork,
          );
          if (restored.state == DesktopServerState.error) {
            expect(restored.error, contains('Tailscale'));
          }
          await restored.stop();
          restored.dispose();
        } finally {
          for (final phone in client) {
            phone.close();
          }
          await controller.stop();
          controller.dispose();
        }
      },
    );
  });

  testWidgets('server page shows QR, approval request and permissions', (
    tester,
  ) async {
    final workspace = Directory.systemTemp.createTempSync('nex_server_ui_');
    final shared = Directory(p.join(workspace.path, 'Photos'))..createSync();
    final state = (await tester.runAsync(() => _serverState(workspace)))!;
    final controller = DesktopServerController(
      dataDirectory: state,
      port: 0,
      tailscaleReader: () async => TailscaleStatus.notInstalled,
    );
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemotePage(isWindows: true, controller: controller),
        ),
      ),
    );
    await tester.runAsync(() async {
      await controller.start(sharedPaths: [shared.path]);
    });
    await tester.pump();
    expect(find.text('Server running'), findsOneWidget);
    expect(find.byType(QrView), findsOneWidget);
    expect(find.text('Scan in nexGallery on your phone'), findsOneWidget);

    final phone = HttpOverrides.runWithHttpOverrides(
      () => NexGalleryRemoteClient(
        baseUri: Uri.parse(controller.urls.first),
        certificateFingerprint: controller.fingerprint,
      ),
      _RealHttp(),
    );
    await tester.runAsync(() async {
      await phone.startPairing(
        code: controller.pairingCode!.code,
        deviceName: 'Kitchen tablet',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Waiting for your approval'), findsOneWidget);
    expect(find.text('Kitchen tablet'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Allow "Kitchen tablet"?'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
    // File writes started from taps would run in the test's fake zone, so
    // the approval itself is made from the real zone.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => controller.approve(
        controller.pendingPairings.single.requestId,
        scopes: DeviceScope.readOnly,
      ),
    );
    await tester.pump();
    expect(controller.devices.single.name, 'Kitchen tablet');
    await tester.scrollUntilVisible(
      find.text('Paired phones'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Paired phones'), findsOneWidget);
    expect(find.textContaining('Browse, Open and download'), findsOneWidget);

    phone.close();
    await tester.runAsync(() async {
      await controller.stop();
      controller.dispose();
      await workspace.delete(recursive: true);
    });
  });
}
