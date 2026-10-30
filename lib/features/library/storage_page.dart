import '../../l10n/app_strings.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../data/android_media/android_media_bridge.dart';
import '../../services/files/storage_insights.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/media_tile.dart';
import 'analysis_page.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({required this.model, super.key});

  final GalleryModel model;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  AndroidStorageStats? _device;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      AndroidMediaBridge.instance
          .getStorageStats()
          .then((value) {
            if (mounted) setState(() => _device = value);
          })
          .catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const AppText('Storage')),
    body: AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final items = widget.model is GalleryTools
            ? (widget.model as GalleryTools).localItems
            : widget.model.items;
        final insights = analyzeStorage(items, now: DateTime.now());
        final categories =
            widget.model.categories
                .where((category) => category.itemCount > 0)
                .toList()
              ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
        final scheme = Theme.of(context).colorScheme;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_device case final device?)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppText(
                        'Phone storage',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: device.shared.totalBytes == 0
                            ? null
                            : device.shared.usedBytes /
                                  device.shared.totalBytes,
                        minHeight: 10,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${formatBytes(device.shared.usedBytes)} used of '
                        '${formatBytes(device.shared.totalBytes)} · '
                        '${formatBytes(device.shared.availableBytes)} free',
                      ),
                    ],
                  ),
                ),
              ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your library · ${formatBytes(insights.totalBytes)}',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 12),
                    for (final category in categories)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(child: Text(_label(category.kind))),
                                Text(
                                  '${category.itemCount} · ${formatBytes(category.totalBytes)}',
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: insights.totalBytes == 0
                                  ? 0
                                  : category.totalBytes / insights.totalBytes,
                              color: scheme.primary,
                              minHeight: 6,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            AppText(
              'Biggest folders',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final folder in insights.folders)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  folder.folder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${folder.count} items'),
                trailing: Text(formatBytes(folder.bytes)),
              ),
            const SizedBox(height: 12),
            AppText(
              'Free up space',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (insights.suggestions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: AppText('No cleanup suggestions right now.'),
              ),
            for (final suggestion in insights.suggestions)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.cleaning_services_outlined),
                  title: Text(suggestion.title),
                  subtitle: Text(
                    '${suggestion.description}\n'
                    '${suggestion.items.length} items · ${formatBytes(suggestion.bytes)}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CleanupReviewPage(
                        model: widget.model,
                        title: suggestion.title,
                        items: suggestion.items,
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.model is GalleryTools)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.content_copy_rounded),
                  title: const AppText('Duplicates and similar photos'),
                  subtitle: const AppText(
                    'Scan for exact copies and look-alikes',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AnalysisPage(
                        kind: AnalysisKind.cleanup,
                        model: widget.model,
                        tools: widget.model as GalleryTools,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// Review-before-delete list. Nothing is selected by default.
class CleanupReviewPage extends StatefulWidget {
  const CleanupReviewPage({
    required this.model,
    required this.title,
    required this.items,
    super.key,
  });

  final GalleryModel model;
  final String title;
  final List<MediaItem> items;

  @override
  State<CleanupReviewPage> createState() => _CleanupReviewPageState();
}

class _CleanupReviewPageState extends State<CleanupReviewPage> {
  final _selected = <String>{};
  final _removed = <String>{};
  bool _busy = false;

  Future<void> _trash(List<MediaItem> items) async {
    final chosen = items.where((item) => _selected.contains(item.id)).toList();
    final bytes = chosen.fold<int>(0, (sum, v) => sum + v.metadata.sizeBytes);
    final confirmed = await confirmAction(
      context,
      title: 'Move ${chosen.length} items to Trash?',
      message:
          'This frees about ${formatBytes(bytes)} once Trash is emptied. You can restore items from Trash.',
      action: 'Move to Trash',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final model = widget.model;
      if (model is GalleryOrganizer) {
        await (model as GalleryOrganizer).moveAllToTrash(chosen);
      } else {
        for (final item in chosen) {
          await model.moveToTrash(item);
        }
      }
      _removed.addAll(chosen.map((item) => item.id));
      _selected.clear();
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.model,
    builder: (context, _) {
      final items = widget.items
          .where(
            (item) =>
                !_removed.contains(item.id) &&
                widget.model.canAccessMedia(item),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      if (_selected.length == items.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(items.map((item) => item.id));
                      }
                    }),
              child: Text(
                _selected.length == items.length && items.isNotEmpty
                    ? 'Clear'
                    : 'Select all',
              ),
            ),
          ],
        ),
        floatingActionButton: _selected.isEmpty
            ? null
            : FloatingActionButton.extended(
                onPressed: _busy ? null : () => _trash(items),
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text('Move ${_selected.length} to Trash'),
              ),
        body: ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return CheckboxListTile(
              value: _selected.contains(item.id),
              onChanged: _busy
                  ? null
                  : (value) => setState(
                      () => value == true
                          ? _selected.add(item.id)
                          : _selected.remove(item.id),
                    ),
              secondary: SizedBox.square(
                dimension: 52,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: MediaThumbnail(item: item, model: widget.model),
                ),
              ),
              title: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${formatBytes(item.metadata.sizeBytes)} · ${item.relativePath}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            );
          },
        ),
      );
    },
  );
}

String _label(MediaKind kind) => switch (kind) {
  MediaKind.image => 'Photos',
  MediaKind.video => 'Videos',
  MediaKind.document => 'Documents',
  MediaKind.audio => 'Audio',
  MediaKind.apk => 'APKs',
  MediaKind.archive => 'Archives',
  MediaKind.other => 'Other',
};
