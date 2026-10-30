import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';
import '../../data/windows_files/windows_files_bridge.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import 'android_saf_browser.dart';
import 'windows_file_browser.dart';
import '../common/catalog_page_footer.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({required this.model, required this.isWindows, super.key});

  final GalleryModel model;
  final bool isWindows;

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final _pathController = TextEditingController();
  final _windowsFiles = const WindowsFilesBridge();
  bool _choosingFolder = false;
  String? _folderError;

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) => SafeArea(
        child: CustomScrollView(
          key: const PageStorageKey('files'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                _padding(context),
                20,
                _padding(context),
                14,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppText(
                      'Files',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.6,
                          ),
                    ),
                    Text(
                      widget.isWindows
                          ? 'Index only folders you choose'
                          : 'Phone media grouped by file type',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (widget.isWindows) ...[
                      const SizedBox(height: 18),
                      _folderInput(context),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                WindowsFileBrowser(model: widget.model),
                          ),
                        ),
                        icon: const Icon(Icons.folder_open),
                        label: const AppText(
                          'Browse folders · Copy, move and ZIP',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: _padding(context)),
              sliver: SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.apps_rounded, size: 18),
                        label: const AppText('All'),
                        onPressed: () => widget.model.showKinds(<MediaKind>{}),
                      ),
                      for (final kind in MediaKind.values) ...[
                        const SizedBox(width: 8),
                        ActionChip(
                          avatar: Icon(_icon(kind), size: 18),
                          label: Text(_label(kind)),
                          onPressed: () =>
                              widget.model.showKinds(<MediaKind>{kind}),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                _padding(context),
                22,
                _padding(context),
                10,
              ),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: AppText(
                        'Indexed items',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    Text('${widget.model.items.length} shown'),
                    if (widget.model is GalleryOrganizer)
                      _SortButton(organizer: widget.model as GalleryOrganizer),
                  ],
                ),
              ),
            ),
            if (!widget.isWindows)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  _padding(context),
                  4,
                  _padding(context),
                  22,
                ),
                sliver: const SliverToBoxAdapter(child: AndroidSafBrowser()),
              ),
            if (widget.model.items.isEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: _padding(context)),
                sliver: const SliverToBoxAdapter(child: _NoFilesCard()),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: _padding(context)),
                sliver: SliverList.separated(
                  itemCount: widget.model.items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final item = widget.model.items[index];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        minTileHeight: 68,
                        onTap: () => widget.model.open(item),
                        leading: CircleAvatar(child: Icon(_icon(item.kind))),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          item.isAvailable
                              ? '${item.relativePath} • ${_bytes(item.metadata.sizeBytes)}'
                              : 'Drive or folder unavailable',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) => _action(item, value),
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'open',
                              child: AppText('Open'),
                            ),
                            PopupMenuItem(
                              value: 'share',
                              child: AppText('Share'),
                            ),
                            PopupMenuItem(
                              value: 'favorite',
                              child: AppText('Favorite'),
                            ),
                            PopupMenuItem(
                              value: 'trash',
                              child: AppText('Move to Trash'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            if (widget.model.items.isNotEmpty)
              SliverToBoxAdapter(child: CatalogPageFooter(model: widget.model)),
            const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
          ],
        ),
      ),
    );
  }

  Widget _folderInput(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppText(
              'Your folders',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const AppText(
              'Choose the folders to show in your library. Changes are picked up automatically.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _choosingFolder || widget.model.isIndexing
                      ? null
                      : _chooseFolder,
                  icon: _choosingFolder
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.create_new_folder_outlined),
                  label: Text(
                    _choosingFolder ? 'Adding folder…' : 'Choose folder',
                  ),
                ),
                Text(
                  '${widget.model.windowsFolders.length} selected',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            if (_folderError != null) ...[
              const SizedBox(height: 10),
              Text(
                _folderError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            for (final path in widget.model.windowsFolders) ...[
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder_outlined),
                title: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: context.tr(
                    'Remove from library; files stay in place',
                  ),
                  onPressed: _choosingFolder || widget.model.isIndexing
                      ? null
                      : () => _removeFolder(path),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
            ],
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const PageStorageKey('files-path-expansion'),
                tilePadding: EdgeInsets.zero,
                title: const AppText('Enter a folder path'),
                childrenPadding: const EdgeInsets.only(bottom: 8),
                children: [
                  TextField(
                    key: const PageStorageKey('files-folder-path-input'),
                    controller: _pathController,
                    decoration: InputDecoration(
                      hintText: r'C:\Users\you\Pictures',
                      labelText: context.tr('Folder path'),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addFolder(),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _choosingFolder || widget.model.isIndexing
                          ? null
                          : _addFolder,
                      icon: const Icon(Icons.add_rounded),
                      label: const AppText('Add path'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addFolder() async {
    final path = _pathController.text.trim();
    if (path.isEmpty || _choosingFolder || widget.model.isIndexing) return;
    await _addPath(() async => path);
  }

  Future<void> _chooseFolder() => _addPath(_windowsFiles.chooseFolder);

  Future<void> _addPath(Future<String?> Function() select) async {
    if (_choosingFolder) return;
    setState(() {
      _choosingFolder = true;
      _folderError = null;
    });
    try {
      final path = await select();
      if (path != null && mounted) {
        await widget.model.addWindowsFolder(path);
        if (mounted && widget.model.windowsFolders.contains(path)) {
          _pathController.clear();
        }
      }
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _folderError = 'The folder dialog is unavailable in this build. Enter a path below.',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _folderError =
              error.message ?? 'Windows could not open the folder dialog.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _folderError = 'This folder could not be added. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _choosingFolder = false);
    }
  }

  Future<void> _removeFolder(String path) async {
    try {
      await widget.model.removeWindowsFolder(path);
    } catch (_) {
      if (mounted) {
        setState(
          () => _folderError = 'This folder could not be removed. Try again.',
        );
      }
    }
  }

  Future<void> _action(MediaItem item, String action) async {
    switch (action) {
      case 'open':
        await widget.model.open(item);
      case 'share':
        await widget.model.share(item);
      case 'favorite':
        await widget.model.toggleFavorite(item);
      case 'trash':
        await widget.model.moveToTrash(item);
    }
  }

  double _padding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.organizer});

  final GalleryOrganizer organizer;

  @override
  Widget build(BuildContext context) {
    const fields = <(CatalogSortField, String)>[
      (CatalogSortField.takenAt, 'Date'),
      (CatalogSortField.name, 'Name'),
      (CatalogSortField.size, 'Size'),
      (CatalogSortField.kind, 'Type'),
      (CatalogSortField.modifiedAt, 'Date modified'),
    ];
    return PopupMenuButton<(CatalogSortField, CatalogSortDirection)>(
      tooltip: context.tr('Sort items'),
      icon: const Icon(Icons.sort_rounded),
      onSelected: (value) => organizer.setSort(value.$1, value.$2),
      itemBuilder: (_) => [
        for (final (field, label) in fields)
          for (final direction in CatalogSortDirection.values)
            CheckedPopupMenuItem(
              value: (field, direction),
              checked:
                  organizer.sortField == field &&
                  organizer.sortDirection == direction,
              child: Text(
                '$label ${switch ((field, direction)) {
                  (CatalogSortField.name, CatalogSortDirection.ascending) => 'A to Z',
                  (CatalogSortField.name, _) => 'Z to A',
                  (CatalogSortField.size, CatalogSortDirection.ascending) => 'smallest first',
                  (CatalogSortField.size, _) => 'largest first',
                  (_, CatalogSortDirection.ascending) => 'oldest first',
                  _ => 'newest first',
                }}',
              ),
            ),
      ],
    );
  }
}

class _NoFilesCard extends StatelessWidget {
  const _NoFilesCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 44,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            const AppText('No indexed files match this view.'),
          ],
        ),
      ),
    );
  }
}

String _label(MediaKind kind) => switch (kind) {
  MediaKind.image => 'Images',
  MediaKind.video => 'Videos',
  MediaKind.document => 'Documents',
  MediaKind.audio => 'Audio',
  MediaKind.apk => 'APKs',
  MediaKind.archive => 'Archives',
  MediaKind.other => 'Other',
};

IconData _icon(MediaKind kind) => switch (kind) {
  MediaKind.image => Icons.image_rounded,
  MediaKind.video => Icons.movie_rounded,
  MediaKind.document => Icons.description_rounded,
  MediaKind.audio => Icons.audio_file_rounded,
  MediaKind.apk => Icons.android_rounded,
  MediaKind.archive => Icons.folder_zip_rounded,
  MediaKind.other => Icons.insert_drive_file_rounded,
};

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
