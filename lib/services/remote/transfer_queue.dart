import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../files/file_tools.dart';
import 'nex_gallery_client.dart';

enum TransferKind { upload, download }

enum TransferStatus { queued, running, paused, conflict, failed, done, skipped }

/// What to do when an upload's destination already exists on the PC.
enum ConflictPolicy { ask, keepBoth, replace, skip }

final class TransferJob {
  TransferJob({
    required this.id,
    required this.kind,
    required this.name,
    required this.root,
    required this.remotePath,
    required this.createdAt,
    this.localPath,
    this.sourceItemId,
    this.policy = ConflictPolicy.ask,
    this.origin,
    this.status = TransferStatus.queued,
    this.done = 0,
    this.total,
    this.error,
    this.note,
    this.remoteModified,
  });

  factory TransferJob.fromJson(Map<String, dynamic> json) => TransferJob(
    id: json['id'] as String,
    kind: TransferKind.values.byName(json['kind'] as String),
    name: json['name'] as String,
    root: json['root'] as String,
    remotePath: json['remotePath'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    localPath: json['localPath'] as String?,
    sourceItemId: json['sourceItemId'] as String?,
    policy: ConflictPolicy.values.byName(json['policy'] as String? ?? 'ask'),
    origin: json['origin'] as String?,
    // An interrupted run resumes from its saved offset.
    status: switch (TransferStatus.values.byName(json['status'] as String)) {
      TransferStatus.running => TransferStatus.queued,
      final status => status,
    },
    done: json['done'] as int? ?? 0,
    total: json['total'] as int?,
    error: json['error'] as String?,
    note: json['note'] as String?,
    remoteModified: json['remoteModified'] == null
        ? null
        : DateTime.parse(json['remoteModified'] as String),
  );

  final String id;
  final TransferKind kind;
  final String name;
  final String root;
  String remotePath;
  final DateTime createdAt;

  /// Upload source or download destination on this device.
  final String? localPath;

  /// A gallery item copied only when its upload starts (camera backup).
  final String? sourceItemId;
  ConflictPolicy policy;

  /// Free-form tag, for example `camera:<item signature>`.
  final String? origin;
  TransferStatus status;
  int done;
  int? total;
  String? error;

  /// Shown with a finished job, for example a security check on the PC.
  String? note;
  final DateTime? remoteModified;

  bool get isFinished =>
      status == TransferStatus.done || status == TransferStatus.skipped;
  double? get progress =>
      total == null || total == 0 ? null : (done / total!).clamp(0, 1);

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'root': root,
    'remotePath': remotePath,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'localPath': ?localPath,
    'sourceItemId': ?sourceItemId,
    'policy': policy.name,
    'origin': ?origin,
    'status': status.name,
    'done': done,
    'total': ?total,
    'error': ?error,
    'note': ?note,
    if (remoteModified != null)
      'remoteModified': remoteModified!.toUtc().toIso8601String(),
  };
}

enum _Stop { pause, cancel, handoff }

/// Persistent, sequential phone-PC transfers. Jobs survive app restarts and
/// resume from their last confirmed byte.
final class TransferQueue extends ChangeNotifier {
  TransferQueue(
    this.directory, {
    this.networkGate,
    this.resolveSource,
    this.onFinished,
    this.allowedJob,
    this.journalOwner,
    this.download,
    this.retryDelay = const Duration(seconds: 30),
    this.chunkBytes = 4 * 1024 * 1024,
  });

  final Directory directory;

  /// Returns a reason when the current network may not be used.
  final Future<String?> Function()? networkGate;

  /// Copies a gallery item to a readable file for upload. The queue deletes
  /// the copy when the attempt ends.
  final Future<File> Function(TransferJob job)? resolveSource;

  /// Called when a job is done or skipped.
  final void Function(TransferJob job)? onFinished;

  /// Background sessions may process only the categories the owner enabled.
  final bool Function(TransferJob job)? allowedJob;
  final bool Function()? journalOwner;
  bool _ready = false;
  int _mutations = 0;
  Completer<void>? _mutationsIdle;
  bool get canMutate =>
      !_closed &&
      !_handoff &&
      !_writeBlocked &&
      (journalOwner == null || (_ready && journalOwner!()));

  Future<T> _mutate<T>(Future<T> Function() work) {
    if (!canMutate) {
      return Future.error(
        StateError(
          'Transfers are changing ownership. Try again after reconnecting.',
        ),
      );
    }
    _mutations++;
    return Future<T>.sync(work).whenComplete(() {
      if (--_mutations == 0) {
        _mutationsIdle?.complete();
        _mutationsIdle = null;
      }
    });
  }

  /// Include app-private cache edits in the same handoff drain as enqueues.
  Future<T> withOwnership<T>(Future<T> Function() work) => _mutate(work);

  bool canRun(TransferJob job) => allowedJob?.call(job) ?? true;

  /// Optional encrypted destination used by offline copies. Ordinary exports
  /// keep the existing file downloader.
  final Future<void> Function(
    NexGalleryRemoteClient client,
    RemoteEntry entry,
    File destination,
    void Function(int, int?) progress,
  )?
  download;
  final Duration retryDelay;
  final int chunkBytes;

  final _jobs = <TransferJob>[];
  NexGalleryRemoteClient? _client;
  bool _processing = false;
  bool _handoff = false, _closed = false, _writeBlocked = false;
  Completer<void>? _idle;
  TransferJob? _current;
  _Stop? _stop;
  Timer? _retry;
  String? _waitingReason;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  List<TransferJob> get jobs => List.unmodifiable(_jobs);
  String? get waitingReason => _waitingReason;
  bool get isBusy => _processing;
  File get _index => File(p.join(directory.path, 'jobs.json'));

  Directory _jobDirectory(TransferJob job) =>
      Directory(p.join(directory.path, job.id));

  Future<void> load() async {
    if (journalOwner != null && !journalOwner!()) {
      throw StateError('The transfer session does not own the journal.');
    }
    _ready = false;
    try {
      await _load();
      _writeBlocked = false;
      _ready = true;
      _handoff = false;
      notifyListeners();
    } catch (_) {
      _writeBlocked = true;
      rethrow;
    }
  }

  Future<void> _load() async {
    await directory.create(recursive: true);
    final previous = File('${_index.path}.previous');
    if (!await _index.exists() && await previous.exists()) {
      await previous.rename(_index.path);
    }
    if (!await _index.exists()) return;
    if (await _index.length() > 8 << 20) {
      throw const FormatException('The transfer list is too large.');
    }
    final value = jsonDecode(await _index.readAsString());
    if (value is Map &&
        value['version'] is int &&
        (value['version'] as int) > 1) {
      throw UnsupportedError(
        'Transfers were saved by a newer nexGallery build.',
      );
    }
    if (value is! Map || value['version'] != 1) {
      throw const FormatException('Invalid transfer journal.');
    }
    _jobs
      ..clear()
      ..addAll([
        for (final job in value['jobs'] as List)
          TransferJob.fromJson(Map<String, dynamic>.from(job as Map)),
      ]);
    notifyListeners();
  }

  Future<void> _saving = Future<void>.value();

  /// Writes are serialized; a failed write does not block later ones.
  Future<void> _save() {
    final next = _saving.catchError((Object _) {}).then((_) => _write());
    _saving = next;
    return next;
  }

  Future<void> _write() async {
    if (_writeBlocked) {
      throw StateError('Transfer writes are blocked after a failed load.');
    }
    await directory.create(recursive: true);
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'jobs': [for (final job in _jobs) job.toJson()],
      }),
      flush: true,
    );
    final previous = File('${_index.path}.previous');
    if (await previous.exists()) await previous.delete();
    if (await _index.exists()) await _index.rename(previous.path);
    try {
      await temporary.rename(_index.path);
    } catch (_) {
      if (!await _index.exists() && await previous.exists()) {
        await previous.rename(_index.path);
      }
      rethrow;
    }
  }

  void beginHandoff() {
    _handoff = true;
    _client = null;
    _retry?.cancel();
    if (_current != null) _stop ??= _Stop.handoff;
    // A progress listener may initiate handoff. Rebuild after that callback
    // returns instead of recursively entering the same listener.
    scheduleMicrotask(notifyListeners);
  }

  Future<void> flush() async {
    while (_mutations > 0) {
      _mutationsIdle ??= Completer<void>();
      await _mutationsIdle!.future;
    }
    while (_processing) {
      await _idle?.future;
    }
    await _saving;
    _handoff = false;
  }

  Future<void> pruneFinished({int keep = 200}) => _mutate(() async {
    final done = _jobs.where((v) => v.isFinished).toList();
    if (done.length <= keep) return;
    final remove = done.take(done.length - keep).map((v) => v.id).toSet();
    _jobs.removeWhere((v) => remove.contains(v.id));
    await _save();
    notifyListeners();
  });

  @override
  void notifyListeners() {
    if (!_closed) super.notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _client = null;
    _retry?.cancel();
    _stop ??= _Stop.handoff;
    super.dispose();
  }

  /// Connects (or disconnects with null) the PC used for transfers.
  set client(NexGalleryRemoteClient? value) {
    _client = value;
    if (value != null) _kick();
  }

  bool hasJobFor(String origin) => _jobs.any((job) => job.origin == origin);

  Future<TransferJob> enqueueUpload({
    required String name,
    required String root,
    required String remotePath,
    File? source,
    String? sourceItemId,
    bool moveSource = false,
    ConflictPolicy policy = ConflictPolicy.ask,
    String? origin,
  }) => _mutate(() async {
    if ((source == null) == (sourceItemId == null)) {
      throw ArgumentError('Give either a source file or a gallery item.');
    }
    final id = uniqueId();
    final job = TransferJob(
      id: id,
      kind: TransferKind.upload,
      name: safeName(name),
      root: root,
      remotePath: remotePath,
      createdAt: DateTime.now().toUtc(),
      sourceItemId: sourceItemId,
      // Files are staged inside the job so the original may change or
      // disappear without breaking a resumed upload.
      localPath: source == null ? null : p.join(directory.path, id, 'source'),
      policy: policy,
      origin: origin,
    );
    if (source != null) {
      await _jobDirectory(job).create(recursive: true);
      if (moveSource) {
        try {
          await source.rename(job.localPath!);
        } on FileSystemException {
          await source.copy(job.localPath!);
          await source.delete();
        }
      } else {
        await source.copy(job.localPath!);
      }
      job.total = await File(job.localPath!).length();
    }
    _jobs.add(job);
    await _save();
    notifyListeners();
    _kick();
    return job;
  });

  Future<TransferJob> enqueueDownload({
    required RemoteEntry entry,
    required File destination,
    String? origin,
  }) => _mutate(() async {
    final existing = _jobs.where(
      (job) =>
          job.kind == TransferKind.download &&
          job.localPath == destination.path,
    );
    if (existing.isNotEmpty && !existing.first.isFinished) {
      return existing.first;
    }
    final job = TransferJob(
      id: uniqueId(),
      kind: TransferKind.download,
      name: safeName(entry.name),
      root: entry.root,
      remotePath: entry.path,
      createdAt: DateTime.now().toUtc(),
      localPath: destination.path,
      total: entry.size,
      remoteModified: entry.modifiedAt,
      origin: origin,
    );
    _jobs.add(job);
    await _save();
    notifyListeners();
    _kick();
    return job;
  });

  void pause(String id) {
    if (!canMutate) return;
    final job = _find(id);
    if (job == null) return;
    if (identical(job, _current)) {
      _stop = _Stop.pause;
    } else if (job.status == TransferStatus.queued) {
      job.status = TransferStatus.paused;
      unawaited(_save());
      notifyListeners();
    }
  }

  void resume(String id) {
    if (!canMutate) return;
    final job = _find(id);
    if (job == null) return;
    if (job.status == TransferStatus.paused ||
        job.status == TransferStatus.failed) {
      job
        ..status = TransferStatus.queued
        ..error = null;
      unawaited(_save());
      notifyListeners();
      _kick();
    }
  }

  void pauseAll() {
    for (final job in _jobs.where((job) => !job.isFinished)) {
      pause(job.id);
    }
  }

  void resumeAll() {
    for (final job in _jobs) {
      resume(job.id);
    }
  }

  Future<void> cancel(String id) => _mutate(() async {
    final job = _find(id);
    if (job == null) return;
    if (identical(job, _current)) {
      _stop = _Stop.cancel;
      return;
    }
    await _remove(job);
  });

  /// Answers a conflict and requeues the upload.
  void resolveConflict(String id, ConflictPolicy policy) {
    if (!canMutate) return;
    final job = _find(id);
    if (job == null || job.status != TransferStatus.conflict) return;
    job
      ..policy = policy
      ..status = TransferStatus.queued
      ..error = null;
    unawaited(_save());
    notifyListeners();
    _kick();
  }

  Future<void> clearFinished() => _mutate(() async {
    for (final job in _jobs.where((job) => job.isFinished).toList()) {
      await _remove(job);
    }
  });

  Future<void> _remove(TransferJob job) async {
    _jobs.remove(job);
    final folder = _jobDirectory(job);
    if (await folder.exists()) await folder.delete(recursive: true);
    if (job.kind == TransferKind.download && !job.isFinished) {
      final part = File('${job.localPath}.part');
      if (await part.exists()) await part.delete();
    }
    await _save();
    notifyListeners();
  }

  TransferJob? _find(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  void _kick() {
    if (_closed || _processing || _client == null) return;
    _retry?.cancel();
    unawaited(_process());
  }

  Future<void> _process() async {
    _processing = true;
    _idle = Completer<void>();
    notifyListeners();
    try {
      while (true) {
        final client = _client;
        if (client == null) break;
        TransferJob? next;
        for (final job in _jobs) {
          if (job.status == TransferStatus.queued && canRun(job)) {
            next = job;
            break;
          }
        }
        if (next == null) {
          _waitingReason = null;
          break;
        }
        final blocked = await networkGate?.call();
        if (blocked != null) {
          _waitingReason = blocked;
          _retry = Timer(retryDelay, _kick);
          break;
        }
        _waitingReason = null;
        final retry = await _run(client, next);
        if (retry) {
          _retry = Timer(retryDelay, _kick);
          break;
        }
      }
    } finally {
      _processing = false;
      _current = null;
      _idle?.complete();
      notifyListeners();
    }
  }

  void _progress(TransferJob job, int done, int? total) {
    job
      ..done = done
      ..total = total ?? job.total;
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 250)) {
      _lastNotify = now;
      notifyListeners();
    }
    final stop = _stop;
    if (stop != null) throw stop;
  }

  /// Runs one job. Returns true when the network failed and the queue should
  /// retry later.
  Future<bool> _run(NexGalleryRemoteClient client, TransferJob job) async {
    _current = job;
    _stop = null;
    job
      ..status = TransferStatus.running
      ..error = null;
    await _save();
    notifyListeners();
    File? temporary;
    try {
      if (job.kind == TransferKind.upload) {
        final source = job.localPath != null
            ? File(job.localPath!)
            : temporary = await resolveSource!(job);
        job.total = await source.length();
        await _jobDirectory(job).create(recursive: true);
        final result = await client.upload(
          root: job.root,
          remotePath: job.remotePath,
          source: source,
          resumeState: File(p.join(_jobDirectory(job).path, 'resume.json')),
          createParents: true,
          chunkBytes: chunkBytes,
          onProgress: (done, total) => _progress(job, done, total),
        );
        job.note = !result.quarantined
            ? null
            : result.scan == 'held'
            ? 'Held on the PC until its owner releases it.'
            : 'The PC is checking this file for threats.';
      } else {
        final destination = File(job.localPath!);
        final entry = RemoteEntry(
          root: job.root,
          path: job.remotePath,
          name: job.name,
          type: 'file',
          size: job.total,
          modifiedAt: job.remoteModified,
        );
        if (download != null) {
          await download!(
            client,
            entry,
            destination,
            (done, total) => _progress(job, done, total),
          );
        } else if (!await destination.exists()) {
          await client.download(
            entry: entry,
            destination: destination,
            onProgress: (done, total) => _progress(job, done, total),
          );
        }
      }
      job
        ..status = TransferStatus.done
        ..done = job.total ?? job.done;
      final folder = _jobDirectory(job);
      if (await folder.exists()) await folder.delete(recursive: true);
      onFinished?.call(job);
    } on _Stop catch (stop) {
      if (stop == _Stop.cancel) {
        await _remove(job);
        return false;
      }
      job.status = stop == _Stop.handoff
          ? TransferStatus.queued
          : TransferStatus.paused;
    } on RemoteApiException catch (error) {
      if (job.kind == TransferKind.upload &&
          error.code == 'destination_exists') {
        await _handleConflict(client, job);
      } else {
        job
          ..status = TransferStatus.failed
          ..error = error.message;
      }
    } on SocketException catch (error) {
      return _networkFailed(job, error.message);
    } on HttpException catch (error) {
      return _networkFailed(job, error.message);
    } on TimeoutException {
      return _networkFailed(job, 'The PC did not respond.');
    } on HandshakeException {
      job
        ..status = TransferStatus.failed
        ..error = 'The PC certificate does not match. Pair again.';
    } on FileSystemException catch (error) {
      job
        ..status = TransferStatus.failed
        ..error = error.message;
    } on FormatException catch (error) {
      job
        ..status = TransferStatus.failed
        ..error = error.message;
    } catch (_) {
      job
        ..status = TransferStatus.failed
        ..error =
            'Transfer could not be verified. Retry or select the file again.';
    } finally {
      if (_handoff &&
          _stop != _Stop.pause &&
          _stop != _Stop.cancel &&
          !job.isFinished &&
          job.status != TransferStatus.conflict) {
        job
          ..status = TransferStatus.queued
          ..error = null;
      }
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      _current = null;
      if (_jobs.contains(job)) await _save();
      notifyListeners();
    }
    return false;
  }

  bool _networkFailed(TransferJob job, String message) {
    job
      ..status = TransferStatus.queued
      ..error = 'Waiting to reconnect: $message';
    _waitingReason = 'Connection lost. Retrying soon.';
    return true;
  }

  Future<void> _handleConflict(
    NexGalleryRemoteClient client,
    TransferJob job,
  ) async {
    // The resume state belongs to the old destination.
    final resume = File(p.join(_jobDirectory(job).path, 'resume.json'));
    if (await resume.exists()) await resume.delete();
    switch (job.policy) {
      case ConflictPolicy.ask:
        job
          ..status = TransferStatus.conflict
          ..error = 'A file with this name already exists on the PC.';
      case ConflictPolicy.skip:
        job.status = TransferStatus.skipped;
        onFinished?.call(job);
      case ConflictPolicy.keepBoth:
        job
          ..remotePath = alternativeName(job.remotePath)
          ..status = TransferStatus.queued;
      case ConflictPolicy.replace:
        await client.trash(
          RemoteEntry(
            root: job.root,
            path: job.remotePath,
            name: job.name,
            type: 'file',
            modifiedAt: null,
          ),
        );
        job.status = TransferStatus.queued;
    }
  }
}

/// `Trips/photo.jpg` becomes `Trips/photo (2).jpg`, then `(3)`.
String alternativeName(String path) {
  final directory = p.posix.dirname(path);
  final extension = p.posix.extension(path);
  var base = p.posix.basenameWithoutExtension(path);
  var number = 2;
  final match = RegExp(r'^(.*) \((\d+)\)$').firstMatch(base);
  if (match != null) {
    base = match.group(1)!;
    number = int.parse(match.group(2)!) + 1;
  }
  final name = '$base ($number)$extension';
  return directory == '.' ? name : '$directory/$name';
}
