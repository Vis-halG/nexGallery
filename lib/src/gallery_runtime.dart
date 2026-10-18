import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import '../core/gallery_settings.dart';
import '../data/android_media/android_media_bridge.dart';
import '../data/device/device_bridge.dart';
import '../data/local_media_scanner.dart';
import '../data/media_catalog_repository.dart';
import '../data/gallery_preferences_store.dart';
import '../data/windows_files/windows_folder_watcher.dart';
import 'gallery_model.dart';
import 'gallery_organizer.dart';
import 'gallery_tools.dart';
import '../services/files/recoverable_trash.dart';
import '../services/files/file_tools.dart';
import '../services/organization/memories.dart';
import '../services/organization/organization_backup.dart';

import 'package:path/path.dart' as p;

final class NexGalleryRuntime extends ChangeNotifier
    implements GalleryModel, GalleryTools, GalleryOrganizer {
  NexGalleryRuntime({
    TargetPlatform? platform,
    LocalMediaScanner? scanner,
    AndroidMediaBridge? androidBridge,
    DeviceBridge? deviceBridge,
    WindowsFolderWatcher? folderWatcher,
    this.dataDirectory,
    int pageSize = 120,
  }) : assert(pageSize > 0 && pageSize <= 500),
       _platform = platform ?? defaultTargetPlatform,
       _scanner = scanner ?? createLocalMediaScanner(),
       _android = androidBridge ?? AndroidMediaBridge.instance,
       _device = deviceBridge ?? DeviceBridge.instance,
       _folderWatcher = folderWatcher ?? WindowsFolderWatcher(),
       _pageSize = pageSize;

  final TargetPlatform _platform;
  final AndroidMediaBridge _android;
  final DeviceBridge _device;
  final WindowsFolderWatcher _folderWatcher;
  final LocalMediaScanner _scanner;
  final int _pageSize;

  /// Overrides the app-private storage location for isolated validation.
  final String? dataDirectory;

  MediaCatalogRepository? _repository;
  StreamSubscription<CatalogSnapshot>? _repositorySubscription;
  StreamSubscription<WindowsFolderChange>? _folderSubscription;
  GalleryPreferencesStore? _preferencesStore;
  GallerySettings _settings = const GallerySettings();
  final _videoPositions = <String, int>{};
  Set<String> _visiblePhoneIds = <String>{};
  Set<String> _visiblePcIds = <String>{};
  Future<void> _configurationQueue = Future<void>.value();
  bool _refreshQueued = false;
  int _scanGeneration = 0;
  int _permissionGeneration = 0;
  ScanCancellationToken? _scanCancellation;
  final List<String> _windowsRoots = <String>[];
  Set<MediaKind> _kinds = <MediaKind>{};
  String? _dataDirectory;
  String? _albumId;
  CatalogSortField _sortField = CatalogSortField.takenAt;
  CatalogSortDirection _sortDirection = CatalogSortDirection.descending;
  bool _disposed = false;
  bool _initialized = false;

  GalleryLoadState _loadState = GalleryLoadState.starting;
  GalleryCollection _collection = GalleryCollection.timeline;
  String _searchText = '';
  String? _statusMessage;
  String? _errorMessage;
  bool _hasLimitedAccess = false;
  bool _isIndexing = false;
  int _indexedCount = 0;
  int? _discoveredCount;
  List<MediaItem> _items = const <MediaItem>[];
  int _totalItemCount = 0;
  List<MediaAlbum> _albums = const <MediaAlbum>[];
  List<CategorySummary> _categories = const <CategorySummary>[];

  @override
  GalleryLoadState get loadState => _loadState;
  @override
  GalleryCollection get collection => _collection;
  @override
  String get searchText => _searchText;
  @override
  String? get statusMessage => _statusMessage;
  @override
  String? get errorMessage => _errorMessage;
  @override
  bool get hasLimitedAccess => _hasLimitedAccess;
  @override
  bool get isIndexing => _isIndexing;
  @override
  int get indexedCount => _indexedCount;
  @override
  int? get discoveredCount => _discoveredCount;
  @override
  List<MediaItem> get items => _items;
  @override
  int get totalItemCount => _totalItemCount;
  @override
  bool get hasMoreItems => _items.length < _totalItemCount;
  @override
  List<MediaAlbum> get albums => _albums;
  @override
  List<CategorySummary> get categories => _categories;
  @override
  GallerySettings get settings => _settings;
  @override
  List<String> get windowsFolders => List<String>.unmodifiable(_windowsRoots);

  bool get isWindows => _platform == TargetPlatform.windows;
  bool get isAndroid => _platform == TargetPlatform.android;

  @override
  List<MediaItem> get localItems => List.unmodifiable(
    _repository?.snapshot.items.where((item) => canAccessMedia(item)) ??
        const <MediaItem>[],
  );

  @override
  Future<Directory> toolsDirectory() async {
    if (_dataDirectory == null) {
      throw StateError('The library is still opening.');
    }
    final directory = Directory(p.join(_dataDirectory!, 'tools'));
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<File> materialize(MediaItem item) async {
    if (!canAccessMedia(item) || item.section == MediaSection.trash) {
      throw StateError('This original is unavailable.');
    }
    if (isAndroid) {
      final cached = await _android.copyDocumentToAppCache(Uri.parse(item.uri));
      if (!canAccessMedia(item)) {
        final file = File(cached.path);
        if (await file.exists()) await file.delete();
        throw StateError('Access to the original has changed.');
      }
      return File(cached.path);
    }
    return _fileForItem(item);
  }

  @override
  Future<String> saveEditedCopy(MediaItem original, Uint8List bytes) async {
    if (!canAccessMedia(original)) {
      throw StateError('Access to the original has changed.');
    }
    final name =
        '${p.basenameWithoutExtension(original.name)}-edited-${uniqueId().substring(0, 8)}.png';
    if (isAndroid) {
      final staged = File(p.join((await toolsDirectory()).path, name));
      try {
        await staged.writeAsBytes(bytes, flush: true);
        final result = await _android.exportAppMedia(
          staged.path,
          name: name,
          mimeType: 'image/png',
        );
        await refresh();
        return result;
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    }
    final target = File(
      p.join(_fileForItem(original).parent.path, safeName(name)),
    );
    if (await target.exists()) {
      throw const FileSystemException('Edited destination exists.');
    }
    await target.writeAsBytes(bytes, flush: true);
    await refresh();
    return target.path;
  }

  @override
  Future<String> saveVideoCopy(MediaItem original, File edited) async {
    if (!canAccessMedia(original)) {
      throw StateError('Access to the original has changed.');
    }
    final name =
        '${p.basenameWithoutExtension(original.name)}-edited-${uniqueId().substring(0, 8)}.mp4';
    if (isAndroid) {
      final uri = await _android.exportAppMedia(
        edited.path,
        name: name,
        mimeType: 'video/mp4',
      );
      await refresh();
      return uri;
    }
    final target = p.join(_fileForItem(original).parent.path, safeName(name));
    await FileTools().copy(edited.path, target);
    await refresh();
    return target;
  }

  @override
  Future<void> annotate(MediaItem item, MediaMetadata metadata) async {
    final current = _repository?.itemById(item.id);
    if (current != null && canAccessMedia(current)) {
      await _repository!.upsert(
        current.copyWith(metadata: withUserOverrides(metadata)),
        preserveUserState: false,
      );
    }
  }

  @override
  Future<void> annotateAll(
    Map<String, MediaMetadata Function(MediaMetadata)> updates,
  ) async {
    final repository = _repository;
    if (repository == null || updates.isEmpty) return;
    await repository.updateItems(
      updates.keys.where((id) {
        final item = repository.itemById(id);
        return item != null && canAccessMedia(item);
      }).toList(),
      (item) => item.copyWith(
        metadata: withUserOverrides(updates[item.id]!(item.metadata)),
      ),
    );
  }

  @override
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    try {
      _dataDirectory ??= dataDirectory ?? await _resolveDataDirectory();
      if (_disposed) return;
      final opened = await MediaCatalogRepository.open(
        databaseFilePath: _join(_dataDirectory!, 'catalog.sqlite'),
        legacyJsonFilePath: _join(_dataDirectory!, 'catalog.json'),
      );
      if (_disposed) {
        await opened.dispose();
        return;
      }
      _repository = opened;
      _repositorySubscription = _repository!.changes.listen((_) {
        _refreshView();
      });
      await _readSettings();
      if (_disposed) {
        await _preferencesStore?.close();
        return;
      }
      if (isWindows) {
        for (final root in _windowsRoots) {
          await for (final item in RecoverableTrash().recover(root)) {
            await _repository!.upsert(item, preserveUserState: false);
          }
        }
      }
      if (!isAndroid) _refreshView();

      if (isAndroid) {
        await _initializeAndroid();
      } else if (isWindows) {
        _folderSubscription = _folderWatcher.changes.listen((_) {
          if (!_settings.autoRefresh || _disposed) return;
          if (_isIndexing) {
            _refreshQueued = true;
          } else {
            unawaited(refresh());
          }
        });
        await _configureWatching();
        if (_windowsRoots.isEmpty) {
          _loadState = _repository!.itemCount == 0
              ? GalleryLoadState.unsupported
              : GalleryLoadState.ready;
          _statusMessage = 'Add a folder in Files to start local indexing.';
          _safeNotify();
        } else {
          await refresh();
        }
      } else {
        _loadState = GalleryLoadState.unsupported;
        _statusMessage = 'This build currently supports Android and Windows.';
        _safeNotify();
      }
    } catch (error) {
      _initialized = false;
      await _folderSubscription?.cancel();
      _folderSubscription = null;
      await _folderWatcher.watchSelectedRoots(const <String>[]);
      await _repositorySubscription?.cancel();
      _repositorySubscription = null;
      await _repository?.dispose();
      _repository = null;
      await _preferencesStore?.close();
      _preferencesStore = null;
      _visiblePhoneIds = <String>{};
      _visiblePcIds = <String>{};
      _clearVisibleCatalogue();
      _fail('Could not start the local catalogue.', error);
    }
  }

  Future<void> _initializeAndroid() async {
    if (!_android.isSupported) {
      _loadState = GalleryLoadState.permissionRequired;
      _statusMessage = 'Android media access is available on a phone build.';
      _safeNotify();
      return;
    }
    final permission = await _android.getPermissionStatus(
      mediaTypes: const <AndroidMediaType>{
        AndroidMediaType.image,
        AndroidMediaType.video,
      },
    );
    _hasLimitedAccess = permission.visualAccess == 'partial';
    final hasVisual =
        permission.isGranted(AndroidMediaType.image) ||
        permission.isGranted(AndroidMediaType.video);
    if (!hasVisual) {
      _visiblePhoneIds = <String>{};
      _clearVisibleCatalogue();
      _loadState = GalleryLoadState.permissionRequired;
      _statusMessage = 'Choose the photos and videos nexGallery may show.';
      _safeNotify();
      return;
    }
    await refresh();
  }

  @override
  Future<void> requestAccessAndRefresh() async {
    if (!isAndroid || !_android.isSupported) {
      _statusMessage = 'Install this build on Android to grant media access.';
      _safeNotify();
      return;
    }
    final requestGeneration = ++_permissionGeneration;
    _visiblePhoneIds = <String>{};
    _clearVisibleCatalogue();
    _safeNotify();
    try {
      final permission = await _android.requestPermissions(
        mediaTypes: const <AndroidMediaType>{
          AndroidMediaType.image,
          AndroidMediaType.video,
        },
      );
      if (_disposed || requestGeneration != _permissionGeneration) return;
      _hasLimitedAccess = permission.visualAccess == 'partial';
      final hasVisual =
          permission.isGranted(AndroidMediaType.image) ||
          permission.isGranted(AndroidMediaType.video);
      if (!hasVisual) {
        _visiblePhoneIds = <String>{};
        _clearVisibleCatalogue();
        _loadState = GalleryLoadState.permissionRequired;
        _statusMessage = permission.canOpenSettings
            ? 'Access is off. You can enable it in Android settings.'
            : 'Photo and video access was not granted.';
        _safeNotify();
        return;
      }
      await refresh();
    } catch (error) {
      _fail('Could not request media access.', error);
    }
  }

  @override
  Future<void> refresh() async {
    final repository = _repository;
    if (_disposed) return;
    if (repository == null) {
      await initialize();
      return;
    }
    if (_isIndexing) {
      _refreshQueued = true;
      if (isAndroid) {
        _permissionGeneration++;
        _visiblePhoneIds = <String>{};
        _clearVisibleCatalogue();
        _safeNotify();
      }
      return;
    }
    _loadState = GalleryLoadState.loading;
    _isIndexing = true;
    _errorMessage = null;
    _indexedCount = 0;
    _discoveredCount = null;
    _statusMessage = null;
    if (isAndroid) {
      // A fresh OS query, never persisted permission state, authorizes the view.
      _visiblePhoneIds = <String>{};
      _clearVisibleCatalogue();
    }
    _safeNotify();
    try {
      bool scanCompleted;
      if (isAndroid) {
        scanCompleted = await _scanAndroid(repository);
      } else if (isWindows) {
        scanCompleted = await _scanWindows(repository);
      } else {
        scanCompleted = false;
      }
      _refreshView();
      if (scanCompleted) {
        _loadState = _items.isEmpty
            ? GalleryLoadState.empty
            : GalleryLoadState.ready;
        _statusMessage ??= _hasLimitedAccess
            ? 'Showing only the photos selected in Android settings.'
            : 'Local scan complete. Nothing was uploaded.';
      }
    } catch (error) {
      if (!await _handleAndroidScanFailure()) {
        _fail('The local scan could not finish.', error);
      }
    } finally {
      _isIndexing = false;
      _safeNotify();
      if (_refreshQueued && !_disposed) {
        _refreshQueued = false;
        unawaited(refresh());
      }
    }
  }

  Future<bool> _handleAndroidScanFailure() async {
    if (!isAndroid || !_android.isSupported || _disposed) return false;
    _visiblePhoneIds = <String>{};
    _clearVisibleCatalogue();
    try {
      final permission = await _android.getPermissionStatus(
        mediaTypes: const <AndroidMediaType>{
          AndroidMediaType.image,
          AndroidMediaType.video,
        },
      );
      if (_disposed) return true;
      _hasLimitedAccess = permission.visualAccess == 'partial';
      if (!permission.isGranted(AndroidMediaType.image) &&
          !permission.isGranted(AndroidMediaType.video)) {
        _loadState = GalleryLoadState.permissionRequired;
        _errorMessage = null;
        _statusMessage =
            'Photo and video access is required to scan this phone.';
        return true;
      }
      if (_refreshQueued) return true;
    } catch (_) {
      // Keep the view closed when the OS cannot confirm current access.
    }
    return false;
  }

  Future<bool> _scanAndroid(MediaCatalogRepository repository) async {
    final generation = ++_permissionGeneration;
    if (!_android.isSupported) {
      throw UnsupportedError('Android MediaStore is unavailable here.');
    }
    final permission = await _android.getPermissionStatus(
      mediaTypes: const <AndroidMediaType>{
        AndroidMediaType.image,
        AndroidMediaType.video,
      },
    );
    if (_disposed || generation != _permissionGeneration) return false;
    _hasLimitedAccess = permission.visualAccess == 'partial';
    final hasVisual =
        permission.isGranted(AndroidMediaType.image) ||
        permission.isGranted(AndroidMediaType.video);
    if (!hasVisual) {
      _visiblePhoneIds = <String>{};
      _clearVisibleCatalogue();
      _loadState = GalleryLoadState.permissionRequired;
      _statusMessage = 'Photo and video access is required to scan this phone.';
      return false;
    }
    final result = <MediaItem>[];
    for (final type in AndroidMediaType.values) {
      if (!permission.isGranted(type)) continue;
      var offset = 0;
      while (true) {
        if (_disposed || generation != _permissionGeneration) return false;
        final page = await _android.queryMedia(
          mediaType: type,
          limit: 500,
          offset: offset,
          sortBy: AndroidMediaSort.dateTaken,
        );
        if (_disposed || generation != _permissionGeneration) return false;
        result.addAll(page.items.map(_fromAndroid));
        _indexedCount = result.length;
        _safeNotify();
        if (!page.hasMore || page.nextOffset == null) break;
        offset = page.nextOffset!;
      }
    }
    _discoveredCount = result.length;
    if (_disposed || generation != _permissionGeneration) return false;
    final latestPermission = await _android.getPermissionStatus(
      mediaTypes: const <AndroidMediaType>{
        AndroidMediaType.image,
        AndroidMediaType.video,
      },
    );
    if (generation != _permissionGeneration ||
        latestPermission.visualAccess != permission.visualAccess ||
        AndroidMediaType.values.any(
          (type) =>
              latestPermission.statuses[type] != permission.statuses[type],
        )) {
      _refreshQueued = true;
      return false;
    }
    await repository.synchronizeSource(
      MediaSource.phone,
      result,
      removeMissing: !_hasLimitedAccess,
      scannedKinds: <MediaKind>{
        if (permission.isGranted(AndroidMediaType.image)) MediaKind.image,
        if (permission.isGranted(AndroidMediaType.video)) MediaKind.video,
        if (permission.isGranted(AndroidMediaType.audio)) MediaKind.audio,
      },
    );
    if (_disposed || generation != _permissionGeneration) return false;
    _indexedCount = result.length;
    _discoveredCount = result.length;
    _visiblePhoneIds = result.map((item) => item.id).toSet();
    if (!_hasLimitedAccess) {
      _visiblePhoneIds.addAll(
        repository.snapshot.items
            .where(
              (item) =>
                  item.source == MediaSource.phone &&
                  item.section == MediaSection.trash &&
                  ((item.kind == MediaKind.image &&
                          permission.isGranted(AndroidMediaType.image)) ||
                      (item.kind == MediaKind.video &&
                          permission.isGranted(AndroidMediaType.video))),
            )
            .map((item) => item.id),
      );
    }
    return true;
  }

  Future<bool> _scanWindows(MediaCatalogRepository repository) async {
    if (_windowsRoots.isEmpty) {
      _loadState = GalleryLoadState.unsupported;
      _statusMessage = 'Add a folder in Files to start local indexing.';
      return false;
    }
    _scanCancellation?.cancel();
    final generation = _scanGeneration;
    final cancellation = ScanCancellationToken();
    _scanCancellation = cancellation;
    final result = await _scanner.scan(
      List<String>.of(_windowsRoots),
      cancellationToken: cancellation,
      options: ScanOptions(
        source: MediaSource.pc,
        includeHidden: _settings.includeHiddenFiles,
        excludedPaths: <String>[_dataDirectory!],
      ),
      onProgress: (progress) {
        if (_disposed || generation != _scanGeneration) return;
        _indexedCount = progress.itemsFound;
        _safeNotify();
      },
    );
    if (_disposed || generation != _scanGeneration) return false;
    _discoveredCount = result.items.length;
    final complete =
        !result.wasCancelled && !result.stoppedByLimit && result.issues.isEmpty;
    final scannedIds = result.items.map((item) => item.id).toSet();
    final unavailable = repository.snapshot.items
        .where((item) {
          if (item.source != MediaSource.pc || scannedIds.contains(item.id)) {
            return false;
          }
          final path = _fileForItem(item).absolute.path;
          return result.issues.any((issue) => _pathIsWithin(path, issue.path));
        })
        .map((item) => item.copyWith(isAvailable: false));
    await repository.synchronizeSource(MediaSource.pc, <MediaItem>[
      ...result.items,
      ...unavailable,
      if (!_settings.includeHiddenFiles)
        ...repository.snapshot.items.where(
          (item) =>
              item.source == MediaSource.pc &&
              _windowsRoots.any(
                (root) => _pathIsWithin(_fileForItem(item).path, root),
              ) &&
              _isHiddenItem(item) &&
              !scannedIds.contains(item.id),
        ),
    ], removeMissing: complete);
    if (!complete) {
      final reason = result.wasCancelled
          ? 'Scan cancelled'
          : result.stoppedByLimit
          ? 'Scan limit reached'
          : '${result.issues.length} paths unavailable';
      _statusMessage = '$reason. Existing metadata and albums were kept.';
    }
    return true;
  }

  @override
  Future<void> addWindowsFolder(String path) async {
    if (!isWindows || _disposed) return;
    final directory = Directory(path.trim());
    if (!await directory.exists()) {
      _recordOperationError('That folder does not exist.', path);
      return;
    }
    final canonical = directory.absolute.path;
    final saved = await _changeConfiguration(() async {
      if (_windowsRoots.any((root) => _samePath(root, canonical))) return;
      await _persistConfiguration(roots: <String>[..._windowsRoots, canonical]);
      _invalidateWindowsScan();
      await _configureWatching();
      _refreshView(resetPaging: true);
    }, 'The folder selection could not be saved.');
    if (saved && !_disposed) await refresh();
  }

  @override
  Future<void> removeWindowsFolder(String path) async {
    if (!isWindows || _disposed) return;
    final saved = await _changeConfiguration(() async {
      if (!_windowsRoots.any((root) => _samePath(root, path))) return;
      final roots = _windowsRoots
          .where((root) => !_samePath(root, path))
          .toList();
      await _persistConfiguration(roots: roots);
      _invalidateWindowsScan();
      await _configureWatching();
      final repository = _repository;
      if (repository != null && !_disposed) {
        final retained = repository.snapshot.items.where(
          (item) =>
              item.source == MediaSource.pc &&
              roots.any((root) => _pathIsWithin(_fileForItem(item).path, root)),
        );
        await repository.synchronizeSource(
          MediaSource.pc,
          retained,
          preserveTrash: false,
        );
      }
      _refreshView(resetPaging: true);
    }, 'The folder selection could not be saved.');
    if (!saved || _disposed) return;
    if (_windowsRoots.isEmpty) {
      _loadState = GalleryLoadState.unsupported;
      _statusMessage = 'Add a folder in Files to start local indexing.';
      _safeNotify();
    } else {
      await refresh();
    }
  }

  void _invalidateWindowsScan() {
    _scanGeneration++;
    _scanCancellation?.cancel();
    if (_isIndexing) _refreshQueued = true;
  }

  Future<void> _configureWatching() => _folderWatcher.watchSelectedRoots(
    isWindows && _settings.autoRefresh ? _windowsRoots : const <String>[],
    ignoredPaths: <String>[?_dataDirectory],
  );

  Future<bool> _changeConfiguration(
    Future<void> Function() operation,
    String message,
  ) {
    final completion = Completer<bool>();
    _configurationQueue = _configurationQueue.then((_) async {
      if (_disposed) {
        completion.complete(false);
        return;
      }
      try {
        await operation();
        _errorMessage = null;
        _safeNotify();
        completion.complete(true);
      } catch (error) {
        _recordOperationError(message, error);
        completion.complete(false);
      }
    });
    return completion.future;
  }

  Future<void> _persistConfiguration({
    GallerySettings? settings,
    List<String>? roots,
    Map<String, int>? videoPositions,
  }) async {
    final store = _preferencesStore;
    if (store == null) {
      throw StateError('Initialize the gallery before changing settings.');
    }
    final candidate = GalleryPreferences(
      settings: settings ?? _settings,
      roots: roots ?? _windowsRoots,
      videoPositions: videoPositions ?? _videoPositions,
    );
    await store.save(candidate);
    if (_disposed) return;
    _settings = candidate.settings;
    _windowsRoots
      ..clear()
      ..addAll(candidate.roots);
    _videoPositions
      ..clear()
      ..addAll(candidate.videoPositions);
  }

  @override
  Future<void> updateSettings(GallerySettings value) async {
    var rescan = false;
    final saved = await _changeConfiguration(() async {
      final previous = _settings;
      await _persistConfiguration(settings: value);
      rescan =
          isWindows && previous.includeHiddenFiles != value.includeHiddenFiles;
      if (rescan) _invalidateWindowsScan();
      await _configureWatching();
      _refreshView(resetPaging: rescan);
    }, 'Settings could not be saved.');
    if (saved && rescan && !_disposed) await refresh();
  }

  @override
  Future<void> openAccessSettings() async {
    if (isAndroid && _android.isSupported) await _android.openAppSettings();
  }

  String _positionKey(MediaItem item) =>
      '${item.id}:${item.metadata.modifiedAt.microsecondsSinceEpoch}';
  @override
  Future<Duration> readVideoPosition(MediaItem item) async =>
      Duration(milliseconds: _videoPositions[_positionKey(item)] ?? 0);
  @override
  Future<void> saveVideoPosition(MediaItem item, Duration position) async {
    if (_disposed || _preferencesStore == null || !canAccessMedia(item)) return;
    await _changeConfiguration(() async {
      final positions = Map<String, int>.of(_videoPositions);
      final key = _positionKey(item);
      positions.remove(key);
      positions[key] = position.inMilliseconds.clamp(0, 1 << 53);
      while (positions.length > 2000) {
        positions.remove(positions.keys.first);
      }
      await _persistConfiguration(videoPositions: positions);
    }, 'Playback position could not be saved.');
  }

  @override
  bool canAccessMedia(MediaItem item) {
    if (_disposed || !item.isAvailable) return false;
    final current = _repository?.itemById(item.id);
    if (_initialized &&
        (current == null ||
            !current.isAvailable ||
            current.uri != item.uri ||
            current.metadata.modifiedAt != item.metadata.modifiedAt)) {
      return false;
    }
    return isAndroid
        ? _visiblePhoneIds.contains(item.id)
        : isWindows && _initialized
        ? _visiblePcIds.contains(item.id)
        : true;
  }

  bool _isHiddenItem(MediaItem item) {
    final path = item.relativePath.replaceAll('\\', '/');
    return path
        .split('/')
        .any(
          (name) =>
              name.startsWith('.') ||
              name.toLowerCase() == r'$recycle.bin' ||
              name.toLowerCase() == 'system volume information',
        );
  }

  Set<String> _visibleIds(MediaCatalogRepository repository) {
    if (isAndroid) return _visiblePhoneIds;
    _visiblePcIds = repository.snapshot.items
        .where(
          (item) =>
              item.source == MediaSource.pc &&
              _windowsRoots.any(
                (root) => _pathIsWithin(_fileForItem(item).path, root),
              ) &&
              (_dataDirectory == null ||
                  !_pathIsWithin(_fileForItem(item).path, _dataDirectory!)) &&
              (_settings.includeHiddenFiles || !_isHiddenItem(item)),
        )
        .map((item) => item.id)
        .toSet();
    return _visiblePcIds;
  }

  @override
  void setSearchText(String value) {
    if (_searchText == value) return;
    _searchText = value;
    _refreshView(resetPaging: true);
  }

  @override
  void showCollection(GalleryCollection value) {
    _collection = value;
    _kinds = <MediaKind>{};
    _albumId = null;
    _refreshView(resetPaging: true);
  }

  @override
  void showKinds(Set<MediaKind> kinds) {
    _collection = GalleryCollection.timeline;
    _kinds = Set<MediaKind>.from(kinds);
    _albumId = null;
    _refreshView(resetPaging: true);
  }

  @override
  void showAlbum(String albumId) {
    _collection = GalleryCollection.timeline;
    _kinds = <MediaKind>{};
    _albumId = albumId;
    _refreshView(resetPaging: true);
  }

  @override
  Future<void> toggleFavorite(MediaItem item) async {
    if (_disposed || (isAndroid && !canAccessMedia(item))) return;
    await _repository?.setFavorite(item.id, !item.isFavorite);
  }

  @override
  Future<void> archive(MediaItem item) async {
    if (_disposed || (isAndroid && !canAccessMedia(item))) return;
    await _repository?.moveToArchive(item.id);
  }

  @override
  Future<bool> moveToTrash(MediaItem item) async {
    if (!canAccessMedia(item)) return false;
    if (isWindows) {
      MediaItem? moved;
      try {
        moved = await RecoverableTrash().put(item);
        await _repository!.upsert(moved, preserveUserState: false);
        return true;
      } catch (error) {
        if (moved != null) {
          await RecoverableTrash().restore(moved);
          await RecoverableTrash().finish(moved);
        }
        _fail('The item could not be moved to Trash.', error);
        return false;
      }
    }
    if (isAndroid && _android.isSupported) {
      try {
        final result = await _android.setTrashed(<Uri>[Uri.parse(item.uri)]);
        if (result.status == 'cancelled') return false;
        if (!result.completed && result.status != 'unsupported') return false;
      } catch (error) {
        _fail('The item could not be moved to Trash.', error);
        return false;
      }
    }
    if (!canAccessMedia(item)) return false;
    await _repository?.moveToTrash(item.id);
    return true;
  }

  @override
  Future<bool> restore(MediaItem item) async {
    if (!canAccessMedia(item)) return false;
    if (isWindows &&
        item.metadata.attributes.containsKey('trash.originalUri')) {
      try {
        final restored = await RecoverableTrash().restore(item);
        try {
          await _repository!.upsert(restored, preserveUserState: false);
        } catch (_) {
          await _fileForItem(restored).rename(_fileForItem(item).path);
          rethrow;
        }
        await RecoverableTrash().finish(item);
        return true;
      } catch (error) {
        _fail('The item could not be restored.', error);
        return false;
      }
    }
    if (isAndroid && _android.isSupported) {
      try {
        final result = await _android.setTrashed(<Uri>[
          Uri.parse(item.uri),
        ], trashed: false);
        if (result.status == 'cancelled') return false;
        if (!result.completed && result.status != 'unsupported') return false;
      } catch (error) {
        _fail('The item could not be restored.', error);
        return false;
      }
    }
    if (!canAccessMedia(item)) return false;
    await _repository?.restore(item.id);
    return true;
  }

  @override
  Future<bool> deletePermanently(MediaItem item) async {
    if (!canAccessMedia(item)) return false;
    try {
      if (isAndroid && _android.isSupported) {
        var result = await _android.deleteMedia(<Uri>[Uri.parse(item.uri)]);
        if (result.status == 'cancelled') return false;
        if (result.requiresRetry) {
          result = await _android.deleteMedia(<Uri>[Uri.parse(item.uri)]);
        }
        if (!result.completed || result.affectedCount < 1) return false;
      } else if (isWindows) {
        final file = _fileForItem(item);
        if (await file.exists()) await file.delete();
      }
      if (!canAccessMedia(item)) return false;
      await _repository?.deletePermanently(item.id);
      if (isWindows) await RecoverableTrash().finish(item);
      return true;
    } catch (error) {
      _fail('The file could not be deleted.', error);
      return false;
    }
  }

  @override
  Future<void> createAlbum(String name) async {
    await _repository?.createAlbum(name);
  }

  @override
  Future<void> addToAlbum(MediaItem item, String albumId) async {
    if (_disposed || (isAndroid && !canAccessMedia(item))) return;
    await _repository?.addToAlbum(albumId, <String>[item.id]);
  }

  @override
  Future<void> open(MediaItem item) async {
    if (!canAccessMedia(item)) return;
    try {
      if (isAndroid && _android.isSupported) {
        await _android.openMedia(
          Uri.parse(item.uri),
          mimeType: item.metadata.mimeType,
        );
      } else if (isWindows) {
        await Process.start('explorer.exe', <String>[_fileForItem(item).path]);
      }
    } catch (error) {
      _fail('No app could open this item.', error);
    }
  }

  @override
  Future<void> share(MediaItem item) async {
    if (!canAccessMedia(item)) return;
    try {
      if (isAndroid && _android.isSupported) {
        await _android.shareMedia(
          <Uri>[Uri.parse(item.uri)],
          mimeType: item.metadata.mimeType,
          chooserTitle: 'Share from nexGallery',
        );
      } else if (isWindows) {
        await Process.start('explorer.exe', <String>[
          '/select,${_fileForItem(item).path}',
        ]);
      }
    } catch (error) {
      _fail('This item could not be shared.', error);
    }
  }

  @override
  String? get activeAlbumId => _albumId;
  List<Memory>? _memories;
  @override
  List<Memory> get memories =>
      _memories ??= buildMemories(localItems, now: DateTime.now());
  @override
  CatalogSortField get sortField => _sortField;
  @override
  CatalogSortDirection get sortDirection => _sortDirection;

  @override
  void setSort(CatalogSortField field, CatalogSortDirection direction) {
    if (field == _sortField && direction == _sortDirection) return;
    _sortField = field;
    _sortDirection = direction;
    _refreshView(resetPaging: true);
  }

  @override
  Future<void> renameAlbum(String albumId, String name) async {
    await _repository?.renameAlbum(albumId, name);
  }

  @override
  Future<void> deleteAlbum(String albumId) async {
    if (_albumId == albumId) _albumId = null;
    await _repository?.deleteAlbum(albumId);
  }

  @override
  Future<void> setAlbumCover(String albumId, MediaItem? item) async {
    if (item != null && !canAccessMedia(item)) return;
    await _repository?.setAlbumCover(albumId, item?.id);
  }

  Iterable<String> _accessibleIds(Iterable<MediaItem> items) =>
      items.where(canAccessMedia).map((item) => item.id);

  @override
  Future<void> addAllToAlbum(Iterable<MediaItem> items, String albumId) async {
    await _repository?.addToAlbum(albumId, _accessibleIds(items).toList());
  }

  @override
  Future<void> removeFromAlbum(
    String albumId,
    Iterable<MediaItem> items,
  ) async {
    await _repository?.removeFromAlbum(
      albumId,
      items.map((item) => item.id).toList(),
    );
  }

  @override
  Future<void> setFavorites(Iterable<MediaItem> items, bool favorite) async {
    await _repository?.updateItems(
      _accessibleIds(items).toList(),
      (item) => item.copyWith(isFavorite: favorite),
    );
  }

  @override
  Future<void> archiveAll(Iterable<MediaItem> items) async {
    await _repository?.updateItems(
      _accessibleIds(items).toList(),
      (item) => item.section == MediaSection.trash
          ? item
          : item.copyWith(section: MediaSection.archive, deletedAt: null),
    );
  }

  @override
  Future<int> moveAllToTrash(Iterable<MediaItem> items) async {
    final selected = items
        .where(
          (item) => canAccessMedia(item) && item.section != MediaSection.trash,
        )
        .toList();
    if (selected.isEmpty) return 0;
    if (isWindows) {
      var moved = 0;
      for (final item in selected) {
        if (await moveToTrash(item)) moved++;
      }
      return moved;
    }
    if (isAndroid && _android.isSupported) {
      try {
        // One system consent covers the whole selection.
        final result = await _android.setTrashed(
          selected.map((item) => Uri.parse(item.uri)).toList(),
        );
        if (result.status == 'cancelled') return 0;
        if (!result.completed && result.status != 'unsupported') return 0;
      } catch (error) {
        _fail('The items could not be moved to Trash.', error);
        return 0;
      }
    }
    final now = DateTime.now().toUtc();
    return await _repository?.updateItems(
          _accessibleIds(selected).toList(),
          (item) => item.copyWith(section: MediaSection.trash, deletedAt: now),
        ) ??
        0;
  }

  @override
  Future<int> emptyTrash() async {
    final repository = _repository;
    if (repository == null) return 0;
    final trashed = repository.snapshot.items
        .where(
          (item) => item.section == MediaSection.trash && canAccessMedia(item),
        )
        .toList();
    if (trashed.isEmpty) return 0;
    if (isWindows) {
      var deleted = 0;
      for (final item in trashed) {
        if (await deletePermanently(item)) deleted++;
      }
      return deleted;
    }
    if (isAndroid && _android.isSupported) {
      try {
        final uris = trashed.map((item) => Uri.parse(item.uri)).toList();
        var result = await _android.deleteMedia(uris);
        if (result.status == 'cancelled') return 0;
        if (result.requiresRetry) result = await _android.deleteMedia(uris);
        if (!result.completed) return 0;
      } catch (error) {
        _fail('Trash could not be emptied.', error);
        return 0;
      }
    }
    return repository.removeItems(trashed.map((item) => item.id).toList());
  }

  @override
  Future<void> shareAll(Iterable<MediaItem> items) async {
    final selected = items.where(canAccessMedia).toList();
    if (selected.isEmpty) return;
    if (selected.length == 1 || !isAndroid) return share(selected.first);
    try {
      final types = selected.map((item) => item.metadata.mimeType).toSet();
      await _android.shareMedia(
        selected.map((item) => Uri.parse(item.uri)).toList(),
        mimeType: types.length == 1 && types.first != null
            ? types.first
            : selected.every((item) => item.kind == MediaKind.image)
            ? 'image/*'
            : '*/*',
        chooserTitle: 'Share from nexGallery',
      );
    } catch (error) {
      _fail('These items could not be shared.', error);
    }
  }

  @override
  Future<void> correctMetadata(
    MediaItem item, {
    DateTime? takenAt,
    (double, double)? location,
    bool clearLocation = false,
  }) async {
    if (!canAccessMedia(item)) {
      throw StateError('Access to the original has changed.');
    }
    if (location != null &&
        (location.$1.abs() > 90 ||
            location.$2.abs() > 180 ||
            !location.$1.isFinite ||
            !location.$2.isFinite)) {
      throw const FormatException('Enter a valid latitude and longitude.');
    }
    await _repository?.updateItems([item.id], (current) {
      final attributes = {...current.metadata.attributes};
      if (takenAt != null) {
        attributes[userTakenAtKey] = takenAt.toUtc().toIso8601String();
      }
      if (clearLocation) {
        attributes
          ..remove(userLatitudeKey)
          ..remove(userLongitudeKey)
          ..[userNoLocationKey] = 'true';
      } else if (location != null) {
        attributes
          ..remove(userNoLocationKey)
          ..[userLatitudeKey] = '${location.$1}'
          ..[userLongitudeKey] = '${location.$2}';
      }
      return current.copyWith(
        metadata: withUserOverrides(
          current.metadata.copyWith(attributes: attributes),
        ),
      );
    });
  }

  @override
  Future<void> setWallpaper(MediaItem item, WallpaperTarget target) async {
    if (!canAccessMedia(item) || item.kind != MediaKind.image) {
      throw StateError('Choose an available photo.');
    }
    if (isAndroid && _android.isSupported) {
      if (!await _device.setAndroidWallpaper(
        Uri.parse(item.uri),
        target.name,
      )) {
        throw UnsupportedError(
          'This phone does not allow apps to set wallpaper.',
        );
      }
    } else if (isWindows) {
      if (target == WallpaperTarget.lock) {
        throw UnsupportedError(
          'Windows lets apps change only the desktop background.',
        );
      }
      await setWindowsWallpaper(_fileForItem(item).path);
    } else {
      throw UnsupportedError('Wallpaper is available on Android and Windows.');
    }
  }

  @override
  Future<Uint8List> exportOrganization(String password) async {
    final repository = _repository;
    if (repository == null) throw StateError('The library is still opening.');
    return OrganizationBackup.encrypt(repository.snapshot, password);
  }

  @override
  Future<int> importOrganization(Uint8List backup, String password) async {
    final repository = _repository;
    if (repository == null) throw StateError('The library is still opening.');
    final decoded = await OrganizationBackup.decrypt(backup, password);
    return repository.restoreOrganization(
      albums: decoded.albums,
      items: decoded.items,
    );
  }

  @override
  Future<Uint8List?> loadThumbnail(MediaItem item, {int size = 384}) async {
    if (!canAccessMedia(item)) return null;
    if (item.kind != MediaKind.image && item.kind != MediaKind.video) {
      return null;
    }
    try {
      if (isAndroid && _android.isSupported) {
        final result = await _android.loadThumbnail(
          Uri.parse(item.uri),
          size: size,
        );
        return canAccessMedia(item) ? result.bytes : null;
      }
      if (isWindows && item.kind == MediaKind.image) {
        return await _decodeLocalThumbnail(_fileForItem(item).path, size);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<Uint8List?> _decodeLocalThumbnail(String path, int size) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) {
          final longest = width > height ? width : height;
          final scale = longest > size ? size / longest : 1.0;
          return ui.TargetImageSize(
            width: (width * scale).round().clamp(1, size),
            height: (height * scale).round().clamp(1, size),
          );
        },
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      image?.dispose();
      codec?.dispose();
      // instantiateImageCodecWithSize owns and disposes the immutable buffer.
    }
  }

  MediaItem _fromAndroid(AndroidMediaItem item) {
    final now = DateTime.now().toUtc();
    final modified = item.dateModifiedSeconds == null
        ? now
        : DateTime.fromMillisecondsSinceEpoch(
            item.dateModifiedSeconds! * 1000,
            isUtc: true,
          );
    final created = item.dateAddedSeconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            item.dateAddedSeconds! * 1000,
            isUtc: true,
          );
    final taken = item.dateTakenMilliseconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            item.dateTakenMilliseconds!,
            isUtc: true,
          );
    final kind = switch (item.type) {
      AndroidMediaType.image => MediaKind.image,
      AndroidMediaType.video => MediaKind.video,
      AndroidMediaType.audio => MediaKind.audio,
    };
    final name =
        item.displayName ?? item.title ?? '${item.type.name}-${item.id}';
    return MediaItem(
      id: 'android_${item.type.name}_${item.id}',
      name: name,
      uri: item.uri.toString(),
      relativePath: item.relativePath ?? item.bucketName ?? '',
      kind: kind,
      source: MediaSource.phone,
      metadata: MediaMetadata(
        sizeBytes: item.sizeBytes ?? 0,
        modifiedAt: modified,
        createdAt: created,
        takenAt: taken,
        duration: item.durationMilliseconds == null
            ? null
            : Duration(milliseconds: item.durationMilliseconds!),
        width: item.width,
        height: item.height,
        mimeType: item.mimeType,
        extension: _extension(name),
        attributes: <String, String>{
          if (item.bucketName != null) 'bucket': item.bucketName!,
          if (item.artist != null) 'artist': item.artist!,
          if (item.album != null) 'album': item.album!,
        },
      ),
      indexedAt: now,
    );
  }

  CatalogQuery _viewQuery({int offset = 0}) {
    final section = switch (_collection) {
      GalleryCollection.timeline => MediaSection.library,
      GalleryCollection.favorites => MediaSection.library,
      GalleryCollection.archive => MediaSection.archive,
      GalleryCollection.trash => MediaSection.trash,
    };
    return CatalogQuery(
      searchText: _searchText,
      section: section,
      favoritesOnly: _collection == GalleryCollection.favorites,
      albumId: _albumId,
      kinds: _kinds,
      sortField: _sortField,
      sortDirection: _sortDirection,
      limit: _pageSize,
      offset: offset,
      itemIds: isAndroid
          ? _visiblePhoneIds
          : isWindows
          ? _visiblePcIds
          : null,
    );
  }

  @override
  void loadMoreItems() {
    final repository = _repository;
    if (repository == null || !hasMoreItems || _disposed) return;
    final page = repository.query(_viewQuery(offset: _items.length));
    _items = List<MediaItem>.unmodifiable(<MediaItem>[
      ..._items,
      ...page.items,
    ]);
    _totalItemCount = page.totalCount;
    _safeNotify();
  }

  void _refreshView({bool resetPaging = false}) {
    final repository = _repository;
    if (repository == null || _disposed) return;
    _memories = null;
    final visibleIds = _visibleIds(repository);
    if (isAndroid && visibleIds.isEmpty) {
      _clearVisibleCatalogue();
      _safeNotify();
      return;
    }
    final visibleCount = resetPaging || _items.length < _pageSize
        ? _pageSize
        : _items.length;
    final allItems = <MediaItem>[];
    var offset = 0;
    while (offset < visibleCount) {
      final page = repository.query(_viewQuery(offset: offset));
      _totalItemCount = page.totalCount;
      allItems.addAll(page.items);
      final next = page.nextOffset;
      if (next == null) break;
      offset = next;
    }
    _items = List<MediaItem>.unmodifiable(allItems);
    _albums = repository.albums(limit: 500).items;
    _categories = repository.categories();
    if (isAndroid || isWindows) {
      _albums = _albums
          .map(
            (album) => album.copyWith(
              itemIds: album.itemIds.where(visibleIds.contains),
              coverItemId: visibleIds.contains(album.coverItemId)
                  ? album.coverItemId
                  : null,
            ),
          )
          .toList(growable: false);
      _categories = MediaKind.values
          .map((kind) {
            final visible = repository.snapshot.items.where(
              (item) =>
                  item.section == MediaSection.library &&
                  item.kind == kind &&
                  visibleIds.contains(item.id),
            );
            return CategorySummary(
              kind: kind,
              itemCount: visible.length,
              totalBytes: visible.fold<int>(
                0,
                (sum, item) => sum + item.metadata.sizeBytes,
              ),
            );
          })
          .toList(growable: false);
    }
    if (_loadState != GalleryLoadState.starting &&
        _loadState != GalleryLoadState.loading &&
        _loadState != GalleryLoadState.permissionRequired &&
        _loadState != GalleryLoadState.unsupported &&
        _loadState != GalleryLoadState.error) {
      _loadState = _items.isEmpty
          ? GalleryLoadState.empty
          : GalleryLoadState.ready;
    }
    _safeNotify();
  }

  Future<String> _resolveDataDirectory() async {
    if (isAndroid && _android.isSupported) {
      return _android.getAppDataPath();
    }
    final base =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final directory = Directory(_join(base, 'nexGallery'));
    await directory.create(recursive: true);
    return directory.path;
  }

  Future<void> _readSettings() async {
    _preferencesStore = GalleryPreferencesStore(_dataDirectory!);
    final preferences = await _preferencesStore!.load();
    if (_disposed) {
      await _preferencesStore!.close();
      return;
    }
    _settings = preferences.settings;
    _videoPositions
      ..clear()
      ..addAll(preferences.videoPositions);
    _windowsRoots
      ..clear()
      ..addAll(
        preferences.roots
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty),
      );
  }

  void _clearVisibleCatalogue() {
    _memories = null;
    _indexedCount = 0;
    _discoveredCount = null;
    _items = const <MediaItem>[];
    _totalItemCount = 0;
    _categories = const <CategorySummary>[];
    _albums = const <MediaAlbum>[];
  }

  File _fileForItem(MediaItem item) {
    final uri = Uri.tryParse(item.uri);
    if (uri != null && uri.scheme == 'file') return File.fromUri(uri);
    return File(item.uri);
  }

  void _recordOperationError(String message, Object error) {
    _errorMessage = '$message ${_friendlyError(error)}';
    _safeNotify();
  }

  void _fail(String message, Object error) {
    _errorMessage = '$message ${_friendlyError(error)}';
    _statusMessage = null;
    _loadState = GalleryLoadState.error;
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _scanCancellation?.cancel();
    unawaited(_repositorySubscription?.cancel());
    unawaited(_folderSubscription?.cancel());
    unawaited(_folderWatcher.dispose());
    unawaited(_configurationQueue.then((_) => _preferencesStore?.close()));
    final repository = _repository;
    if (repository != null) unawaited(repository.dispose());
    super.dispose();
  }
}

String _join(String left, String right) {
  final separator = Platform.pathSeparator;
  final cleanLeft = left.endsWith(separator)
      ? left.substring(0, left.length - 1)
      : left;
  return '$cleanLeft$separator$right';
}

bool _samePath(String left, String right) =>
    _pathIsWithin(left, right) && _pathIsWithin(right, left);

bool _pathIsWithin(String path, String root) {
  String normalized(String value) =>
      value.replaceAll('/', '\\').replaceAll(RegExp(r'\\+$'), '').toLowerCase();
  final candidate = normalized(path);
  final boundary = normalized(root);
  return candidate == boundary || candidate.startsWith('$boundary\\');
}

String? _extension(String name) {
  final index = name.lastIndexOf('.');
  if (index <= 0 || index == name.length - 1) return null;
  return name.substring(index + 1).toLowerCase();
}

String _friendlyError(Object error) {
  final text = error.toString().replaceFirst(
    RegExp(r'^[A-Za-z]+Exception: '),
    '',
  );
  return text.length > 180 ? '${text.substring(0, 180)}…' : text;
}
