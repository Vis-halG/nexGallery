import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/data/local_media_scanner.dart';
import 'package:nex_gallery/data/sqlite_catalog_persistence.dart';
import 'package:nex_gallery/services/files/recoverable_trash.dart';
import 'package:nex_gallery/src/gallery_model.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';

void main() {
  late Directory workspace;
  late Directory state;
  late Directory media;
  late NexGalleryRuntime runtime;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp(
      'nexgallery_runtime_safety_',
    );
    state = await Directory('${workspace.path}/state').create();
    media = await Directory('${workspace.path}/media').create();
    await File('${media.path}/public.jpg').writeAsBytes(<int>[1, 2, 3]);
    await _seedPreferences(state, media);
    runtime = NexGalleryRuntime(
      platform: TargetPlatform.windows,
      dataDirectory: state.path,
    );
  });

  tearDown(() async {
    runtime.dispose();
    await workspace.delete(recursive: true);
  });

  test(
    'hidden visibility changes preserve favorites and virtual album metadata',
    () async {
      final original = File('${media.path}/.secret.jpg');
      const bytes = <int>[4, 5, 6];
      await original.writeAsBytes(bytes);
      await _seedPreferences(state, media, includeHidden: true);
      await runtime.initialize();
      expect(runtime.items, hasLength(2));
      final secret = runtime.items.singleWhere(
        (item) => item.name == '.secret.jpg',
      );
      await runtime.toggleFavorite(secret);
      await runtime.createAlbum('Private memories');
      final album = runtime.albums.single;
      await runtime.addToAlbum(secret, album.id);

      await runtime.updateSettings(
        runtime.settings.copyWith(includeHiddenFiles: false),
      );
      expect(runtime.items.any((item) => item.id == secret.id), isFalse);
      final hiddenSnapshot = await _snapshot(state);
      expect(
        hiddenSnapshot.items
            .singleWhere((item) => item.id == secret.id)
            .isFavorite,
        isTrue,
      );
      expect(hiddenSnapshot.albums.single.itemIds, contains(secret.id));

      await runtime.updateSettings(
        runtime.settings.copyWith(includeHiddenFiles: true),
      );
      final visible = runtime.items.singleWhere((item) => item.id == secret.id);
      expect(visible.isFavorite, isTrue);
      expect(runtime.albums.single.itemIds, contains(secret.id));
      expect(await original.readAsBytes(), bytes);
    },
  );

  test('forgetting a folder removes catalogue trash and preserves physical recovery', () async {
    await runtime.initialize();
    final item = runtime.items.single;
    await runtime.createAlbum('Family');
    await runtime.addToAlbum(item, runtime.albums.single.id);
    expect(await runtime.moveToTrash(item), isTrue);
    runtime.showCollection(GalleryCollection.trash);
    expect(runtime.items.single.id, item.id);
    final trashed = runtime.items.single;
    final payload = File.fromUri(Uri.parse(trashed.uri));
    final journal = File(trashed.metadata.attributes['trash.journal']!);
    final recoveryRecord = await journal.readAsString();
    expect(await File('${media.path}/public.jpg').exists(), isFalse);

    await runtime.removeWindowsFolder(media.path);
    expect(runtime.windowsFolders, isEmpty);
    expect(runtime.items, isEmpty);
    final snapshot = await _snapshot(state);
    expect(snapshot.items, isEmpty);
    expect(snapshot.albums.single.itemIds, isEmpty);
    expect(await payload.readAsBytes(), <int>[1, 2, 3]);
    expect(await journal.readAsString(), recoveryRecord);
    expect((await _preferences(state)).roots, isEmpty);
    await RecoverableTrash().restore(trashed);
    await RecoverableTrash().finish(trashed);
    expect(await File('${media.path}/public.jpg').readAsBytes(), <int>[
      1,
      2,
      3,
    ]);
  });

  test('failed configuration write retains settings roots and organization', () async {
    await runtime.initialize();
    final originalSettings = runtime.settings.toJson();
    final originalRoots = runtime.windowsFolders;
    final originalItem = runtime.items.single;
    await runtime.toggleFavorite(originalItem);
    await runtime.createAlbum('Protected');
    await runtime.addToAlbum(originalItem, runtime.albums.single.id);
    final before = await File('${state.path}/settings.json').readAsString();
    final extraRoot = await Directory('${workspace.path}/extra').create();
    await File('${extraRoot.path}/extra.jpg').writeAsBytes(<int>[9]);
    // A directory at the backup filename blocks atomic file rotation without
    // depending on platform permission semantics or changing the valid source.
    final backup = File('${state.path}/settings.json.bak');
    if (await backup.exists()) await backup.delete();
    await Directory(backup.path).create();

    await runtime.updateSettings(
      runtime.settings.copyWith(appearance: GalleryAppearance.dark),
    );
    expect(runtime.settings.toJson(), originalSettings);
    expect(runtime.errorMessage, isNotNull);
    await runtime.removeWindowsFolder(media.path);
    expect(runtime.windowsFolders, originalRoots);
    expect(runtime.errorMessage, isNotNull);
    await runtime.addWindowsFolder(extraRoot.path);
    expect(runtime.windowsFolders, originalRoots);
    expect(runtime.errorMessage, isNotNull);
    expect(await File('${state.path}/settings.json').readAsString(), before);
    final snapshot = await _snapshot(state);
    expect(snapshot.items.single.id, originalItem.id);
    expect(snapshot.items.single.isFavorite, isTrue);
    expect(snapshot.albums.single.itemIds, <String>[originalItem.id]);
  });

  test('concurrent settings and video saves retain the final complete configuration', () async {
    await File('${media.path}/clip.mp4').writeAsBytes(<int>[7, 8, 9]);
    await runtime.initialize();
    final video = runtime.items.singleWhere((item) => item.name == 'clip.mp4');
    final dark = runtime.settings.copyWith(appearance: GalleryAppearance.dark);
    final light = runtime.settings.copyWith(
      appearance: GalleryAppearance.light,
    );
    await Future.wait(<Future<void>>[
      runtime.updateSettings(dark),
      runtime.saveVideoPosition(video, const Duration(seconds: 17)),
      runtime.updateSettings(light),
      runtime.saveVideoPosition(video, const Duration(seconds: 29)),
    ]);

    expect(runtime.settings.toJson(), light.toJson());
    expect(await runtime.readVideoPosition(video), const Duration(seconds: 29));
    final preferences = await _preferences(state);
    expect(preferences.settings.toJson(), light.toJson());
    expect(preferences.roots, <String>[media.absolute.path]);
    expect(preferences.videoPositions.values, <int>[29000]);
    expect(runtime.errorMessage, isNull);
  });

  test('selected parent folder cannot index app-private database or settings files', () async {
    await _seedPreferences(state, workspace);
    await runtime.initialize();
    expect(runtime.items.map((item) => item.name), <String>['public.jpg']);
    expect(runtime.items.any((item) => item.uri.contains('/state/')), isFalse);
    expect((await _snapshot(state)).items, hasLength(1));
  });

  test(
    'stale original cannot delete a replacement after physical Trash',
    () async {
      await runtime.initialize();
      final stale = runtime.items.single;
      expect(await runtime.moveToTrash(stale), isTrue);
      runtime.showCollection(GalleryCollection.trash);
      final current = runtime.items.single;
      final payload = File.fromUri(Uri.parse(current.uri));
      final replacement = File.fromUri(Uri.parse(stale.uri));
      const replacementBytes = <int>[99, 98, 97];
      await replacement.writeAsBytes(replacementBytes);

      expect(await runtime.deletePermanently(stale), isFalse);
      expect(await replacement.readAsBytes(), replacementBytes);
      expect(await payload.readAsBytes(), <int>[1, 2, 3]);
      final snapshot = await _snapshot(state);
      expect(snapshot.items.single.uri, current.uri);
      expect(snapshot.items.single.section, MediaSection.trash);
    },
  );

  test(
    'shutdown during an unfinished scan preserves committed organization',
    () async {
      await runtime.initialize();
      final original = runtime.items.single;
      await runtime.toggleFavorite(original);
      await runtime.createAlbum('Preserved');
      await runtime.addToAlbum(original, runtime.albums.single.id);
      final before = await _snapshot(state);
      runtime.dispose();

      final scanner = _GatedScanner();
      runtime = NexGalleryRuntime(
        platform: TargetPlatform.windows,
        dataDirectory: state.path,
        scanner: scanner,
      );
      var notifications = 0;
      runtime.addListener(() => notifications++);
      final opening = runtime.initialize();
      await scanner.started.future;
      runtime.dispose();
      final notificationsAtShutdown = notifications;
      scanner.result.complete(
        ScanResult(
          items: const <MediaItem>[],
          issues: const <ScanIssue>[],
          filesVisited: 0,
          directoriesVisited: 1,
          wasCancelled: false,
          stoppedByLimit: false,
        ),
      );
      await opening;
      expect(notifications, notificationsAtShutdown);
      expect((await _snapshot(state)).toJson(), before.toJson());
      expect(await File('${media.path}/public.jpg').readAsBytes(), <int>[
        1,
        2,
        3,
      ]);
    },
  );
}

Future<void> _seedPreferences(
  Directory state,
  Directory root, {
  bool includeHidden = false,
}) async {
  final store = GalleryPreferencesStore(state.path);
  try {
    await store.save(
      GalleryPreferences(
        settings: GallerySettings(
          autoRefresh: false,
          includeHiddenFiles: includeHidden,
        ),
        roots: <String>[root.absolute.path],
      ),
    );
  } finally {
    await store.close();
  }
}

Future<GalleryPreferences> _preferences(Directory state) async {
  final store = GalleryPreferencesStore(state.path);
  try {
    return await store.load();
  } finally {
    await store.close();
  }
}

Future<CatalogSnapshot> _snapshot(Directory state) async {
  final store = SqliteCatalogPersistence('${state.path}/catalog.sqlite');
  try {
    return await store.load();
  } finally {
    await store.close();
  }
}

final class _GatedScanner implements LocalMediaScanner {
  final started = Completer<void>();
  final result = Completer<ScanResult>();

  @override
  bool get isSupported => true;

  @override
  Future<ScanResult> scan(
    Iterable<String> rootPaths, {
    ScanOptions? options,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}
