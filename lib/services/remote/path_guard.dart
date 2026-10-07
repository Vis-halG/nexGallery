import 'dart:io';

final class RemotePathException implements Exception {
  const RemotePathException(this.message, {this.statusCode = 400});

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

final class AllowedRoot {
  const AllowedRoot({
    required this.id,
    required this.directory,
    required this.canonicalPath,
  });

  final String id;
  final Directory directory;
  final String canonicalPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': directory.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .lastOrNull,
  };
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

/// Resolves API paths only inside explicitly configured roots.
///
/// Existing paths are resolved through the operating system so links cannot
/// escape a root. For a new target, the nearest existing ancestor is resolved
/// before the missing suffix is appended and checked. Reserved server paths
/// are never exposed through the public file API.
final class PathGuard {
  PathGuard._(this.roots);

  final Map<String, AllowedRoot> roots;

  static Future<PathGuard> create(Map<String, String> configuredRoots) async {
    if (configuredRoots.isEmpty) {
      throw ArgumentError('At least one allowed root is required.');
    }
    final result = <String, AllowedRoot>{};
    for (final entry in configuredRoots.entries) {
      if (!RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(entry.key)) {
        throw ArgumentError.value(
          entry.key,
          'root id',
          'Use letters, digits, _ or -.',
        );
      }
      if (result.containsKey(entry.key)) {
        throw ArgumentError('Duplicate root id: ${entry.key}');
      }
      final directory = Directory(entry.value).absolute;
      if (!await directory.exists()) {
        throw ArgumentError('Allowed root does not exist: ${entry.value}');
      }
      final canonical = await directory.resolveSymbolicLinks();
      result[entry.key] = AllowedRoot(
        id: entry.key,
        directory: Directory(canonical),
        canonicalPath: canonical,
      );
    }
    return PathGuard._(Map<String, AllowedRoot>.unmodifiable(result));
  }

  AllowedRoot root(String id) {
    final value = roots[id];
    if (value == null) {
      throw const RemotePathException('Unknown root.', statusCode: 404);
    }
    return value;
  }

  Future<String> resolve(
    String rootId,
    String relativePath, {
    bool mustExist = true,
    bool allowRoot = true,
    bool allowInternal = false,
  }) async {
    final allowedRoot = root(rootId);
    final segments = normalizeSegments(
      relativePath,
      allowInternal: allowInternal,
    );
    if (segments.isEmpty && !allowRoot) {
      throw const RemotePathException('A non-root path is required.');
    }
    final candidate = _join(allowedRoot.canonicalPath, segments);
    final type = await FileSystemEntity.type(candidate, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      final canonical = await _resolveExisting(candidate, type);
      _requireContained(allowedRoot.canonicalPath, canonical);
      if (!allowInternal) {
        _requirePublicPath(allowedRoot.canonicalPath, canonical);
      }
      return canonical;
    }
    if (mustExist) {
      throw const RemotePathException('Path was not found.', statusCode: 404);
    }

    var ancestor = candidate;
    final missing = <String>[];
    while (await FileSystemEntity.type(ancestor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = File(ancestor).parent.path;
      if (_samePath(parent, ancestor)) {
        throw const RemotePathException('Path has no existing parent.');
      }
      missing.insert(0, _basename(ancestor));
      ancestor = parent;
    }
    final ancestorType = await FileSystemEntity.type(
      ancestor,
      followLinks: false,
    );
    final canonicalAncestor = await _resolveExisting(ancestor, ancestorType);
    _requireContained(allowedRoot.canonicalPath, canonicalAncestor);
    if (!allowInternal) {
      _requirePublicPath(allowedRoot.canonicalPath, canonicalAncestor);
    }
    final resolvedCandidate = _join(canonicalAncestor, missing);
    _requireContained(allowedRoot.canonicalPath, resolvedCandidate);
    return resolvedCandidate;
  }

  List<String> normalizeSegments(
    String relativePath, {
    bool allowInternal = false,
  }) {
    if (relativePath.length > 4096) {
      throw const RemotePathException('Path is too long.');
    }
    if (relativePath.contains('\u0000')) {
      throw const RemotePathException('Path contains an invalid character.');
    }
    final normalized = relativePath.replaceAll('\\', '/').trim();
    if (normalized.startsWith('/') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(normalized) ||
        normalized.startsWith('//')) {
      throw const RemotePathException('Absolute paths are not allowed.');
    }
    if (normalized.isEmpty) {
      return const <String>[];
    }
    final result = <String>[];
    for (final segment in normalized.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        throw const RemotePathException(
          'Parent path segments are not allowed.',
        );
      }
      if (Platform.isWindows && segment.contains(':')) {
        throw const RemotePathException('Invalid Windows path segment.');
      }
      if (!allowInternal && segment.toLowerCase().startsWith('.nexgallery-')) {
        throw const RemotePathException('Reserved server path.');
      }
      result.add(segment);
    }
    return result;
  }

  String relative(String rootId, String absolutePath) {
    final rootPath = root(rootId).canonicalPath;
    _requireContained(rootPath, absolutePath);
    if (_samePath(rootPath, absolutePath)) {
      return '';
    }
    return _relativeSuffix(rootPath, absolutePath);
  }

  bool containsAbsolutePath(String absolutePath) {
    for (final root in roots.values) {
      try {
        _requireContained(root.canonicalPath, absolutePath);
        return true;
      } on RemotePathException {
        // Check the next configured root.
      }
    }
    return false;
  }

  static Future<String> _resolveExisting(
    String path,
    FileSystemEntityType type,
  ) {
    return switch (type) {
      FileSystemEntityType.directory => Directory(path).resolveSymbolicLinks(),
      FileSystemEntityType.link => Link(path).resolveSymbolicLinks(),
      _ => File(path).resolveSymbolicLinks(),
    };
  }

  static String _join(String base, List<String> segments) {
    var value = base;
    for (final segment in segments) {
      value = '$value${Platform.pathSeparator}$segment';
    }
    return value;
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final pieces = normalized.split('/');
    return pieces.lastWhere((piece) => piece.isNotEmpty, orElse: () => '');
  }

  static void _requireContained(String root, String candidate) {
    final comparableRoot = _comparable(root);
    final comparableCandidate = _comparable(candidate);
    final containmentPrefix = _hasTrailingSeparator(comparableRoot)
        ? comparableRoot
        : '$comparableRoot${Platform.pathSeparator}';
    if (comparableCandidate != comparableRoot &&
        !comparableCandidate.startsWith(containmentPrefix)) {
      throw const RemotePathException(
        'Path escapes the allowed root.',
        statusCode: 403,
      );
    }
  }

  static void _requirePublicPath(String root, String candidate) {
    if (_samePath(root, candidate)) return;
    final relative = _relativeSuffix(root, candidate);
    if (relative
        .split('/')
        .any((segment) => segment.toLowerCase().startsWith('.nexgallery-'))) {
      throw const RemotePathException('Reserved server path.');
    }
  }

  static bool _samePath(String first, String second) =>
      _comparable(first) == _comparable(second);

  static String _relativeSuffix(String root, String candidate) {
    final offset = _hasTrailingSeparator(root) ? root.length : root.length + 1;
    return candidate.substring(offset).replaceAll('\\', '/');
  }

  static bool _hasTrailingSeparator(String path) =>
      path.endsWith('/') || path.endsWith('\\');

  static String _comparable(String path) {
    var value = Directory(path).absolute.path;
    while (value.length > 1 &&
        (value.endsWith('/') || value.endsWith('\\')) &&
        !RegExp(r'^[a-zA-Z]:[\\/]$').hasMatch(value)) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }
}
