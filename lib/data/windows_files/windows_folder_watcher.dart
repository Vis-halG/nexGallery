import 'dart:async';
import 'dart:io';

enum WindowsFolderChangeReason {
  filesystem,
  availability,
  reconciliation,
  watcherError,
}

/// An invalidation, never an authoritative snapshot or a request to delete.
final class WindowsFolderChange {
  WindowsFolderChange({
    required Iterable<String> roots,
    required Iterable<String> unavailableRoots,
    required this.reason,
  }) : roots = Set<String>.unmodifiable(roots),
       unavailableRoots = Set<String>.unmodifiable(unavailableRoots);

  final Set<String> roots;
  final Set<String> unavailableRoots;
  final WindowsFolderChangeReason reason;
}

typedef WindowsDirectoryExists = Future<bool> Function(String path);
typedef WindowsDirectoryEvents = Stream<FileSystemEvent> Function(String path);

/// Watches only explicitly selected roots. Bursts are debounced with an upper
/// delay bound; periodic invalidations recover from lost native events. Missing
/// roots remain registered and are retried when a drive reconnects.
final class WindowsFolderWatcher {
  WindowsFolderWatcher({
    this.debounce = const Duration(milliseconds: 500),
    this.maximumDelay = const Duration(seconds: 3),
    this.reconciliationInterval = const Duration(seconds: 30),
    this.availabilityInterval = const Duration(seconds: 10),
    WindowsDirectoryExists? exists,
    WindowsDirectoryEvents? watch,
  }) : assert(debounce > Duration.zero),
       assert(maximumDelay >= debounce),
       assert(reconciliationInterval > Duration.zero),
       assert(availabilityInterval > Duration.zero),
       _exists = exists ?? ((path) => Directory(path).exists()),
       _watch = watch ?? ((path) => Directory(path).watch(recursive: true));

  final Duration debounce;
  final Duration maximumDelay;
  final Duration reconciliationInterval;
  final Duration availabilityInterval;
  final WindowsDirectoryExists _exists;
  final WindowsDirectoryEvents _watch;
  final _changes = StreamController<WindowsFolderChange>.broadcast();
  final _roots = <String, _RootWatch>{};
  final _pending = <String>{};
  Set<String> _ignoredPaths = <String>{};
  Timer? _debounceTimer;
  Timer? _maximumDelayTimer;
  Timer? _reconciliationTimer;
  Timer? _availabilityTimer;
  WindowsFolderChangeReason _pendingReason =
      WindowsFolderChangeReason.filesystem;
  bool _checking = false;
  bool _checkAgain = false;
  bool _disposed = false;
  int _selectionGeneration = 0;

  Stream<WindowsFolderChange> get changes => _changes.stream;

  Set<String> get unavailableRoots => Set<String>.unmodifiable(
    _roots.values
        .where((root) => root.available == false)
        .map((root) => root.path),
  );

  Future<void> watchSelectedRoots(
    Iterable<String> selectedRoots, {
    Iterable<String> ignoredPaths = const <String>[],
  }) async {
    if (_disposed) return;
    final generation = ++_selectionGeneration;
    _ignoredPaths = ignoredPaths
        .where((path) => path.trim().isNotEmpty)
        .map((path) => _key(Directory(path.trim()).absolute.path))
        .toSet();
    final requested = <String, String>{};
    for (final path in selectedRoots) {
      if (path.trim().isEmpty) continue;
      final absolute = Directory(path.trim()).absolute.path;
      if (_withinIgnoredPath(absolute)) continue;
      requested[_key(absolute)] = absolute;
    }
    for (final key in _roots.keys.toList()) {
      if (requested.containsKey(key)) continue;
      final removed = _roots.remove(key)!;
      _pending.remove(removed.path);
      await removed.subscription?.cancel();
      if (_disposed || generation != _selectionGeneration) return;
    }
    for (final entry in requested.entries) {
      _roots.putIfAbsent(entry.key, () => _RootWatch(entry.value));
    }
    if (_roots.isEmpty) {
      _cancelTimers();
      _pending.clear();
      _pendingReason = WindowsFolderChangeReason.filesystem;
      return;
    }
    _reconciliationTimer ??= Timer.periodic(reconciliationInterval, (_) {
      if (_disposed || _roots.isEmpty) return;
      for (final root in _roots.values) {
        _queue(root.path, WindowsFolderChangeReason.reconciliation);
      }
      unawaited(_checkAvailability());
    });
    _availabilityTimer ??= Timer.periodic(availabilityInterval, (_) {
      unawaited(_checkAvailability());
    });
    await _checkAvailability();
  }

  Future<void> _checkAvailability() async {
    if (_disposed) return;
    if (_checking) {
      _checkAgain = true;
      return;
    }
    _checking = true;
    try {
      for (final root in _roots.values.toList(growable: false)) {
        bool available;
        try {
          available = await _exists(root.path);
        } catch (_) {
          available = false;
        }
        if (!_isCurrent(root)) continue;
        final previous = root.available;
        root.available = available;
        if (previous != available && (previous != null || !available)) {
          _queue(root.path, WindowsFolderChangeReason.availability);
        }
        if (!available) {
          final subscription = root.subscription;
          root.subscription = null;
          await subscription?.cancel();
        } else if (root.subscription == null) {
          _attach(root);
        }
      }
    } finally {
      _checking = false;
      if (_checkAgain && !_disposed) {
        _checkAgain = false;
        await _checkAvailability();
      }
    }
  }

  void _attach(_RootWatch root) {
    try {
      root.subscription = _watch(root.path).listen(
        (event) {
          if (!_isCurrent(root)) return;
          // A staging rename into a final filename must invalidate the library.
          if (_isIgnored(event.path) &&
              (event is! FileSystemMoveEvent ||
                  event.destination == null ||
                  _isIgnored(event.destination!))) {
            return;
          }
          _queue(root.path, WindowsFolderChangeReason.filesystem);
        },
        onError: (Object error, StackTrace stack) => _watchEnded(root),
        onDone: () => _watchEnded(root),
        cancelOnError: true,
      );
    } catch (_) {
      _watchEnded(root);
    }
  }

  void _watchEnded(_RootWatch root) {
    if (!_isCurrent(root)) return;
    final subscription = root.subscription;
    root.subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    _queue(root.path, WindowsFolderChangeReason.watcherError);
  }

  bool _isCurrent(_RootWatch root) =>
      !_disposed && identical(_roots[_key(root.path)], root);

  void _queue(String path, WindowsFolderChangeReason reason) {
    if (_disposed || !_roots.containsKey(_key(path))) return;
    _pending.add(path);
    // Preserve status events when a later file event joins the same burst.
    if (reason.index > _pendingReason.index) _pendingReason = reason;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, _flush);
    _maximumDelayTimer ??= Timer(maximumDelay, _flush);
  }

  void _flush() {
    _debounceTimer?.cancel();
    _maximumDelayTimer?.cancel();
    _debounceTimer = null;
    _maximumDelayTimer = null;
    if (_disposed || _pending.isEmpty) return;
    _changes.add(
      WindowsFolderChange(
        roots: _pending,
        unavailableRoots: unavailableRoots,
        reason: _pendingReason,
      ),
    );
    _pending.clear();
    _pendingReason = WindowsFolderChangeReason.filesystem;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelTimers();
    final subscriptions = _roots.values
        .map((root) => root.subscription)
        .whereType<StreamSubscription<FileSystemEvent>>()
        .toList(growable: false);
    _roots.clear();
    _pending.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    await _changes.close();
  }

  void _cancelTimers() {
    _debounceTimer?.cancel();
    _maximumDelayTimer?.cancel();
    _reconciliationTimer?.cancel();
    _availabilityTimer?.cancel();
    _debounceTimer = null;
    _maximumDelayTimer = null;
    _reconciliationTimer = null;
    _availabilityTimer = null;
  }

  static String _key(String path) {
    final normalized = path
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  bool _isIgnored(String path) =>
      _withinIgnoredPath(path) ||
      path
          .replaceAll('\\', '/')
          .toLowerCase()
          .split('/')
          .any(
            (segment) =>
                segment.endsWith('.part') || segment.startsWith('.nexgallery-'),
          );

  bool _withinIgnoredPath(String path) {
    final normalized = _key(path);
    return _ignoredPaths.any(
      (ignored) => normalized == ignored || normalized.startsWith('$ignored/'),
    );
  }
}

final class _RootWatch {
  _RootWatch(this.path);

  final String path;
  bool? available;
  StreamSubscription<FileSystemEvent>? subscription;
}
