import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/android_media/android_media_bridge.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';
import 'package:nex_gallery/src/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AndroidFixture fixture;

  setUp(() async => fixture = await _AndroidFixture.create());
  tearDown(() async => fixture.close());

  test(
    'empty and copied identity filters never query unauthorized rows',
    () async {
      final repository = await MediaCatalogRepository.open();
      addTearDown(repository.dispose);
      await repository.upsertAll([_catalogueItem(1), _catalogueItem(2)]);
      final sourceIds = {'android_image_1'};
      final query = CatalogQuery(itemIds: sourceIds);
      sourceIds.add('android_image_2');
      expect(repository.query(query).items.single.id, 'android_image_1');
      expect(
        repository.query(query.copyWith(itemIds: <String>{})).totalCount,
        0,
      );
      expect(repository.query(query.copyWith(itemIds: null)).totalCount, 2);
    },
  );

  test('partial selection hides unauthorized rows and preserves SQLite organization for regrant', () async {
    final album = await fixture.seedOrganization();
    await fixture.runtime.initialize();
    expect(fixture.runtime.totalItemCount, 3);
    expect(
      fixture.runtime.items
          .singleWhere((item) => item.id == 'android_image_2')
          .isFavorite,
      isTrue,
    );
    fixture.permission = 'partial';
    fixture.images = [1];
    fixture.videos = [];
    await fixture.runtime.refresh();
    expect(fixture.runtime.hasLimitedAccess, isTrue);
    expect(fixture.runtime.items.map((item) => item.id), ['android_image_1']);
    expect(fixture.runtime.totalItemCount, 1);
    expect(fixture.runtime.hasMoreItems, isFalse);
    expect(
      fixture.runtime.categories
          .singleWhere((category) => category.kind == MediaKind.image)
          .itemCount,
      1,
    );
    expect(
      fixture.runtime.categories
          .singleWhere((category) => category.kind == MediaKind.image)
          .totalBytes,
      100,
    );
    expect(
      fixture.runtime.categories
          .singleWhere((category) => category.kind == MediaKind.video)
          .itemCount,
      0,
    );
    expect(fixture.runtime.albums.single.itemIds, isEmpty);
    expect(fixture.runtime.albums.single.coverItemId, isNull);
    fixture.runtime.showCollection(GalleryCollection.favorites);
    expect(fixture.runtime.items, isEmpty);
    fixture.runtime.showAlbum(album.id);
    expect(fixture.runtime.items, isEmpty);

    // Inspect the real persisted SQLite state independently of its filtered UI.
    final persisted = await MediaCatalogRepository.open(
      databaseFilePath: fixture.cataloguePath,
    );
    expect(
      persisted.snapshot.items
          .singleWhere((item) => item.id == 'android_image_2')
          .isFavorite,
      isTrue,
    );
    expect(persisted.snapshot.albums.single.itemIds, ['android_image_2']);
    expect(persisted.snapshot.albums.single.coverItemId, 'android_image_2');
    await persisted.dispose();

    fixture.permission = 'full';
    fixture.images = [1, 2];
    fixture.videos = [10];
    fixture.runtime.showCollection(GalleryCollection.timeline);
    await fixture.runtime.refresh();
    expect(fixture.runtime.hasLimitedAccess, isFalse);
    expect(fixture.runtime.totalItemCount, 3);
    expect(
      fixture.runtime.items
          .singleWhere((item) => item.id == 'android_image_2')
          .isFavorite,
      isTrue,
    );
    expect(fixture.runtime.albums.single.itemIds, ['android_image_2']);
    expect(fixture.runtime.albums.single.coverItemId, 'android_image_2');
  });

  test(
    'denied startup and later repository mutations expose no cached metadata',
    () async {
      await fixture.seedOrganization();
      fixture.permission = 'denied';
      final exposures = <List<String>>[];
      fixture.runtime.addListener(
        () => exposures.add(
          fixture.runtime.items.map((item) => item.id).toList(),
        ),
      );
      await fixture.runtime.initialize();
      expect(fixture.runtime.loadState, GalleryLoadState.permissionRequired);
      expect(exposures.every((items) => items.isEmpty), isTrue);
      _expectDenied(fixture.runtime);
      await fixture.runtime.createAlbum('A new local album');
      _expectDenied(fixture.runtime);
      fixture.runtime.showCollection(GalleryCollection.favorites);
      fixture.runtime.setSearchText('private');
      fixture.runtime.loadMoreItems();
      _expectDenied(fixture.runtime);
      expect(fixture.queryCalls, 0);
    },
  );

  test('refresh after permission revoke clears counts and cached rows without deleting SQLite data', () async {
    await fixture.seedOrganization();
    await fixture.runtime.initialize();
    final priorItem = fixture.runtime.items.first;
    fixture.permission = 'denied';
    await fixture.runtime.refresh();
    _expectDenied(fixture.runtime);
    await fixture.runtime.toggleFavorite(priorItem);
    _expectDenied(fixture.runtime);
    final persisted = await MediaCatalogRepository.open(
      databaseFilePath: fixture.cataloguePath,
    );
    expect(persisted.itemCount, 3);
    expect(persisted.snapshot.albums.single.itemIds, ['android_image_2']);
    await persisted.dispose();
    fixture.permission = 'full';
    await fixture.runtime.requestAccessAndRefresh();
    expect(fixture.runtime.loadState, GalleryLoadState.ready);
    expect(fixture.runtime.totalItemCount, 3);
  });

  test('new permission request invalidates a pending scan that observed older access', () async {
    await fixture.runtime.initialize();
    final queryStarted = Completer<void>();
    final queryGate = Completer<Object?>();
    fixture.nextQuery = (call) async {
      queryStarted.complete();
      return queryGate.future;
    };
    final refreshing = fixture.runtime.refresh();
    await queryStarted.future;
    fixture.permission = 'denied';
    await fixture.runtime.requestAccessAndRefresh();
    _expectDenied(fixture.runtime);
    queryGate.complete(fixture.page('image', [1, 2]));
    await refreshing;
    await Future<void>.delayed(Duration.zero);
    _expectDenied(fixture.runtime);
  });

  test('permission refresh requested during scan is queued and observes changed selection', () async {
    await fixture.runtime.initialize();
    final queryStarted = Completer<void>();
    final queryGate = Completer<Object?>();
    fixture.nextQuery = (call) async {
      queryStarted.complete();
      return queryGate.future;
    };
    final refreshing = fixture.runtime.refresh();
    await queryStarted.future;
    fixture.permission = 'partial';
    fixture.images = [1];
    fixture.videos = [];
    // HomeShell calls this on resumed, including when the earlier query is busy.
    await fixture.runtime.refresh();
    queryGate.complete(fixture.page('image', [1, 2]));
    await refreshing;
    await fixture.waitUntilIdle();
    expect(fixture.runtime.hasLimitedAccess, isTrue);
    expect(fixture.runtime.items.map((item) => item.id), ['android_image_1']);
    expect(fixture.runtime.totalItemCount, 1);
  });

  test('mid-scan permission change cannot publish or reconcile an obsolete full snapshot', () async {
    await fixture.seedOrganization();
    await fixture.runtime.initialize();
    fixture.nextQuery = (call) async {
      // Simulate returning a final old cursor page while settings revokes access.
      fixture.permission = 'denied';
      return fixture.page(call.arguments['mediaType'] as String, [1]);
    };
    await fixture.runtime.refresh();
    await fixture.waitUntilIdle();
    _expectDenied(fixture.runtime);
    final persisted = await MediaCatalogRepository.open(
      databaseFilePath: fixture.cataloguePath,
    );
    expect(
      persisted.snapshot.items.any((item) => item.id == 'android_image_2'),
      isTrue,
    );
    expect(persisted.snapshot.albums.single.itemIds, ['android_image_2']);
    await persisted.dispose();
  });

  test('permission query failure stays hidden and initialization retry does not duplicate subscriptions', () async {
    await fixture.seedOrganization();
    fixture.nextPermissionError = PlatformException(
      code: 'permission_query_failed',
    );
    await fixture.runtime.initialize();
    expect(fixture.runtime.loadState, GalleryLoadState.error);
    expect(fixture.runtime.items, isEmpty);
    await fixture.runtime.initialize();
    expect(fixture.runtime.loadState, GalleryLoadState.ready);
    var notifications = 0;
    fixture.runtime.addListener(() => notifications++);
    await fixture.runtime.createAlbum('After retry');
    expect(fixture.runtime.albums, hasLength(2));
    expect(notifications, 1);
  });

  test(
    'single media-kind permission queries only the granted collection',
    () async {
      await fixture.seedOrganization();
      fixture.permission = 'partial';
      fixture.imagePermission = 'granted';
      fixture.videoPermission = 'denied';
      await fixture.runtime.initialize();
      expect(fixture.queriedKinds, ['image']);
      expect(fixture.runtime.totalItemCount, 2);
      expect(
        fixture.runtime.categories
            .singleWhere((category) => category.kind == MediaKind.video)
            .itemCount,
        0,
      );
      final persisted = await MediaCatalogRepository.open(
        databaseFilePath: fixture.cataloguePath,
      );
      expect(
        persisted.snapshot.items.any((item) => item.kind == MediaKind.video),
        isTrue,
      );
      await persisted.dispose();
    },
  );

  testWidgets(
    'Android resumed lifecycle rechecks revoked access even with auto-refresh off',
    (tester) async {
      await tester.runAsync(() async {
        await fixture.runtime.initialize();
        await fixture.runtime.updateSettings(
          fixture.runtime.settings.copyWith(autoRefresh: false),
        );
      });
      await tester.pumpWidget(
        NexGalleryApp(platform: TargetPlatform.android, model: fixture.runtime),
      );
      await tester.pump();
      expect(fixture.runtime.totalItemCount, 3);
      fixture.permission = 'denied';
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.runAsync(fixture.waitUntilIdle);
      await tester.pump();
      _expectDenied(fixture.runtime);
      expect(find.text('private-1.jpg'), findsNothing);
      expect(find.text('private-2.jpg'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  test('unauthorized cached snapshots cannot open, share, mutate or allocate thumbnails', () async {
    final album = await fixture.seedOrganization();
    await fixture.runtime.initialize();
    final first = fixture.runtime.items.singleWhere(
      (item) => item.id == 'android_image_1',
    );
    final favorite = fixture.runtime.items.singleWhere(
      (item) => item.id == 'android_image_2',
    );
    fixture.permission = 'denied';
    await fixture.runtime.refresh();
    expect(fixture.runtime.canAccessMedia(first), isFalse);
    await fixture.runtime.open(first);
    await fixture.runtime.share(first);
    expect(await fixture.runtime.loadThumbnail(first), isNull);
    expect(await fixture.runtime.moveToTrash(first), isFalse);
    expect(await fixture.runtime.restore(first), isFalse);
    expect(await fixture.runtime.deletePermanently(first), isFalse);
    await fixture.runtime.toggleFavorite(favorite);
    await fixture.runtime.archive(first);
    await fixture.runtime.addToAlbum(first, album.id);
    expect(fixture.nativeOperations, isEmpty);
    _expectDenied(fixture.runtime);
    final persisted = await MediaCatalogRepository.open(
      databaseFilePath: fixture.cataloguePath,
    );
    expect(persisted.itemCount, 3);
    expect(
      persisted.snapshot.items
          .singleWhere((item) => item.id == first.id)
          .section,
      MediaSection.library,
    );
    expect(
      persisted.snapshot.items
          .singleWhere((item) => item.id == favorite.id)
          .isFavorite,
      isTrue,
    );
    expect(persisted.snapshot.albums.single.itemIds, ['android_image_2']);
    await persisted.dispose();
  });
}

void _expectDenied(NexGalleryRuntime runtime) {
  expect(runtime.loadState, GalleryLoadState.permissionRequired);
  expect(runtime.items, isEmpty);
  expect(runtime.totalItemCount, 0);
  expect(runtime.hasMoreItems, isFalse);
  expect(runtime.albums, isEmpty);
  expect(runtime.categories, isEmpty);
  expect(runtime.indexedCount, 0);
  expect(runtime.discoveredCount, isNull);
}

class _AndroidFixture {
  _AndroidFixture(this.directory);

  final Directory directory;
  static const channel = MethodChannel('nexgallery/test/android-permissions');
  late final NexGalleryRuntime runtime;
  String permission = 'full';
  String? imagePermission;
  String? videoPermission;
  List<int> images = [1, 2];
  List<int> videos = [10];
  int queryCalls = 0;
  final queriedKinds = <String>[];
  final nativeOperations = <String>[];
  Future<Object?> Function(MethodCall)? nextQuery;
  PlatformException? nextPermissionError;

  String get cataloguePath => '${directory.path}/catalog.sqlite';

  static Future<_AndroidFixture> create() async {
    final fixture = _AndroidFixture(
      await Directory.systemTemp.createTemp('nex-permission-'),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, fixture.handle);
    fixture.runtime = NexGalleryRuntime(
      platform: TargetPlatform.android,
      dataDirectory: fixture.directory.path,
      androidBridge: AndroidMediaBridge(
        channel: channel,
        platform: TargetPlatform.android,
      ),
    );
    return fixture;
  }

  Future<MediaAlbum> seedOrganization() async {
    final repository = await MediaCatalogRepository.open(
      databaseFilePath: cataloguePath,
    );
    await repository.upsertAll([
      _catalogueItem(1),
      _catalogueItem(2),
      _catalogueItem(10, video: true),
    ]);
    await repository.setFavorite('android_image_2', true);
    final album = await repository.createAlbum('Private trip');
    await repository.addToAlbum(album.id, ['android_image_2']);
    await repository.setAlbumCover(album.id, 'android_image_2');
    await repository.dispose();
    return album;
  }

  Map<String, Object?> permissionMap() => {
    'sdkInt': 36,
    'statuses': {
      'image':
          imagePermission ?? (permission == 'full' ? 'granted' : permission),
      'video':
          videoPermission ?? (permission == 'full' ? 'granted' : permission),
    },
    'visualAccess': permission,
    'canOpenSettings': true,
  };

  Map<String, Object?> page(String kind, List<int> ids) => {
    'mediaType': kind,
    'offset': 0,
    'limit': 500,
    'hasMore': false,
    'nextOffset': null,
    'items': [
      for (final id in ids)
        {
          'id': id,
          'uri': 'content://media/external/$kind/media/$id',
          'mediaType': kind,
          'displayName': 'private-$id.${kind == 'video' ? 'mp4' : 'jpg'}',
          'mimeType': kind == 'video' ? 'video/mp4' : 'image/jpeg',
          'size': id * 100,
          'dateModified': 1790908800,
          'dateTaken': 1790908800000,
          'relativePath': 'DCIM/Private/',
        },
    ],
  };

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getPermissionStatus':
      case 'requestPermissions':
        if (nextPermissionError != null) {
          final error = nextPermissionError!;
          nextPermissionError = null;
          throw error;
        }
        return permissionMap();
      case 'queryMedia':
        queryCalls++;
        final kind = call.arguments['mediaType'] as String;
        queriedKinds.add(kind);
        final custom = nextQuery;
        nextQuery = null;
        if (custom != null) return custom(call);
        if (permission == 'denied') {
          throw PlatformException(code: 'permission_denied');
        }
        return page(kind, kind == 'image' ? images : videos);
      case 'getPersistedDirectories':
        return <Object?>[];
      case 'loadThumbnail':
        nativeOperations.add(call.method);
        throw PlatformException(code: 'thumbnail_unavailable');
      default:
        nativeOperations.add(call.method);
        throw MissingPluginException(call.method);
    }
  }

  Future<void> waitUntilIdle() async {
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (!runtime.isIndexing) return;
    }
    fail('Android refresh did not finish.');
  }

  Future<void> close() async {
    runtime.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await directory.delete(recursive: true);
  }
}

MediaItem _catalogueItem(int id, {bool video = false}) => MediaItem(
  id: 'android_${video ? 'video' : 'image'}_$id',
  name: 'private-$id.${video ? 'mp4' : 'jpg'}',
  uri: 'content://media/external/${video ? 'video' : 'image'}/media/$id',
  relativePath: 'DCIM/Private/',
  kind: video ? MediaKind.video : MediaKind.image,
  source: MediaSource.phone,
  metadata: MediaMetadata(
    sizeBytes: id * 100,
    modifiedAt: DateTime.utc(2026, 10, 2),
  ),
  indexedAt: DateTime.utc(2026, 10, 2),
);
