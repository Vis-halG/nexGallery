import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/services/remote/catalog_index.dart';
import 'package:nex_gallery/services/remote/catalog_source.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/path_guard.dart';
import 'package:nex_gallery/services/remote/security.dart';

void main() {
  late Directory workspace, photos, hidden;
  late CatalogSnapshot snapshot;
  late RemoteCatalogIndex index;
  final identity = DeviceIdentity(
    id: 'phone',
    name: 'Phone',
    tokenId: 't',
    createdAt: DateTime.utc(2026),
    roots: ['photos'],
    scopes: DeviceScope.readOnly,
  );
  MediaItem item(int n, Directory root) => MediaItem(
    id: 'local-$n',
    name: 'photo-$n.jpg',
    uri: File('${root.path}/photo-$n.jpg').uri.toString(),
    relativePath: 'photo-$n.jpg',
    kind: MediaKind.image,
    source: MediaSource.pc,
    indexedAt: DateTime.utc(2026),
    metadata: MediaMetadata(
      sizeBytes: 1,
      modifiedAt: DateTime.utc(2026, 1, n + 1),
      attributes: {
        'rootPath': root.path,
        'private.secret': 'must-not-leak',
        'analysis.people': 'Family',
      },
    ),
  );
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_catalog_api_');
    photos = await Directory('${workspace.path}/photos').create();
    hidden = await Directory('${workspace.path}/hidden').create();
    for (var n = 0; n < 6; n++) {
      await File('${(n < 4 ? photos : hidden).path}/photo-$n.jpg')
          .writeAsString('x');
    }
    snapshot = CatalogSnapshot(
      items: [for (var n = 0; n < 6; n++) item(n, n < 4 ? photos : hidden)],
      albums: [
        MediaAlbum(
          id: 'album',
          name: 'Mixed album',
          itemIds: ['local-0', 'local-4'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
      savedAt: DateTime.utc(2026),
    );
    final guard = await PathGuard.create({
      'photos': photos.path,
      'hidden': hidden.path,
    });
    index = RemoteCatalogIndex(
      guard,
      () async => snapshot,
      refreshInterval: Duration.zero,
    );
  });
  tearDown(() => workspace.delete(recursive: true));

  test('background source joins authorized People groups and newly shared roots without exposing face vectors', () async {
    final persistence = SqliteCatalogPersistence(
      '${workspace.path}/catalog.sqlite',
    );
    await persistence.save(snapshot);
    await persistence.close();
    final analysis = await Directory('${workspace.path}/tools/analysis')
        .create(recursive: true);
    await File('${analysis.path}/analysis.json').writeAsString(
      jsonEncode({
        'version': 1,
        'faces': [
          {
            'personId': 'family',
            'itemId': 'local-0',
            'vector': ['private-biometric'],
          },
          {
            'personId': 'private',
            'itemId': 'local-4',
            'vector': ['private-biometric'],
          },
        ],
        'names': {'family': 'Family', 'private': 'Hidden name'},
      }),
    );
    final extra = await Directory('${workspace.path}/new-share').create();
    await File('${extra.path}/new.jpg').writeAsBytes([1]);
    final source = RemoteCatalogSource(workspace, [
      photos.path,
      hidden.path,
      extra.path,
    ]);
    final loaded = await source.load();
    expect(loaded.items.any((v) => v.name == 'new.jpg'), isTrue);
    final joined = RemoteCatalogIndex(
      await PathGuard.create({
        'photos': photos.path,
        'hidden': hidden.path,
        'extra': extra.path,
      }),
      source.load,
    );
    final people = await joined.page('person', {}, identity);
    expect((people['items'] as List).single['name'], 'Family');
    expect((people['items'] as List).single['count'], 1);
    expect(jsonEncode(people), isNot(contains('private-biometric')));
    expect(jsonEncode(people), isNot(contains('Hidden name')));
  });

  test(
    'canonical folder aliases retain catalogue albums and metadata',
    () async {
      final alias = Link('${workspace.path}/alias');
      await alias.create(photos.path);
      snapshot = CatalogSnapshot(
        items: [item(0, Directory(alias.path))],
        albums: snapshot.albums,
        savedAt: snapshot.savedAt,
      );
      final page = await index.page('item', {}, identity);
      expect((page['items'] as List).single['name'], 'photo-0.jpg');
      final albums = await index.page('album', {}, identity);
      expect((albums['items'] as List).single['name'], 'Mixed album');
    },
    skip: Platform.isWindows,
  ); // Windows short-path case runs in compiled smoke.

  test('timeline cursors have no duplicates and sanitize private paths and attributes', () async {
    final first = await index.page('item', {'limit': '2'}, identity);
    final second = await index.page('item', {
      'limit': '2',
      'cursor': first['nextCursor'] as String,
    }, identity);
    final rows = [...first['items'] as List, ...second['items'] as List];
    expect(rows.map((v) => v['id']).toSet(), hasLength(4));
    expect(second['nextCursor'], isNull);
    final encoded = jsonEncode(rows);
    expect(encoded, isNot(contains(workspace.path.replaceAll('\\', '\\\\'))));
    expect(encoded, isNot(contains('must-not-leak')));
    expect(encoded, isNot(contains('photo-4')));
    expect(rows.first['name'], 'photo-3.jpg');
    final other = DeviceIdentity(
      id: 'other',
      name: 'other',
      tokenId: '2',
      createdAt: DateTime.utc(2026),
    );
    await expectLater(
      index.page('item', {
        'limit': '2',
        'cursor': first['nextCursor'] as String,
      }, other),
      throwsA(isA<CatalogApiException>()),
    );
    await expectLater(
      index.page('item', {
        'limit': '1',
        'cursor': first['nextCursor'] as String,
      }, identity),
      throwsA(isA<CatalogApiException>()),
    );
  });

  test('album and people counts and covers exclude unshared media', () async {
    final albums = await index.page('album', {}, identity);
    final album = (albums['items'] as List).single as Map;
    expect(album['count'], 1);
    expect(album['cover']['root'], 'photos');
    expect(album.containsKey('itemIds'), isFalse);
    final page = await index.page('item', {'album': 'album'}, identity);
    expect((page['items'] as List).single['name'], 'photo-0.jpg');
    final people = await index.page('person', {}, identity);
    expect((people['items'] as List).single['count'], 4);
  });

  test('delta reports deletions, favorites and album visibility loss; stale cursors force resync', () async {
    final first = await index.page('item', {'limit': '2'}, identity);
    snapshot = CatalogSnapshot(
      items: [item(1, photos).copyWith(isFavorite: true), item(4, hidden)],
      albums: [
        MediaAlbum(
          id: 'album',
          name: 'Mixed album',
          itemIds: ['local-4'],
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ],
      savedAt: DateTime.utc(2026),
    );
    final changes = await index.changes({
      'since': first['changeToken'] as String,
    }, identity);
    final rows = changes['changes'] as List;
    expect(
      rows.any((v) => v['deleted'] == true && v['entity'] == 'album'),
      isTrue,
    );
    expect(
      rows.any((v) => v['deleted'] == false && v['value']['favorite'] == true),
      isTrue,
    );
    expect(
      rows.where((v) => v['deleted'] == true && v['entity'] == 'item'),
      hasLength(3),
    );
    await expectLater(
      index.page('item', {
        'limit': '2',
        'cursor': first['nextCursor'] as String,
      }, identity),
      throwsA(isA<CatalogApiException>()),
    );
    expect(
      (await index.changes({
        'since': changes['changeToken'] as String,
      }, identity))['changes'],
      isEmpty,
    );
  });

  test('tampered, restarted and expired journal tokens fail closed', () async {
    final first = await index.page('item', {}, identity);
    final token = first['changeToken'] as String;
    await expectLater(
      index.changes({'since': '${token}x'}, identity),
      throwsA(isA<CatalogApiException>()),
    );
    final guard = await PathGuard.create({'photos': photos.path});
    final restarted = RemoteCatalogIndex(
      guard,
      () async => snapshot,
      refreshInterval: Duration.zero,
    );
    await expectLater(
      restarted.changes({'since': token}, identity),
      throwsA(isA<CatalogApiException>()),
    );
    final shortHistory = RemoteCatalogIndex(
      guard,
      () async => snapshot,
      refreshInterval: Duration.zero,
      journalLimit: 1,
    );
    final old = await shortHistory.page('item', {}, identity);
    snapshot = CatalogSnapshot.empty();
    await expectLater(
      shortHistory.changes({'since': old['changeToken'] as String}, identity),
      throwsA(isA<CatalogApiException>()),
    );
  });

  test('real HTTP client catalogue routes require browse permission and enforce root restrictions', () async {
    final server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'photos': photos.path, 'hidden': hidden.path},
        dataDirectory: Directory('${workspace.path}/server'),
        port: 0,
        discoveryPort: 0,
        catalogLoader: () async => snapshot,
      ),
    );
    await server.start();
    final client = NexGalleryRemoteClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
    );
    try {
      await expectLater(client.catalog(), throwsA(isA<RemoteApiException>()));
      final ticket = await client.startPairing(
        code: server.createPairingCode().code,
        deviceName: 'test',
      );
      await server.approvePairing(
        ticket!.requestId,
        roots: ['photos'],
        scopes: DeviceScope.readOnly,
      );
      await client.checkPairing(ticket);
      expect((await client.catalog()).total, 4);
      await expectLater(
        client.catalog(root: 'hidden'),
        throwsA(
          isA<RemoteApiException>().having((v) => v.statusCode, 'status', 403),
        ),
      );
      final device = server.devices.single;
      await server.updateDevicePermissions(
        device.tokenId,
        scopes: {DeviceScope.download},
        roots: ['photos'],
      );
      await expectLater(
        client.catalog(),
        throwsA(
          isA<RemoteApiException>().having((v) => v.statusCode, 'status', 403),
        ),
      );
    } finally {
      client.close();
      await server.stop(force: true);
    }
  });
}
