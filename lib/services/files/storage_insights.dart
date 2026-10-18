import '../../core/media_item.dart';

final class FolderUsage {
  const FolderUsage(this.folder, this.bytes, this.count);
  final String folder;
  final int bytes;
  final int count;
}

final class CleanupSuggestion {
  const CleanupSuggestion({
    required this.id,
    required this.title,
    required this.description,
    required this.items,
  });

  final String id;
  final String title;
  final String description;

  /// Largest first.
  final List<MediaItem> items;

  int get bytes => items.fold(0, (sum, item) => sum + item.metadata.sizeBytes);
}

final class StorageInsights {
  const StorageInsights({
    required this.totalBytes,
    required this.folders,
    required this.suggestions,
  });

  final int totalBytes;
  final List<FolderUsage> folders;
  final List<CleanupSuggestion> suggestions;
}

/// Summarizes library usage and review-only cleanup ideas. Nothing is deleted
/// here; the user chooses items to move to Trash.
StorageInsights analyzeStorage(
  Iterable<MediaItem> source, {
  required DateTime now,
  int largeFileBytes = 100 * 1024 * 1024,
}) {
  final items = source
      .where((item) => item.isAvailable && item.section != MediaSection.trash)
      .toList();
  final folders = <String, (int, int)>{};
  var total = 0;
  for (final item in items) {
    total += item.metadata.sizeBytes;
    final folder = _folder(item);
    final current = folders[folder] ?? (0, 0);
    folders[folder] = (current.$1 + item.metadata.sizeBytes, current.$2 + 1);
  }
  final ranked =
      folders.entries
          .map((e) => FolderUsage(e.key, e.value.$1, e.value.$2))
          .toList()
        ..sort((a, b) => b.bytes.compareTo(a.bytes));

  bool olderThan(MediaItem item, int days) =>
      now.difference(item.metadata.modifiedAt).inDays >= days;
  bool inFolder(MediaItem item, String name) => item.relativePath
      .replaceAll('\\', '/')
      .toLowerCase()
      .split('/')
      .any((part) => part == name || part == '${name}s');

  List<MediaItem> largestFirst(Iterable<MediaItem> values) =>
      values.toList()
        ..sort((a, b) => b.metadata.sizeBytes.compareTo(a.metadata.sizeBytes));

  final suggestions = <CleanupSuggestion>[
    CleanupSuggestion(
      id: 'large',
      title: 'Large files',
      description: 'Files of ${largeFileBytes ~/ (1024 * 1024)} MB or more',
      items: largestFirst(
        items.where((item) => item.metadata.sizeBytes >= largeFileBytes),
      ),
    ),
    CleanupSuggestion(
      id: 'old-downloads',
      title: 'Old downloads',
      description: 'In Download folders and unchanged for 90 days',
      items: largestFirst(
        items.where(
          (item) => inFolder(item, 'download') && olderThan(item, 90),
        ),
      ),
    ),
    CleanupSuggestion(
      id: 'old-screenshots',
      title: 'Old screenshots',
      description: 'Screenshots older than 30 days',
      items: largestFirst(
        items.where(
          (item) =>
              item.kind == MediaKind.image &&
              (inFolder(item, 'screenshot') ||
                  item.name.toLowerCase().startsWith('screenshot')) &&
              olderThan(item, 30),
        ),
      ),
    ),
    CleanupSuggestion(
      id: 'installers',
      title: 'App installers',
      description: 'APK files that are usually no longer needed after install',
      items: largestFirst(items.where((item) => item.kind == MediaKind.apk)),
    ),
  ].where((suggestion) => suggestion.items.isNotEmpty).toList();
  return StorageInsights(
    totalBytes: total,
    folders: ranked.take(8).toList(),
    suggestions: suggestions,
  );
}

String _folder(MediaItem item) {
  // PC paths include the file name; Android paths name only the folder.
  final parts = item.relativePath
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isNotEmpty && parts.last == item.name) parts.removeLast();
  if (parts.isEmpty) return 'Top level';
  return parts.take(2).join('/');
}
