import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/transfer_queue.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  late Directory shared;
  late NexGalleryServer server;
  late NexGalleryRemoteClient client;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_transfers_');
    shared = await Directory(p.join(workspace.path, 'pc')).create();
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'pc': shared.path},
        dataDirectory: Directory(p.join(workspace.path, 'state')),
        port: 0,
        allowWrites: true,
        requireApproval: false,
        maxUploadChunkBytes: 64 * 1024,
      ),
    );
    await server.start();
    client = NexGalleryRemoteClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
    );
    await client.pair(
      code: server.createPairingCode().code,
      deviceName: 'Phone',
    );
  });

  tearDown(() async {
    client.close();
    await server.stop(force: true);
    await workspace.delete(recursive: true);
  });

  Future<File> localFile(String name, String text) async =>
      File(p.join(workspace.path, name)).writeAsString(text);

  Future<void> settle(TransferQueue queue) async {
    for (var i = 0; i < 400; i++) {
      if (!queue.isBusy &&
          queue.jobs.every((job) => job.status != TransferStatus.queued)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Transfers did not finish.');
  }

  TransferQueue newQueue({
    Future<String?> Function()? gate,
    Future<File> Function(TransferJob job)? resolve,
    void Function(TransferJob job)? finished,
    int chunkBytes = 4 * 1024 * 1024,
  }) => TransferQueue(
    Directory(p.join(workspace.path, 'queue')),
    networkGate: gate,
    resolveSource: resolve,
    onFinished: finished,
    retryDelay: const Duration(milliseconds: 50),
    chunkBytes: chunkBytes,
  );

  test(
    'handoff drains an enqueue already staging and rejects stale UI edits',
    () async {
      var owns = true;
      final folder = Directory(p.join(workspace.path, 'ownership-queue'));
      final queue = TransferQueue(folder, journalOwner: () => owns);
      addTearDown(queue.dispose);
      await queue.load();
      final source = await localFile('selected.txt', 'selected media');
      final pending = queue.enqueueUpload(
        name: 'selected.txt',
        root: 'pc',
        remotePath: 'selected.txt',
        source: source,
      );
      queue.beginHandoff();
      owns = false;
      await queue.flush();
      expect(queue.canMutate, isFalse);
      final next = TransferQueue(folder);
      addTearDown(next.dispose);
      await next.load();
      expect(next.jobs, hasLength(1));
      expect(
        await File(next.jobs.single.localPath!).readAsString(),
        'selected media',
      );
      final job = await pending;
      queue.pause(job.id);
      expect(job.status, TransferStatus.queued);
      await expectLater(queue.cancel(job.id), throwsStateError);
      await expectLater(
        queue.enqueueUpload(
          name: 'stale.txt',
          root: 'pc',
          remotePath: 'stale.txt',
          source: source,
        ),
        throwsStateError,
      );
      expect(await source.readAsString(), 'selected media');
      expect(next.jobs.single.id, job.id);
    },
  );

  test('uploads into new folders and reports completion', () async {
    final finished = <String>[];
    final queue = newQueue(finished: (job) => finished.add(job.name));
    final source = await localFile('a.txt', 'hello PC');
    final job = await queue.enqueueUpload(
      name: 'a.txt',
      root: 'pc',
      remotePath: 'Backup/2026-10/a.txt',
      source: source,
    );
    expect(await source.exists(), isTrue, reason: 'copied by default');
    queue.client = client;
    await settle(queue);
    expect(job.status, TransferStatus.done);
    expect(
      await File(p.join(shared.path, 'Backup', '2026-10', 'a.txt'))
          .readAsString(),
      'hello PC',
    );
    expect(finished, ['a.txt']);
    expect(
      await Directory(p.join(workspace.path, 'queue', job.id)).exists(),
      isFalse,
    );
    await queue.clearFinished();
    expect(queue.jobs, isEmpty);
  });

  test('handoff checkpoints an active upload and a fresh queue resumes without unpausing user-paused work', () async {
    final queue = newQueue(chunkBytes: 64 * 1024);
    final source = await File(p.join(workspace.path, 'handoff.bin'))
        .writeAsBytes(List.generate(640 * 1024, (i) => i % 251));
    final active = await queue.enqueueUpload(
      name: 'handoff.bin',
      root: 'pc',
      remotePath: 'handoff.bin',
      source: source,
    );
    final paused = await queue.enqueueUpload(
      name: 'paused.txt',
      root: 'pc',
      remotePath: 'paused.txt',
      source: await localFile('paused.txt', 'paused'),
    );
    queue.pause(paused.id);
    final checkpoint = Completer<void>();
    queue.addListener(() {
      if (!checkpoint.isCompleted &&
          active.status == TransferStatus.running &&
          active.done > 0) {
        queue.beginHandoff();
        checkpoint.complete();
      }
    });
    queue.client = client;
    await checkpoint.future;
    await queue.flush();
    final offset = active.done;
    expect(active.status, TransferStatus.queued);
    expect(paused.status, TransferStatus.paused);
    queue.dispose();
    final next = newQueue(chunkBytes: 64 * 1024);
    await next.load();
    next.client = client;
    await settle(next);
    expect(
      next.jobs.firstWhere((v) => v.id == active.id).status,
      TransferStatus.done,
    );
    expect(
      next.jobs.firstWhere((v) => v.id == paused.id).status,
      TransferStatus.paused,
    );
    expect(offset, greaterThan(0));
    expect(
      await File(p.join(shared.path, 'handoff.bin')).readAsBytes(),
      await source.readAsBytes(),
    );
    await next.flush();
    next.dispose();
  });

  test('a crash between journal rotation and commit recovers all jobs; future schemas are never overwritten', () async {
    final queue = newQueue();
    await queue.enqueueUpload(
      name: 'a.txt',
      root: 'pc',
      remotePath: 'a.txt',
      source: await localFile('a.txt', 'a'),
    );
    await queue.flush();
    queue.dispose();
    final index = File(p.join(workspace.path, 'queue', 'jobs.json'));
    final previous = File('${index.path}.previous');
    if (await previous.exists()) await previous.delete();
    await index.rename(previous.path);
    final recovered = newQueue();
    await recovered.load();
    expect(recovered.jobs.single.name, 'a.txt');
    recovered.dispose();
    await index.writeAsString('{"version":99,"jobs":[]}');
    final future = newQueue();
    await expectLater(future.load(), throwsUnsupportedError);
    await expectLater(
      future.enqueueUpload(
        name: 'b.txt',
        root: 'pc',
        remotePath: 'b.txt',
        source: await localFile('b.txt', 'b'),
      ),
      throwsStateError,
    );
    expect(await index.readAsString(), '{"version":99,"jobs":[]}');
    future.dispose();
  });

  test('conflicts can be asked, kept twice, skipped or replaced', () async {
    await File(p.join(shared.path, 'same.txt')).writeAsString('original');
    final queue = newQueue()..client = client;
    final ask = await queue.enqueueUpload(
      name: 'same.txt',
      root: 'pc',
      remotePath: 'same.txt',
      source: await localFile('one.txt', 'one'),
    );
    await settle(queue);
    expect(ask.status, TransferStatus.conflict);
    queue.resolveConflict(ask.id, ConflictPolicy.keepBoth);
    await settle(queue);
    expect(ask.status, TransferStatus.done);
    expect(
      await File(p.join(shared.path, 'same (2).txt')).readAsString(),
      'one',
    );

    final skip = await queue.enqueueUpload(
      name: 'same.txt',
      root: 'pc',
      remotePath: 'same.txt',
      source: await localFile('two.txt', 'two'),
      policy: ConflictPolicy.skip,
    );
    await settle(queue);
    expect(skip.status, TransferStatus.skipped);

    final replace = await queue.enqueueUpload(
      name: 'same.txt',
      root: 'pc',
      remotePath: 'same.txt',
      source: await localFile('three.txt', 'three'),
      policy: ConflictPolicy.replace,
    );
    await settle(queue);
    expect(replace.status, TransferStatus.done);
    expect(await File(p.join(shared.path, 'same.txt')).readAsString(), 'three');
    final trash = await client.trashEntries('pc');
    expect(trash.single['originalPath'], 'same.txt');
    expect(alternativeName('a/b.jpg'), 'a/b (2).jpg');
    expect(alternativeName('a/b (2).jpg'), 'a/b (3).jpg');
    expect(alternativeName('b'), 'b (2)');
  });

  test('pausing mid-upload resumes without resending finished bytes', () async {
    final queue = newQueue(chunkBytes: 64 * 1024);
    final data = List<int>.generate(640 * 1024, (i) => i % 251);
    final source = await File(p.join(workspace.path, 'big.bin'))
        .writeAsBytes(data);
    final job = await queue.enqueueUpload(
      name: 'big.bin',
      root: 'pc',
      remotePath: 'big.bin',
      source: source,
      moveSource: true,
    );
    expect(await source.exists(), isFalse, reason: 'moved into the job');
    var paused = false;
    queue.addListener(() {
      if (!paused && job.done > 0 && job.status == TransferStatus.running) {
        paused = true;
        queue.pause(job.id);
      }
    });
    queue.client = client;
    await settle(queue);
    expect(job.status, TransferStatus.paused);
    final pausedAt = job.done;
    expect(pausedAt, greaterThan(0));
    expect(pausedAt, lessThan(data.length));
    queue.resume(job.id);
    await settle(queue);
    expect(job.status, TransferStatus.done);
    expect(await File(p.join(shared.path, 'big.bin')).readAsBytes(), data);
  });

  test('Wi-Fi-only policy waits, then continues', () async {
    var blocked = true;
    final queue = newQueue(
      gate: () async => blocked ? 'Waiting for Wi-Fi.' : null,
    );
    final job = await queue.enqueueUpload(
      name: 'w.txt',
      root: 'pc',
      remotePath: 'w.txt',
      source: await localFile('w.txt', 'wifi'),
    );
    queue.client = client;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(job.status, TransferStatus.queued);
    expect(queue.waitingReason, 'Waiting for Wi-Fi.');
    blocked = false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await settle(queue);
    expect(job.status, TransferStatus.done);
    expect(queue.waitingReason, isNull);
  });

  test('downloads, persists jobs and uploads gallery items lazily', () async {
    await File(p.join(shared.path, 'pc.txt')).writeAsString('from PC');
    final entry = (await client.list(root: 'pc')).single;
    final first = newQueue();
    final target = File(p.join(workspace.path, 'offline', 'pc.txt'));
    await first.enqueueDownload(entry: entry, destination: target);
    final temporary = File(p.join(workspace.path, 'materialized.jpg'));
    await first.enqueueUpload(
      name: 'camera.jpg',
      root: 'pc',
      remotePath: 'Camera/camera.jpg',
      sourceItemId: 'android_image_7',
      policy: ConflictPolicy.skip,
      origin: 'camera:android_image_7:1:2',
    );
    expect(first.hasJobFor('camera:android_image_7:1:2'), isTrue);

    final restored = newQueue(
      resolve: (job) async {
        expect(job.sourceItemId, 'android_image_7');
        return temporary.writeAsString('jpeg bytes');
      },
    );
    await restored.load();
    expect(restored.jobs, hasLength(2));
    restored.client = client;
    await settle(restored);
    expect(
      restored.jobs.map((job) => job.status),
      everyElement(TransferStatus.done),
    );
    expect(await target.readAsString(), 'from PC');
    expect(
      await File(p.join(shared.path, 'Camera', 'camera.jpg')).readAsString(),
      'jpeg bytes',
    );
    expect(await temporary.exists(), isFalse, reason: 'copy removed');
  });

  test('cancel removes a queued job and its staged copy', () async {
    final queue = newQueue();
    final job = await queue.enqueueUpload(
      name: 'c.txt',
      root: 'pc',
      remotePath: 'c.txt',
      source: await localFile('c.txt', 'cancel me'),
    );
    expect(await File(job.localPath!).exists(), isTrue);
    await queue.cancel(job.id);
    expect(queue.jobs, isEmpty);
    expect(await File(job.localPath!).exists(), isFalse);
  });
}
