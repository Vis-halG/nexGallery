import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/data/windows_files/windows_folder_watcher.dart';

void main() {
  final root = Directory('${Directory.systemTemp.path}/nex-watcher-selected')
      .absolute
      .path;

  test('coalesces bursts and flushes even during continuous changes', () async {
    final harness = _Harness(root);
    await harness.watcher.watchSelectedRoots(<String>[root]);
    for (var index = 0; index < 5; index++) {
      harness.source.add(
        FileSystemCreateEvent('$root/photo-$index.jpg', false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _until(() => harness.changes.isNotEmpty);
    expect(harness.changes, hasLength(1));
    expect(harness.changes.single.roots, <String>{root});
    expect(harness.changes.single.reason, WindowsFolderChangeReason.filesystem);
    expect(harness.changes.single.unavailableRoots, isEmpty);
    await harness.close();
  });

  test('missing drives stay selected and recover after reconnecting', () async {
    final harness = _Harness(root, available: false);
    await harness.watcher.watchSelectedRoots(<String>[root]);
    await _until(() => harness.changes.isNotEmpty);
    expect(harness.changes.single.unavailableRoots, <String>{root});
    expect(harness.attachCount, 0);
    harness.available = true;
    await _until(
      () => harness.changes.any((change) => change.unavailableRoots.isEmpty),
    );
    expect(harness.attachCount, 1);
    expect(harness.changes.last.reason, WindowsFolderChangeReason.availability);
    expect(harness.changes.last.unavailableRoots, isEmpty);
    harness.available = false;
    await _until(() => harness.changes.last.unavailableRoots.isNotEmpty);
    expect(harness.changes.last.unavailableRoots, <String>{root});
    expect(harness.source.hasListener, isFalse);
    await harness.close();
  });

  test(
    'watch errors invalidate and are retried with periodic recovery',
    () async {
      final harness = _Harness(
        root,
        reconciliationInterval: const Duration(milliseconds: 200),
      );
      await harness.watcher.watchSelectedRoots(<String>[root]);
      harness.source.addError(
        const FileSystemException('event buffer overflow'),
      );
      await _until(() => harness.changes.isNotEmpty);
      expect(
        harness.changes.single.reason,
        WindowsFolderChangeReason.watcherError,
      );
      await _until(() => harness.attachCount == 2);
      expect(harness.attachCount, 2);
      await _until(
        () =>
            harness.changes.last.reason ==
            WindowsFolderChangeReason.reconciliation,
      );
      expect(
        harness.changes.last.reason,
        WindowsFolderChangeReason.reconciliation,
      );
      await harness.close();
    },
  );

  test('removed roots stop emitting and dispose cancels callbacks', () async {
    final harness = _Harness(root);
    await harness.watcher.watchSelectedRoots(<String>[root, root, '']);
    expect(harness.attachCount, 1);
    harness.source.add(FileSystemCreateEvent('$root/photo.jpg', false));
    await harness.watcher.watchSelectedRoots(const <String>[]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(harness.changes, isEmpty);
    expect(harness.source.hasListener, isFalse);
    await harness.watcher.watchSelectedRoots(<String>[root]);
    harness.source.add(FileSystemCreateEvent('$root/photo.jpg', false));
    await harness.close();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(harness.changes, isEmpty);
    await harness.watcher.watchSelectedRoots(<String>[root]);
    expect(harness.attachCount, 2);
  });

  test(
    'private writes are excluded while finalized uploads invalidate',
    () async {
      final harness = _Harness(root);
      await harness.watcher.watchSelectedRoots(
        <String>[root],
        ignoredPaths: <String>['$root/app-data'],
      );
      harness.source.add(
        FileSystemModifyEvent('$root/app-data/catalog.sqlite-wal', false, true),
      );
      harness.source.add(
        FileSystemCreateEvent('$root/app-data/settings.json', false),
      );
      harness.source.add(
        FileSystemCreateEvent('$root/incomplete.jpg.part', false),
      );
      harness.source.add(
        FileSystemCreateEvent('$root/.nexgallery-upload/state.json', false),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(harness.changes, isEmpty);
      harness.source.add(
        FileSystemMoveEvent('$root/photo.jpg.part', false, '$root/photo.jpg'),
      );
      await _until(() => harness.changes.isNotEmpty);
      expect(harness.changes, hasLength(1));
      expect(
        harness.changes.single.reason,
        WindowsFolderChangeReason.filesystem,
      );
      await harness.close();
    },
  );

  test(
    'native directory events observe a real temporary-folder change',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'nexgallery_watch_',
      );
      final watcher = WindowsFolderWatcher(
        debounce: const Duration(milliseconds: 20),
        maximumDelay: const Duration(milliseconds: 80),
      );
      try {
        await watcher.watchSelectedRoots(<String>[workspace.path]);
        final changed = watcher.changes.first.timeout(
          const Duration(seconds: 5),
        );
        await File('${workspace.path}/local-only.jpg').writeAsBytes(<int>[1]);
        final event = await changed;
        expect(event.roots, contains(workspace.path));
        expect(event.reason, WindowsFolderChangeReason.filesystem);
      } finally {
        await watcher.dispose();
        await workspace.delete(recursive: true);
      }
    },
  );
}

Future<void> _until(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition()) {
    if (timeout.elapsed > const Duration(seconds: 2)) {
      fail('Watcher condition did not become true within two seconds.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _Harness {
  _Harness(
    String root, {
    this.available = true,
    Duration reconciliationInterval = const Duration(seconds: 2),
  }) {
    watcher = WindowsFolderWatcher(
      debounce: const Duration(milliseconds: 40),
      maximumDelay: const Duration(milliseconds: 100),
      reconciliationInterval: reconciliationInterval,
      availabilityInterval: const Duration(milliseconds: 100),
      exists: (_) async => available,
      watch: (path) {
        expect(path, root);
        attachCount++;
        return source.stream;
      },
    );
    watcher.changes.listen(changes.add);
    addTearDown(close);
  }

  final source = StreamController<FileSystemEvent>.broadcast(sync: true);
  final changes = <WindowsFolderChange>[];
  late final WindowsFolderWatcher watcher;
  bool available;
  int attachCount = 0;

  Future<void> close() async {
    await watcher.dispose();
    await source.close();
  }
}
