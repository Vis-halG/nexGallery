import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/catalog_models.dart';
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/data/catalog_persistence.dart';
import 'package:nex_gallery/data/media_catalog_repository.dart';

void main() {
  test('failed favorite persistence rolls back and emits no change', () async {
    final persistence = _ControlledPersistence();
    final repository = await MediaCatalogRepository.open(
      persistence: persistence,
    );
    final emitted = <CatalogSnapshot>[];
    final subscription = repository.changes.listen(emitted.add);
    try {
      await repository.upsert(_item('photo'));
      await Future<void>.delayed(Duration.zero);
      emitted.clear();
      persistence.failNext = true;
      await expectLater(
        repository.setFavorite('photo', true),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(repository.itemById('photo')!.isFavorite, isFalse);
      expect(persistence.snapshot.items.single.isFavorite, isFalse);
      expect(emitted, isEmpty);
    } finally {
      await subscription.cancel();
      await repository.dispose();
    }
  });

  test(
    'failed permanent deletion restores item membership and album cover',
    () async {
      final persistence = _ControlledPersistence();
      final repository = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      try {
        await repository.upsert(_item('photo'));
        await repository.createAlbum('Family', id: 'family');
        await repository.addToAlbum('family', <String>['photo']);
        await repository.setAlbumCover('family', 'photo');
        final previousItem = repository.itemById('photo')!.toJson();
        final previousAlbum = repository.albumById('family')!.toJson();
        persistence.failNext = true;
        await expectLater(
          repository.deletePermanently('photo'),
          throwsStateError,
        );
        expect(repository.itemById('photo')!.toJson(), previousItem);
        expect(repository.albumById('family')!.toJson(), previousAlbum);
        expect(persistence.snapshot.albums.single.toJson(), previousAlbum);
      } finally {
        await repository.dispose();
      }
    },
  );

  test(
    'failure halfway through a batch rolls back already changed items',
    () async {
      final persistence = _ControlledPersistence();
      final repository = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      try {
        await repository.upsert(_item('original'));
        await expectLater(
          repository.upsertAll(_brokenBatch()),
          throwsStateError,
        );
        expect(repository.itemCount, 1);
        expect(repository.itemById('original'), isNotNull);
        expect(repository.itemById('partial'), isNull);
        expect(persistence.snapshot.items.single.id, 'original');
      } finally {
        await repository.dispose();
      }
    },
  );

  test(
    'a queued mutation succeeds against restored state after failure',
    () async {
      final persistence = _ControlledPersistence();
      final repository = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      try {
        await repository.upsert(_item('photo'));
        persistence.failNext = true;
        final failed = repository.setFavorite('photo', true);
        final succeeding = repository.moveToArchive('photo');
        await expectLater(failed, throwsStateError);
        await succeeding;
        expect(repository.itemById('photo')!.isFavorite, isFalse);
        expect(repository.itemById('photo')!.section, MediaSection.archive);
        expect(persistence.snapshot.items.single.section, MediaSection.archive);
        expect(persistence.snapshot.items.single.isFavorite, isFalse);
      } finally {
        await repository.dispose();
      }
    },
  );

  test(
    'dispose waits for queued persistence and closes it exactly once',
    () async {
      final persistence = _ControlledPersistence();
      final repository = await MediaCatalogRepository.open(
        persistence: persistence,
      );
      persistence.gate = Completer<void>();
      final writing = repository.upsert(_item('photo'));
      await persistence.writeStarted.future;
      final disposing = repository.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(persistence.closeCount, 0);
      await expectLater(repository.upsert(_item('late')), throwsStateError);
      persistence.gate!.complete();
      await Future.wait(<Future<void>>[writing, disposing]);
      await repository.dispose();
      expect(persistence.closeCount, 1);
      expect(persistence.snapshot.items.single.id, 'photo');
    },
  );
}

Iterable<MediaItem> _brokenBatch() sync* {
  yield _item('partial');
  throw StateError('Injected iteration failure.');
}

MediaItem _item(String id) => MediaItem(
  id: id,
  name: '$id.jpg',
  uri: 'file:///Pictures/$id.jpg',
  relativePath: 'Pictures/$id.jpg',
  kind: MediaKind.image,
  source: MediaSource.pc,
  indexedAt: DateTime.utc(2026, 10, 2),
  metadata: MediaMetadata(sizeBytes: 42, modifiedAt: DateTime.utc(2026, 10, 2)),
);

final class _ControlledPersistence implements CloseableCatalogPersistence {
  CatalogSnapshot snapshot = CatalogSnapshot.empty();
  bool failNext = false;
  int closeCount = 0;
  Completer<void>? gate;
  final writeStarted = Completer<void>();

  @override
  Future<CatalogSnapshot> load() async => snapshot;

  @override
  Future<void> save(CatalogSnapshot value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('Injected disk write failure.');
    }
    snapshot = value;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}
