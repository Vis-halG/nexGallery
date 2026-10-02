import '../core/media_item.dart';

final class ScanCancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

final class ScanOptions {
  ScanOptions({
    this.source = MediaSource.pc,
    this.maxDepth = 32,
    this.maxFiles = 250000,
    this.maxDirectories = 50000,
    this.includeHidden = false,
    this.progressEveryFiles = 100,
    Iterable<MediaKind> kinds = const <MediaKind>[],
  }) : assert(maxDepth >= 0),
       assert(maxFiles > 0),
       assert(maxDirectories > 0),
       assert(progressEveryFiles > 0),
       kinds = Set<MediaKind>.unmodifiable(kinds);

  final MediaSource source;
  final int maxDepth;
  final int maxFiles;
  final int maxDirectories;
  final bool includeHidden;
  final int progressEveryFiles;
  final Set<MediaKind> kinds;
}

final class ScanProgress {
  const ScanProgress({
    required this.currentPath,
    required this.filesVisited,
    required this.directoriesVisited,
    required this.itemsFound,
    required this.errorCount,
    required this.isCancelled,
    required this.stoppedByLimit,
  });

  final String currentPath;
  final int filesVisited;
  final int directoriesVisited;
  final int itemsFound;
  final int errorCount;
  final bool isCancelled;
  final bool stoppedByLimit;
}

final class ScanIssue {
  const ScanIssue({required this.path, required this.message});

  final String path;
  final String message;
}

final class ScanResult {
  ScanResult({
    required Iterable<MediaItem> items,
    required Iterable<ScanIssue> issues,
    required this.filesVisited,
    required this.directoriesVisited,
    required this.wasCancelled,
    required this.stoppedByLimit,
  }) : items = List<MediaItem>.unmodifiable(items),
       issues = List<ScanIssue>.unmodifiable(issues);

  final List<MediaItem> items;
  final List<ScanIssue> issues;
  final int filesVisited;
  final int directoriesVisited;
  final bool wasCancelled;
  final bool stoppedByLimit;
}

abstract interface class LocalMediaScanner {
  bool get isSupported;

  Future<ScanResult> scan(
    Iterable<String> rootPaths, {
    ScanOptions? options,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  });
}
