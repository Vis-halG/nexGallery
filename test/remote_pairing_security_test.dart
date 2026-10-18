import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nex_gallery/services/remote/lan_tools.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/request_signing.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late Directory photos;
  late Directory documents;
  late NexGalleryServer server;
  late Uri base;
  final clients = <NexGalleryRemoteClient>[];

  NexGalleryRemoteClient newClient() {
    final client = NexGalleryRemoteClient(baseUri: base);
    clients.add(client);
    return client;
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_pairing_');
    photos = await Directory(p.join(workspace.path, 'photos')).create();
    documents = await Directory(p.join(workspace.path, 'documents')).create();
    final image = img.Image(width: 800, height: 600);
    img.fill(image, color: img.ColorRgb8(200, 40, 40));
    await File(p.join(photos.path, 'red.png'))
        .writeAsBytes(img.encodePng(image));
    for (var i = 0; i < 6; i++) {
      await File(p.join(photos.path, 'note-$i.txt')).writeAsString('$i');
    }
    await File(p.join(documents.path, 'secret.txt')).writeAsString('private');
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'photos': photos.path, 'documents': documents.path},
        dataDirectory: Directory(p.join(workspace.path, 'state')),
        port: 0,
        allowWrites: true,
        ownerSecret: 'owner-secret-for-tests',
        serverName: 'Test PC',
      ),
    );
    await server.start();
    base = Uri.parse('http://127.0.0.1:${server.boundPort}');
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    await server.stop(force: true);
    await workspace.delete(recursive: true);
  });

  Future<PendingPairing> waitForRequest() async {
    for (var i = 0; i < 500; i++) {
      if (server.pendingPairings.isNotEmpty) return server.pendingPairings.last;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('No pairing request arrived.');
  }

  Future<NexGalleryRemoteClient> paired({
    Set<String> scopes = DeviceScope.readOnly,
    List<String>? roots,
  }) async {
    final client = newClient();
    final pairing = client.pair(
      code: server.createPairingCode().code,
      deviceName: 'Phone',
      pollInterval: const Duration(milliseconds: 20),
    );
    final request = await waitForRequest();
    await server.approvePairing(
      request.requestId,
      scopes: scopes,
      roots: roots,
    );
    await pairing;
    return client;
  }

  test('new phones wait for owner approval and can be declined', () async {
    final declined = newClient();
    final ticket = await declined.startPairing(
      code: server.createPairingCode().code,
      deviceName: 'Unknown phone',
    );
    expect(ticket, isNotNull);
    expect(declined.isPaired, isFalse);
    expect(await declined.checkPairing(ticket!), isFalse);
    expect(server.pendingPairings.single.deviceName, 'Unknown phone');
    expect(await server.denyPairing(ticket.requestId), isTrue);
    await expectLater(
      declined.checkPairing(ticket),
      throwsA(
        isA<RemoteApiException>().having(
          (e) => e.code,
          'code',
          'pairing_denied',
        ),
      ),
    );
    expect(server.devices, isEmpty);

    final client = await paired(roots: ['photos']);
    expect(client.isPaired, isTrue);
    expect(client.tokenId, isNotNull);
    expect(server.devices.single.publicKey, client.deviceKey!.publicKey);
    expect((await client.roots()).map((root) => root.id), ['photos']);
    final info = await client.info();
    expect(info.name, 'Test PC');
    expect(info.scopes, DeviceScope.readOnly);
  });

  test('scopes and shared-folder limits are enforced', () async {
    final client = await paired(roots: ['photos']);
    await expectLater(
      client.list(root: 'documents'),
      throwsA(
        isA<RemoteApiException>().having((e) => e.code, 'code', 'root_denied'),
      ),
    );
    final source = await File(p.join(workspace.path, 'up.txt'))
        .writeAsString('x');
    await expectLater(
      client.upload(root: 'photos', remotePath: 'up.txt', source: source),
      throwsA(
        isA<RemoteApiException>().having((e) => e.code, 'code', 'scope_denied'),
      ),
    );
    await server.updateDevicePermissions(
      client.tokenId!,
      scopes: {...DeviceScope.readOnly, DeviceScope.organize},
      roots: ['photos'],
    );
    await client.createFolder(root: 'photos', path: 'Trips');
    expect(await Directory(p.join(photos.path, 'Trips')).exists(), isTrue);
    await expectLater(
      client.createFolder(root: 'documents', path: 'Nope'),
      throwsA(
        isA<RemoteApiException>().having((e) => e.code, 'code', 'root_denied'),
      ),
    );

    final page = await client.list(root: 'photos', limit: 3);
    expect(page.map((e) => e.name), ['Trips', 'note-0.txt', 'note-1.txt']);
    final last = await client.list(root: 'photos', offset: 6, limit: 3);
    expect(last.map((e) => e.name), ['note-5.txt', 'red.png']);

    expect(await server.revokeDevice(client.tokenId!), isTrue);
    await expectLater(
      client.roots(),
      throwsA(
        isA<RemoteApiException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
  });

  test('keyed devices must sign; replays and tampering fail', () async {
    final client = await paired();
    final http = HttpClient();
    try {
      Future<int> send(Uri uri, Map<String, String> headers) async {
        final request = await http.getUrl(uri);
        headers.forEach(request.headers.set);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      final bearer = {'authorization': 'Bearer ${client.token}'};
      expect(await send(base.resolve('/v1/roots'), bearer), 401);

      Future<Map<String, String>> signed(
        String path,
        String query, {
        DateTime? at,
        String? nonce,
      }) async {
        final timestamp =
            '${(at ?? DateTime.now()).toUtc().millisecondsSinceEpoch}';
        final once = nonce ?? randomNonce();
        return {
          ...bearer,
          SignedHeaders.device: client.tokenId!,
          SignedHeaders.timestamp: timestamp,
          SignedHeaders.nonce: once,
          SignedHeaders.signature: await client.deviceKey!.sign(
            canonicalRequest(
              method: 'GET',
              path: path,
              query: query,
              timestamp: timestamp,
              nonce: once,
              tokenId: client.tokenId!,
              header: (_) => null,
            ),
          ),
        };
      }

      final headers = await signed('/v1/roots', '');
      expect(await send(base.resolve('/v1/roots'), headers), 200);
      expect(await send(base.resolve('/v1/roots'), headers), 401); // replay
      final forList = await signed('/v1/list', 'root=photos&path=');
      expect(
        await send(base.resolve('/v1/list?root=documents&path='), forList),
        401,
      );
      final stale = await signed(
        '/v1/roots',
        '',
        at: DateTime.now().subtract(const Duration(minutes: 10)),
      );
      expect(await send(base.resolve('/v1/roots'), stale), 401);
    } finally {
      http.close(force: true);
    }
  });

  test('photo previews are resized and cached', () async {
    final client = await paired();
    final entry = (await client.list(root: 'photos'))
        .firstWhere((entry) => entry.name == 'red.png');
    final preview = img.decodeJpg(await client.thumbnail(entry, size: 256))!;
    expect(preview.width, 256);
    expect(preview.height, 192);
    expect(preview.getPixel(10, 10).r, greaterThan(150));
    await client.thumbnail(entry, size: 200);
    final cache = Directory(p.join(workspace.path, 'state', 'thumbnails'));
    expect(cache.listSync().whereType<File>(), hasLength(1));
    final text = (await client.list(root: 'photos'))
        .firstWhere((entry) => entry.name == 'note-0.txt');
    await expectLater(
      client.thumbnail(text),
      throwsA(
        isA<RemoteApiException>().having((e) => e.statusCode, 'status', 415),
      ),
    );
  });

  test('owner endpoints need loopback and the owner secret', () async {
    final http = HttpClient();
    try {
      Future<(int, Object?)> owner(String path, {String? secret}) async {
        final request = await http.getUrl(base.resolve(path));
        if (secret != null) request.headers.set('x-nex-owner', secret);
        final response = await request.close();
        final body = await utf8.decodeStream(response);
        return (response.statusCode, body.isEmpty ? null : jsonDecode(body));
      }

      expect((await owner('/v1/pair/requests')).$1, 403);
      expect((await owner('/v1/pair/requests', secret: 'wrong')).$1, 403);
      final client = await paired();
      final devices = await owner(
        '/v1/tokens',
        secret: 'owner-secret-for-tests',
      );
      expect(devices.$1, 200);
      expect(
        ((devices.$2! as Map)['devices'] as List).single['tokenId'],
        client.tokenId,
      );
      final audit = await owner(
        '/v1/audit?limit=50',
        secret: 'owner-secret-for-tests',
      );
      final actions = ((audit.$2! as Map)['entries'] as List)
          .map((entry) => (entry as Map)['action'])
          .toList();
      expect(actions, contains('pair.approve'));
      expect(actions.first, isNot('server.start')); // newest first
      expect((await server.readAudit(limit: 3)), hasLength(3));
    } finally {
      http.close(force: true);
    }
  });

  test('LAN discovery answers with name, port and fingerprint', () async {
    final port = 40000 + Random().nextInt(20000);
    final lan = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'photos': photos.path},
        dataDirectory: Directory(p.join(workspace.path, 'lan-state')),
        port: 0,
        bindAddresses: [InternetAddress.anyIPv4],
        discoveryPort: port,
        serverName: 'Living room PC',
        certificateFingerprint: 'abcdef0123456789' * 4,
      ),
    );
    await lan.start();
    try {
      final found = await discoverPcs(
        target: InternetAddress.loopbackIPv4,
        port: port,
        timeout: const Duration(milliseconds: 600),
      );
      expect(found.single.name, 'Living room PC');
      expect(found.single.port, lan.boundPort);
      expect(found.single.shortFingerprint, 'ABCD EF01');
    } finally {
      await lan.stop(force: true);
    }
  });

  test('wake-on-LAN packet and legacy token files', () async {
    final packet = magicPacket('AA:BB:CC:DD:EE:0F');
    expect(packet.length, 102);
    expect(packet.take(6), everyElement(0xFF));
    expect(packet.sublist(96), [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x0F]);
    expect(() => magicPacket('nope'), throwsFormatException);

    final legacy = File(p.join(workspace.path, 'legacy', 'tokens.json'));
    await legacy.parent.create();
    await legacy.writeAsString(
      jsonEncode({
        'version': 1,
        'tokens': [
          {
            'deviceId': 'd1',
            'deviceName': 'Old phone',
            'tokenId': 't1',
            'salt': 's',
            'hash': 'h',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        ],
      }),
    );
    final store = DeviceTokenStore(legacy);
    await store.load();
    expect(store.list().single.scopes, DeviceScope.all);
    expect(store.list().single.publicKey, isNull);
  });

  test('replay guard rejects reuse and bad nonces', () {
    final guard = ReplayGuard();
    final now = DateTime.utc(2026, 10, 17, 12);
    final time = '${now.millisecondsSinceEpoch}';
    expect(guard.check('t', time, 'abcdefghijklmnop', now: now), isNull);
    expect(
      guard.check('t', time, 'abcdefghijklmnop', now: now),
      'replayed_request',
    );
    expect(guard.check('u', time, 'abcdefghijklmnop', now: now), isNull);
    expect(guard.check('t', time, 'short', now: now), 'invalid_nonce');
    expect(
      guard.check('t', 'x', 'abcdefghijklmnoq', now: now),
      'invalid_timestamp',
    );
  });
}
