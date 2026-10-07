import 'dart:io';

import '../core/media_item.dart';
import 'local_media_scanner_types.dart';

LocalMediaScanner createLocalMediaScanner() => const _IoLocalMediaScanner();

final class _IoLocalMediaScanner implements LocalMediaScanner {
  const _IoLocalMediaScanner();

  @override
  bool get isSupported => true;

  @override
  Future<ScanResult> scan(
    Iterable<String> rootPaths, {
    ScanOptions? options,
    ScanCancellationToken? cancellationToken,
    void Function(ScanProgress progress)? onProgress,
  }) async {
    final settings = options ?? ScanOptions();
    final cancellation = cancellationToken ?? ScanCancellationToken();
    final excludedPaths = settings.excludedPaths.map((path) =>
      _normalizedPath(Directory(path).absolute.path).replaceAll(RegExp(r'/+$'), '')).toList();
    bool excluded(String path) {
      final normalized = _normalizedPath(File(path).absolute.path);
      return excludedPaths.any((root) => normalized == root || normalized.startsWith('$root/'));
    }
    final roots = rootPaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .map((path) => Directory(path).absolute.path)
        .toSet()
        .toList(growable: false);
    final items = <MediaItem>[];
    final issues = <ScanIssue>[];
    final visitedPaths = <String>{};
    var filesVisited = 0;
    var directoriesVisited = 0;
    var stoppedByLimit = false;
    var currentPath = '';

    void report() {
      if (onProgress == null) return;
      try {
        onProgress(
          ScanProgress(
            currentPath: currentPath,
            filesVisited: filesVisited,
            directoriesVisited: directoriesVisited,
            itemsFound: items.length,
            errorCount: issues.length,
            isCancelled: cancellation.isCancelled,
            stoppedByLimit: stoppedByLimit,
          ),
        );
      } catch (_) {
        // A presentation callback cannot invalidate a filesystem scan.
      }
    }

    report();
    scanRoots:
    for (final rootPath in roots) {
      if (excluded(rootPath)) continue;
      if (cancellation.isCancelled) break;
      final root = Directory(rootPath);
      currentPath = root.path;
      if (!await root.exists()) {
        issues.add(ScanIssue(path: root.path, message: 'Directory not found.'));
        report();
        continue;
      }

      final queue = <_PendingDirectory>[_PendingDirectory(root, 0)];
      var queueIndex = 0;
      while (queueIndex < queue.length) {
        if (cancellation.isCancelled) break scanRoots;
        if (directoriesVisited >= settings.maxDirectories) {
          stoppedByLimit = true;
          break scanRoots;
        }

        final pending = queue[queueIndex++];
        currentPath = pending.directory.path;
        directoriesVisited += 1;
        try {
          await for (final entity in pending.directory.list(
            followLinks: false,
          )) {
            if (cancellation.isCancelled) break scanRoots;
            final name = _basename(entity.path);
            if (excluded(entity.path)) continue;
            // Transfer staging files and private protocol state are never
            // presented as completed files, including in hidden-file mode.
            final lowerName = name.toLowerCase();
            if (lowerName.endsWith('.part') ||
                lowerName.startsWith('.nexgallery-')) {
              continue;
            }
            if (!settings.includeHidden && _isHiddenOrSystemName(name)) {
              continue;
            }

            final type = await FileSystemEntity.type(
              entity.path,
              followLinks: false,
            );
            if (type == FileSystemEntityType.directory) {
              if (pending.depth < settings.maxDepth) {
                if (queue.length < settings.maxDirectories) {
                  queue.add(
                    _PendingDirectory(
                      Directory(entity.path),
                      pending.depth + 1,
                    ),
                  );
                } else {
                  stoppedByLimit = true;
                }
              } else {
                stoppedByLimit = true;
              }
              continue;
            }
            if (type != FileSystemEntityType.file) continue;
            if (filesVisited >= settings.maxFiles) {
              stoppedByLimit = true;
              break scanRoots;
            }

            filesVisited += 1;
            currentPath = entity.path;
            final normalizedPath = _normalizedPath(entity.absolute.path);
            if (!visitedPaths.add(normalizedPath)) continue;
            final extension = _extensionOf(name);
            final kind = mediaKindForExtension(extension);
            if (settings.kinds.isNotEmpty && !settings.kinds.contains(kind)) {
              if (filesVisited % settings.progressEveryFiles == 0) report();
              continue;
            }

            try {
              final file = File(entity.path);
              final stat = await file.stat();
              items.add(
                MediaItem(
                  id: _stableId('${settings.source.name}:$normalizedPath'),
                  name: name,
                  uri: file.absolute.uri.toString(),
                  relativePath: _relativePath(root.path, file.absolute.path),
                  kind: kind,
                  source: settings.source,
                  metadata: MediaMetadata(
                    sizeBytes: stat.size,
                    modifiedAt: stat.modified.toUtc(),
                    createdAt: stat.changed.toUtc(),
                    mimeType: mimeTypeForExtension(extension),
                    extension: extension.isEmpty ? null : extension,
                    attributes: <String, String>{'rootPath': root.path},
                  ),
                  indexedAt: DateTime.now().toUtc(),
                ),
              );
            } on FileSystemException catch (error) {
              issues.add(ScanIssue(path: entity.path, message: error.message));
            }
            if (filesVisited % settings.progressEveryFiles == 0) report();
          }
        } on FileSystemException catch (error) {
          issues.add(
            ScanIssue(path: pending.directory.path, message: error.message),
          );
        }
        report();
      }
    }

    report();
    return ScanResult(
      items: items,
      issues: issues,
      filesVisited: filesVisited,
      directoriesVisited: directoriesVisited,
      wasCancelled: cancellation.isCancelled,
      stoppedByLimit: stoppedByLimit,
    );
  }
}

final class _PendingDirectory {
  const _PendingDirectory(this.directory, this.depth);

  final Directory directory;
  final int depth;
}

MediaKind mediaKindForExtension(String extension) {
  final normalized = extension.toLowerCase();
  if (_imageExtensions.contains(normalized)) return MediaKind.image;
  if (_videoExtensions.contains(normalized)) return MediaKind.video;
  if (_audioExtensions.contains(normalized)) return MediaKind.audio;
  if (normalized == 'apk' || normalized == 'xapk' || normalized == 'apks') {
    return MediaKind.apk;
  }
  if (_archiveExtensions.contains(normalized)) return MediaKind.archive;
  if (_documentExtensions.contains(normalized)) return MediaKind.document;
  return MediaKind.other;
}

String? mimeTypeForExtension(String extension) =>
    _mimeTypes[extension.toLowerCase()];

const Set<String> _imageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'tif',
  'tiff',
  'heic',
  'heif',
  'avif',
  'dng',
  'raw',
  'cr2',
  'cr3',
  'nef',
  'arw',
  'orf',
  'rw2',
  'svg',
};
const Set<String> _videoExtensions = <String>{
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'avi',
  'webm',
  'wmv',
  'flv',
  '3gp',
  '3g2',
  'mpeg',
  'mpg',
  'mts',
  'm2ts',
  'ts',
  'vob',
};
const Set<String> _audioExtensions = <String>{
  'mp3',
  'm4a',
  'aac',
  'wav',
  'flac',
  'ogg',
  'oga',
  'opus',
  'wma',
  'amr',
  'aiff',
  'aif',
  'mid',
  'midi',
};
const Set<String> _archiveExtensions = <String>{
  'zip',
  'rar',
  '7z',
  'tar',
  'gz',
  'gzip',
  'bz2',
  'xz',
  'tgz',
  'cab',
  'iso',
};
const Set<String> _documentExtensions = <String>{
  'pdf',
  'txt',
  'md',
  'rtf',
  'csv',
  'log',
  'json',
  'xml',
  'yaml',
  'yml',
  'doc',
  'docx',
  'odt',
  'xls',
  'xlsx',
  'ods',
  'ppt',
  'pptx',
  'odp',
  'epub',
  'mobi',
  'azw',
  'azw3',
  'html',
  'htm',
};

const Map<String, String> _mimeTypes = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
  'svg': 'image/svg+xml',
  'mp4': 'video/mp4',
  'm4v': 'video/x-m4v',
  'mov': 'video/quicktime',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'avi': 'video/x-msvideo',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'json': 'application/json',
  'xml': 'application/xml',
  'csv': 'text/csv',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'apk': 'application/vnd.android.package-archive',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
};

String _extensionOf(String name) {
  final index = name.lastIndexOf('.');
  if (index <= 0 || index == name.length - 1) return '';
  return name.substring(index + 1).toLowerCase();
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

bool _isHiddenOrSystemName(String name) {
  final normalized = name.toLowerCase();
  return name.startsWith('.') ||
      normalized == r'$recycle.bin' ||
      normalized == 'system volume information';
}

String _normalizedPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

String _relativePath(String rootPath, String filePath) {
  final root = rootPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final file = filePath.replaceAll('\\', '/');
  final comparableRoot = Platform.isWindows ? root.toLowerCase() : root;
  final comparableFile = Platform.isWindows ? file.toLowerCase() : file;
  if (comparableFile == comparableRoot) return _basename(filePath);
  if (comparableFile.startsWith('$comparableRoot/')) {
    return file.substring(root.length + 1);
  }
  return _basename(filePath);
}

String _stableId(String value) {
  var first = 0x811c9dc5;
  var second = 0x9e3779b9;
  for (final unit in value.codeUnits) {
    first = ((first ^ unit) * 0x01000193) & 0xffffffff;
    second = ((second ^ unit) * 0x85ebca6b) & 0xffffffff;
  }
  return 'local_${first.toRadixString(16).padLeft(8, '0')}'
      '${second.toRadixString(16).padLeft(8, '0')}';
}
