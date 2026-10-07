import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/gallery_settings.dart';

final class GalleryPreferences {
  GalleryPreferences({
    this.settings = const GallerySettings(),
    Iterable<String> roots = const <String>[],
    Map<String, int> videoPositions = const <String, int>{},
  }) : roots = List<String>.unmodifiable(roots),
       videoPositions = Map<String, int>.unmodifiable(videoPositions);

  final GallerySettings settings;
  final List<String> roots;
  final Map<String, int> videoPositions;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'settings': settings.toJson(),
    'roots': roots,
    'videoPositions': videoPositions,
  };

  factory GalleryPreferences.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] is num && (json['schemaVersion'] as num) > 1) {
      throw UnsupportedError(
        'Settings were saved by a newer nexGallery build.',
      );
    }
    if (json['schemaVersion'] != 1) {
      throw const FormatException(
        'Settings schema is not supported by this build.',
      );
    }
    final rawSettings = json['settings'];
    final rawRoots = json['roots'];
    final rawPositions = json['videoPositions'];
    if (rawSettings is! Map ||
        rawRoots is! List ||
        rawRoots.any((root) => root is! String) ||
        rawPositions is! Map ||
        rawPositions.entries.any(
          (entry) =>
              entry.key is! String ||
              entry.value is! int ||
              (entry.value as int) < 0,
        )) {
      throw const FormatException(
        'Invalid settings, folders or video positions.',
      );
    }
    for (final key in <String>['autoRefresh', 'includeHiddenFiles']) {
      if (rawSettings.containsKey(key) && rawSettings[key] is! bool) {
        throw FormatException('Invalid $key setting.');
      }
    }
    if (rawSettings.containsKey('appearance') &&
        !GalleryAppearance.values.any(
          (value) => value.name == rawSettings['appearance'],
        )) {
      throw const FormatException('Invalid appearance setting.');
    }
    return GalleryPreferences(
      settings: GallerySettings.fromJson(
        Map<String, Object?>.from(rawSettings),
      ),
      roots: rawRoots.cast<String>(),
      videoPositions: Map<String, int>.from(rawPositions),
    );
  }
}

/// Serialized replace-and-backup writes. A corrupt/future settings file is never
/// silently replaced with defaults; a valid crash backup can be restored.
final class GalleryPreferencesStore {
  GalleryPreferencesStore(this.directory);
  final String directory;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;
  Object? _blockedError;
  String? recoveredSettingsPath;
  String get _path => '$directory${Platform.pathSeparator}settings.json';

  Future<GalleryPreferences> load() => _enqueue(_loadGuarded);

  Future<GalleryPreferences> _loadGuarded() async {
    try {
      final result = await _loadCurrent();
      _blockedError = null;
      return result;
    } catch (error) {
      _blockedError = error;
      rethrow;
    }
  }

  Future<GalleryPreferences> _loadCurrent() async {
    final target = File(_path);
    final backup = File('$_path.bak');
    if (!await target.exists()) {
      if (await backup.exists()) {
        final recovered = await _read(backup);
        await _restoreBackup(target, backup);
        return recovered;
      }
      final legacy = File('$directory${Platform.pathSeparator}roots.txt');
      final roots = await legacy.exists()
          ? await legacy.readAsLines()
          : <String>[];
      return GalleryPreferences(
        roots: roots
            .map((path) => path.trim())
            .where((path) => path.isNotEmpty),
      );
    }
    try {
      return await _read(target);
    } on FormatException {
      if (await backup.exists()) {
        final recovered = await _read(backup);
        await _restoreBackup(target, backup);
        return recovered;
      }
      rethrow;
    }
  }

  Future<void> _restoreBackup(File target, File backup) async {
    final suffix = '${pid}_${DateTime.now().microsecondsSinceEpoch}';
    final temporary = File('$_path.recovery.$suffix.part');
    File? preserved;
    try {
      await temporary.writeAsBytes(await backup.readAsBytes(), flush: true);
      if (await target.exists()) {
        preserved = await target.rename('$_path.corrupt.$suffix');
        recoveredSettingsPath = preserved.path;
      }
      await temporary.rename(target.path);
    } catch (_) {
      if (!await target.exists() &&
          preserved != null &&
          await preserved.exists()) {
        await preserved.rename(target.path);
        recoveredSettingsPath = null;
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  Future<GalleryPreferences> _read(File file) async {
    if (await file.length() > 1 << 20) {
      throw const FormatException('Settings exceed the safe size limit.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('Invalid settings file.');
    return GalleryPreferences.fromJson(Map<String, Object?>.from(decoded));
  }

  Future<void> save(GalleryPreferences value) => _enqueue(() async {
    if (_blockedError != null) {
      throw StateError(
        'Settings loading failed; disk writes are blocked to preserve data. $_blockedError',
      );
    }
    // Call the private loader in this queue entry to avoid recursively queuing
    // and deadlocking. This also protects a future file before the first load.
    await _loadGuarded();
    GalleryPreferences.fromJson(value.toJson());
    final encoded = utf8.encode(jsonEncode(value.toJson()));
    if (encoded.length > 1 << 20) {
      throw const FormatException('Settings exceed the safe size limit.');
    }
    final target = File(_path);
    final backup = File('$_path.bak');
    await target.parent.create(recursive: true);
    final temporary = File(
      '$_path.${pid}_${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await temporary.writeAsBytes(encoded, flush: true);
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
      }
      await temporary.rename(target.path);
    } catch (_) {
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    if (_closed) {
      return Future<T>.error(StateError('Settings store is closed.'));
    }
    final result = _queue.then((_) => operation());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> close() async {
    _closed = true;
    await _queue;
  }
}
