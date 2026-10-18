import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/catalog_persistence.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';
import 'package:nex_gallery/data/windows_files/file_identity.dart';
import 'package:nex_gallery/services/intelligence/local_analysis.dart';
import 'package:nex_gallery/src/gallery_runtime.dart';
import 'package:path/path.dart' as p;

MediaItem _item(
  String id,
  String name, {
  int size = 10,
  DateTime? modified,
  String? identity,
}) => MediaItem(
  id: id,
  name: name,
  uri: 'file:///$name',
  relativePath: name,
  kind: MediaKind.image,
  source: MediaSource.pc,
  metadata: MediaMetadata(
    sizeBytes: size,
    modifiedAt: modified ?? DateTime.utc(2026, 1, 1),
    attributes: {'fileIdentity': ?identity},
  ),
  indexedAt: DateTime.utc(2026),
);

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_file_identity_');
  });
  tearDown(() => workspace.delete(recursive: true));

  test('Windows file identity survives rename and move on one drive', () async {
    final file = File(p.join(workspace.path, 'a.jpg'));
    await file.writeAsString('pixels');
    final before = windowsFileIdentity(file.path);
    expect(before, matches(RegExp(r'^winfile_[0-9a-f]{16}_[0-9a-f]{32}_')));

    final folder = await Directory(p.join(workspace.path, 'Trips')).create();
    final moved = await file.rename(p.join(folder.path, 'renamed.jpg'));
    expect(windowsFileIdentity(moved.path), before);

    final other = File(p.join(workspace.path, 'b.jpg'));
    await other.writeAsString('pixels');
    expect(windowsFileIdentity(other.path), isNot(before));
    expect(windowsFileIdentity(folder.path), isNull);
    expect(windowsFileIdentity(p.join(workspace.path, 'missing')), isNull);
  }, skip: !Platform.isWindows);

  group('repository reconciliation', () {
    late MediaCatalogRepository repository;

    setUp(() async {
      repository = await MediaCatalogRepository.open(
        persistence: InMemoryCatalogPersistence(),
      );
      await repository.synchronizeSource(MediaSource.pc, [
        _item('old', 'beach.jpg', identity: 'winfile_1_aa_1'),
        _item('other', 'city.jpg'),
      ]);
      await repository.setFavorite('old', true);
      final album = await repository.createAlbum('Trip');
      await repository.addToAlbum(album.id, ['old', 'other']);
      await repository.setAlbumCover(album.id, 'old');
    });
    tearDown(() => repository.dispose());

    test('a renamed file keeps its favorite, albums and cover', () async {
      await repository.synchronizeSource(MediaSource.pc, [
        _item('new', 'Beach day.jpg', identity: 'winfile_1_aa_1'),
        _item('other', 'city.jpg'),
      ]);
      expect(repository.itemById('old'), isNull);
      final moved = repository.itemById('new')!;
      expect(moved.isFavorite, isTrue);
      expect(
        moved.metadata.attributes[MediaCatalogRepository.movedFromAttribute],
        'old',
      );
      final album = repository.snapshot.albums.single;
      expect(album.itemIds, ['new', 'other']);
      expect(album.coverItemId, 'new');
    });

    test(
      'a different file with a recycled ID but another size is new',
      () async {
        await repository.synchronizeSource(MediaSource.pc, [
          _item('new', 'beach.jpg', identity: 'winfile_1_aa_1', size: 99),
          _item('other', 'city.jpg'),
        ]);
        expect(repository.itemById('new')!.isFavorite, isFalse);
        expect(repository.snapshot.albums.single.itemIds, ['other']);
      },
    );

    test('a move to another drive matches name, size and time', () async {
      await repository.synchronizeSource(MediaSource.pc, [
        // Copying to another drive gives the file a new ID.
        _item('usb', 'Beach.JPG', identity: 'winfile_2_bb_2'),
        _item('other', 'city.jpg'),
      ]);
      expect(repository.itemById('usb')!.isFavorite, isTrue);
      expect(repository.snapshot.albums.single.itemIds, contains('usb'));
    });

    test(
      'two candidates with the same name and size are not guessed',
      () async {
        await repository.synchronizeSource(MediaSource.pc, [
          _item('copy1', 'beach.jpg'),
          _item('copy2', 'beach.jpg'),
          _item('other', 'city.jpg'),
        ]);
        expect(repository.itemById('copy1')!.isFavorite, isFalse);
        expect(repository.itemById('copy2')!.isFavorite, isFalse);
      },
    );

    test(
      'an incomplete scan copies organization and keeps the original',
      () async {
        await repository.synchronizeSource(MediaSource.pc, [
          _item('link', 'beach-link.jpg', identity: 'winfile_1_aa_1'),
        ], removeMissing: false);
        expect(repository.itemById('old')!.isFavorite, isTrue);
        expect(repository.itemById('link')!.isFavorite, isTrue);
        expect(
          repository.snapshot.albums.single.itemIds,
          containsAll(['old', 'link', 'other']),
        );
      },
    );
  });

  test(
    'the Windows gallery keeps albums and faces when a photo is renamed',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final root = await Directory(p.join(workspace.path, 'pics')).create();
      final original = File(p.join(root.path, 'IMG_0001.jpg'));
      await original.writeAsBytes(
        img.encodeJpg(img.Image(width: 8, height: 8)),
      );
      final state = await Directory(p.join(workspace.path, 'state')).create();
      final store = GalleryPreferencesStore(state.path);
      await store.save(GalleryPreferences(roots: [root.path]));
      await store.close();
      final runtime = NexGalleryRuntime(
        platform: TargetPlatform.windows,
        dataDirectory: state.path,
      );
      addTearDown(runtime.dispose);
      await runtime.initialize();
      final photo = runtime.localItems.single;
      await runtime.toggleFavorite(photo);
      await runtime.createAlbum('Family');
      await runtime.addToAlbum(photo, runtime.albums.single.id);
      final analysis = LocalAnalysis(
        Directory(p.join(state.path, 'analysis')),
        runtime,
        runtime,
      );
      analysis.faces.add(
        LocalFace(
          id: 'face',
          itemId: photo.id,
          personId: 'mum',
          vector: const [1, 0],
          bounds: const [0, 0, 1, 1],
        ),
      );
      analysis.signatures[photo.id] = '${photo.id}:sig';

      final folder = await Directory(p.join(root.path, 'Birthday')).create();
      await original.rename(p.join(folder.path, 'Mum birthday.jpg'));
      await runtime.refresh();

      final renamed = runtime.localItems.single;
      expect(renamed.id, isNot(photo.id));
      expect(renamed.name, 'Mum birthday.jpg');
      expect(renamed.isFavorite, isTrue);
      expect(runtime.albums.single.itemIds, [renamed.id]);
      expect(analysis.adoptMovedItems(), isTrue);
      expect(analysis.faces.single.itemId, renamed.id);
      expect(analysis.signatures[renamed.id], '${renamed.id}:sig');
      expect(analysis.adoptMovedItems(), isFalse);
    },
    skip: !Platform.isWindows,
  );
}
