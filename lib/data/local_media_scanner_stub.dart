import 'local_media_scanner_types.dart';

LocalMediaScanner createLocalMediaScanner() => const _UnsupportedMediaScanner();

final class _UnsupportedMediaScanner implements LocalMediaScanner {
  const _UnsupportedMediaScanner();

  @override
  bool get isSupported => false;

  @override
  Future<ScanResult> scan(
    Iterable<String> rootPaths, {
    ScanOptions? options,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async => ScanResult(
    items: const [],
    issues: const <ScanIssue>[
      ScanIssue(
        path: '',
        message: 'Directory scanning is unavailable on this platform.',
      ),
    ],
    filesVisited: 0,
    directoriesVisited: 0,
    wasCancelled: cancellationToken?.isCancelled ?? false,
    stoppedByLimit: false,
  );
}
