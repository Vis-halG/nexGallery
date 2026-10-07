import 'package:flutter/services.dart';

/// Narrow access to the Windows runner's native folder dialog and file IDs.
/// Cancelled dialogs return null; native failures remain visible to the caller.
final class WindowsFilesBridge {
  const WindowsFilesBridge({
    this.channel = const MethodChannel('nexgallery/windows_files'),
  });

  final MethodChannel channel;

  Future<String?> chooseFolder() async {
    final path = await channel.invokeMethod<String>('chooseFolder');
    return path == null || path.trim().isEmpty ? null : path;
  }

  /// Volume, file ID and creation timestamp survive same-volume renames.
  /// Unreadable/unsupported files are omitted, allowing path-based fallback.
  Future<Map<String, String>> fileIdentities(Iterable<String> paths) async {
    final pending = paths.toSet().toList(growable: false);
    final result = <String, String>{};
    for (var offset = 0; offset < pending.length; offset += 256) {
      final end = (offset + 256).clamp(0, pending.length);
      final batch = pending.sublist(offset, end);
      final values = await channel.invokeMapMethod<String, String>(
        'fileIdentities',
        <String, Object>{'paths': batch},
      );
      if (values != null) result.addAll(values);
    }
    return Map<String, String>.unmodifiable(result);
  }
}
