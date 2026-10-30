import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';
import '../../services/remote/remote_session.dart';
import '../../services/remote/security.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/media_tile.dart';
import '../common/catalog_page_footer.dart';
import '../editing/collage_page.dart';
import '../library/memories_page.dart';
import 'media_viewer.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({
    required this.model,
    required this.isDesktop,
    this.onOpenSettings,
    this.remoteSession,
    super.key,
  });

  final GalleryModel model;
  final bool isDesktop;
  final VoidCallback? onOpenSettings;

  /// Enables "Send to PC" for selections when the phone is paired.
  final RemoteSession? remoteSession;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  final _searchController = TextEditingController();
  final _selected = <String>{};
  double _gridScale = 1;
  bool _busy = false;

  GalleryOrganizer? get _organizer => widget.model is GalleryOrganizer
      ? widget.model as GalleryOrganizer
      : null;

  List<MediaItem> get _selectedItems => widget.model.items
      .where((item) => _selected.contains(item.id))
      .toList(growable: false);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(MediaItem item) => setState(() {
    if (!_selected.remove(item.id)) _selected.add(item.id);
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        _selected.retainAll(widget.model.items.map((item) => item.id));
        // Library pages (Smart search, Places) can set the query directly.
        if (_searchController.text != widget.model.searchText) {
          _searchController.text = widget.model.searchText;
        }
        final selecting = _selected.isNotEmpty;
        return PopScope(
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selecting) setState(_selected.clear);
          },
          child: SafeArea(
            child: RefreshIndicator(
              onRefresh: widget.model.refresh,
              child: CustomScrollView(
                key: const PageStorageKey('photos-timeline'),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      _pagePadding(context),
                      18,
                      _pagePadding(context),
                      12,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: selecting
                          ? _selectionBar(context)
                          : _header(context),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(
                      horizontal: _pagePadding(context),
                    ),
                    sliver: SliverToBoxAdapter(child: _filters(context)),
                  ),
                  if (_showMemories)
                    SliverToBoxAdapter(
                      child: MemoryCarousel(
                        model: widget.model,
                        padding: _pagePadding(context),
                      ),
                    ),
                  if (widget.model.isIndexing)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        _pagePadding(context),
                        8,
                        _pagePadding(context),
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _IndexProgress(model: widget.model),
                      ),
                    ),
                  ..._content(context),
                  if (widget.model.items.isNotEmpty &&
                      (widget.model.loadState == GalleryLoadState.ready ||
                          widget.model.loadState == GalleryLoadState.loading))
                    SliverToBoxAdapter(
                      child: CatalogPageFooter(model: widget.model),
                    ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  bool get _showMemories {
    final organizer = _organizer;
    return organizer != null &&
        widget.model.collection == GalleryCollection.timeline &&
        widget.model.searchText.isEmpty &&
        organizer.activeAlbumId == null &&
        _selected.isEmpty &&
        organizer.memories.isNotEmpty;
  }

  Widget _selectionBar(BuildContext context) {
    final organizer = _organizer!;
    final items = _selectedItems;
    final inTrash = widget.model.collection == GalleryCollection.trash;
    final albumId = organizer.activeAlbumId;
    final images = items.where((item) => item.kind == MediaKind.image).length;
    return Row(
      children: [
        IconButton(
          tooltip: context.tr('Clear selection'),
          onPressed: () => setState(_selected.clear),
          icon: const Icon(Icons.close_rounded),
        ),
        Expanded(
          child: Text(
            '${items.length} selected',
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.all(12),
            child: SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          tooltip: context.tr('Select all loaded'),
          onPressed: () => setState(
            () => _selected.addAll(widget.model.items.map((item) => item.id)),
          ),
          icon: const Icon(Icons.select_all_rounded),
        ),
        if (!inTrash) ...[
          IconButton(
            tooltip: context.tr('Share selected'),
            onPressed: _busy ? null : () => _batch(organizer.shareAll(items)),
            icon: const Icon(Icons.share_rounded),
          ),
          IconButton(
            tooltip: context.tr('Move selected to Trash'),
            onPressed: _busy
                ? null
                : () => _batch(() async {
                    final moved = await organizer.moveAllToTrash(items);
                    if (mounted) {
                      showMessage(this.context, '$moved moved to Trash');
                    }
                  }()),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
        PopupMenuButton<String>(
          tooltip: context.tr('More actions for selection'),
          enabled: !_busy,
          onSelected: (action) => _selectionAction(action, items),
          itemBuilder: (_) => [
            if (!inTrash) ...[
              const PopupMenuItem(
                value: 'favorite',
                child: AppText('Favorite'),
              ),
              const PopupMenuItem(
                value: 'unfavorite',
                child: AppText('Remove favorite'),
              ),
              const PopupMenuItem(
                value: 'album',
                child: AppText('Add to album'),
              ),
              if (albumId != null)
                const PopupMenuItem(
                  value: 'remove-album',
                  child: AppText('Remove from this album'),
                ),
              const PopupMenuItem(value: 'archive', child: AppText('Archive')),
              if (widget.model is GalleryTools && images >= 2 && images <= 9)
                const PopupMenuItem(
                  value: 'collage',
                  child: AppText('Create collage'),
                ),
              const PopupMenuItem(
                value: 'slideshow',
                child: AppText('Slideshow'),
              ),
              if (widget.remoteSession?.allows(DeviceScope.upload) == true)
                const PopupMenuItem(
                  value: 'send',
                  child: AppText('Send to PC'),
                ),
            ] else
              const PopupMenuItem(value: 'restore', child: AppText('Restore')),
          ],
        ),
      ],
    );
  }

  Future<void> _batch(Future<void> operation) async {
    setState(() => _busy = true);
    try {
      await operation;
      if (mounted) setState(_selected.clear);
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectionAction(String action, List<MediaItem> items) async {
    final organizer = _organizer!;
    switch (action) {
      case 'favorite':
        await _batch(organizer.setFavorites(items, true));
      case 'unfavorite':
        await _batch(organizer.setFavorites(items, false));
      case 'archive':
        await _batch(organizer.archiveAll(items));
      case 'remove-album':
        await _batch(
          organizer.removeFromAlbum(organizer.activeAlbumId!, items),
        );
      case 'album':
        final picked = await pickAlbum(
          context,
          widget.model.albums,
          createAlbum: widget.model.createAlbum,
        );
        final albumId = resolvePickedAlbum(picked, widget.model.albums);
        if (albumId != null && mounted) {
          await _batch(organizer.addAllToAlbum(items, albumId));
          if (mounted) showMessage(context, 'Added ${itemCount(items.length)}');
        }
      case 'restore':
        await _batch(() async {
          for (final item in items) {
            await widget.model.restore(item);
          }
        }());
      case 'collage':
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => CollagePage(
              model: widget.model,
              tools: widget.model as GalleryTools,
              items: items
                  .where((item) => item.kind == MediaKind.image)
                  .toList(),
            ),
          ),
        );
        if (mounted) setState(_selected.clear);
      case 'slideshow':
        await _showViewer(items.first, items: items, slideshow: true);
      case 'send':
        await _batch(() async {
          final added = await widget.remoteSession!.sendToPc(items);
          if (mounted) {
            showMessage(context, '$added items added to Transfers');
          }
        }());
    }
  }

  Future<void> _emptyTrash() async {
    final organizer = _organizer;
    if (organizer == null) return;
    final confirmed = await confirmIrreversible(
      context,
      title: 'Empty Trash?',
      message: 'Everything in Trash will be deleted permanently. This cannot be undone.',
      action: 'Empty Trash',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final deleted = await organizer.emptyTrash();
      if (mounted) showMessage(context, '${itemCount(deleted)} deleted');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _header(BuildContext context) {
    final title = widget.isDesktop ? 'This PC' : 'Photos';
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppText(
              title,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
            ),
            Text(
              widget.model.items.isEmpty
                  ? 'Private, local and organized'
                  : itemCount(widget.model.totalItemCount),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton.filledTonal(
              tooltip: context.tr('Refresh library'),
              onPressed: widget.model.loadState == GalleryLoadState.loading
                  ? null
                  : widget.model.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: context.tr('Change grid size'),
              onPressed: () => setState(() {
                _gridScale = switch (_gridScale) {
                  < 0.9 => 1,
                  < 1.1 => 1.3,
                  _ => 0.75,
                };
              }),
              icon: const Icon(Icons.grid_view_rounded),
            ),
            if (widget.onOpenSettings != null) ...[
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: context.tr('Settings'),
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _filters(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchBar(
          controller: _searchController,
          hintText: context.tr('Search names, places, people, things or text'),
          leading: const Icon(Icons.search_rounded),
          trailing: [
            if (_searchController.text.isNotEmpty)
              IconButton(
                tooltip: context.tr('Clear search'),
                onPressed: () {
                  _searchController.clear();
                  widget.model.setSearchText('');
                  setState(() {});
                },
                icon: const Icon(Icons.close_rounded),
              ),
          ],
          onChanged: (value) {
            widget.model.setSearchText(value);
            setState(() {});
          },
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _collectionChip('Timeline', GalleryCollection.timeline),
              const SizedBox(width: 8),
              _collectionChip('Favorites', GalleryCollection.favorites),
              const SizedBox(width: 8),
              _collectionChip('Archive', GalleryCollection.archive),
              const SizedBox(width: 8),
              _collectionChip('Trash', GalleryCollection.trash),
            ],
          ),
        ),
        if (_activeAlbum case final album?)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                avatar: const Icon(Icons.photo_album_rounded, size: 18),
                label: Text('Album: ${album.name}'),
                deleteButtonTooltipMessage: 'Show the whole timeline',
                onDeleted: () =>
                    widget.model.showCollection(GalleryCollection.timeline),
              ),
            ),
          ),
        if (_organizer != null &&
            widget.model.collection == GalleryCollection.trash &&
            widget.model.items.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _busy ? null : _emptyTrash,
              icon: const Icon(Icons.delete_forever_rounded),
              label: const AppText('Empty Trash'),
            ),
          ),
      ],
    );
  }

  MediaAlbum? get _activeAlbum {
    final id = _organizer?.activeAlbumId;
    if (id == null) return null;
    for (final album in widget.model.albums) {
      if (album.id == id) return album;
    }
    return null;
  }

  Widget _collectionChip(String label, GalleryCollection value) {
    return ChoiceChip(
      selected: widget.model.collection == value,
      onSelected: (_) => widget.model.showCollection(value),
      avatar: Icon(switch (value) {
        GalleryCollection.timeline => Icons.photo_library_outlined,
        GalleryCollection.favorites => Icons.favorite_outline_rounded,
        GalleryCollection.archive => Icons.archive_outlined,
        GalleryCollection.trash => Icons.delete_outline_rounded,
      }, size: 18),
      label: AppText(label),
    );
  }

  List<Widget> _content(BuildContext context) {
    switch (widget.model.loadState) {
      case GalleryLoadState.starting:
      case GalleryLoadState.loading:
        if (widget.model.items.isNotEmpty) return _timeline(context);
        return [
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          ),
        ];
      case GalleryLoadState.permissionRequired:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AccessState(
              icon: Icons.photo_library_outlined,
              title: 'Allow photo and video access',
              message: 'nexGallery reads your phone library locally. Nothing is uploaded.',
              actionLabel: 'Choose photos and videos',
              onAction: widget.model.requestAccessAndRefresh,
            ),
          ),
        ];
      case GalleryLoadState.error:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AccessState(
              icon: Icons.error_outline_rounded,
              title: 'Library could not be opened',
              message: widget.model.errorMessage ?? 'Try again.',
              actionLabel: 'Retry',
              onAction: widget.model.refresh,
            ),
          ),
        ];
      case GalleryLoadState.unsupported:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AccessState(
              icon: Icons.folder_open_rounded,
              title: 'Choose a folder to begin',
              message: 'Enter a local Windows folder in Files. Originals stay where they are.',
              actionLabel: 'Refresh',
              onAction: widget.model.refresh,
            ),
          ),
        ];
      case GalleryLoadState.empty:
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: _AccessState(
              icon: Icons.photo_outlined,
              title: _emptyTitle(),
              message: widget.model.statusMessage ?? 'Pull down to scan again.',
              actionLabel: 'Scan again',
              onAction: widget.model.refresh,
            ),
          ),
        ];
      case GalleryLoadState.ready:
        return _timeline(context);
    }
  }

  List<Widget> _timeline(BuildContext context) {
    final sort = _organizer?.sortField ?? CatalogSortField.takenAt;
    final groups = sort == CatalogSortField.takenAt
        ? _groupByDay(widget.model.items)
        : <DateTime?, List<MediaItem>>{
            if (widget.model.items.isNotEmpty) null: widget.model.items,
          };
    if (groups.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _AccessState(
            icon: Icons.search_off_rounded,
            title: 'No matching items',
            message: 'Try a different search or collection.',
            actionLabel: 'Clear filters',
            onAction: () {
              _searchController.clear();
              widget.model.setSearchText('');
              widget.model.showCollection(GalleryCollection.timeline);
            },
          ),
        ),
      ];
    }
    return [
      for (final group in groups.entries) ...[
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            _pagePadding(context),
            22,
            _pagePadding(context),
            10,
          ),
          sliver: SliverToBoxAdapter(
            child: Text(
              group.key == null ? _sortLabel(sort) : _dateLabel(group.key!),
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: _pagePadding(context)),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final base = switch (constraints.crossAxisExtent) {
                < 380 => 2,
                < 650 => 3,
                < 900 => 4,
                < 1250 => 5,
                _ => 6,
              };
              final columns = (base * _gridScale).round().clamp(2, 8);
              return SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  childAspectRatio: 0.92,
                ),
                itemCount: group.value.length,
                itemBuilder: (context, index) {
                  final item = group.value[index];
                  return MediaTile(
                    key: ValueKey(item.id),
                    item: item,
                    model: widget.model,
                    onAction: (action) => _handleAction(item, action),
                    onSelect: _organizer == null ? null : () => _toggle(item),
                    selectionMode: _selected.isNotEmpty,
                    selected: _selected.contains(item.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    ];
  }

  String _emptyTitle() => switch (widget.model.collection) {
    GalleryCollection.timeline => 'No photos or videos found',
    GalleryCollection.favorites => 'No favorites yet',
    GalleryCollection.archive => 'Archive is empty',
    GalleryCollection.trash => 'Trash is empty',
  };

  Future<void> _handleAction(MediaItem item, MediaTileAction action) async {
    switch (action) {
      case MediaTileAction.open:
        await _showViewer(item);
      case MediaTileAction.favorite:
        await widget.model.toggleFavorite(item);
      case MediaTileAction.addToAlbum:
        await _addToAlbum(item);
      case MediaTileAction.archive:
        await widget.model.archive(item);
      case MediaTileAction.trash:
        final moved = await widget.model.moveToTrash(item);
        if (mounted && moved) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('${item.name} moved to Trash'),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => widget.model.restore(item),
              ),
            ),
          );
        }
      case MediaTileAction.restore:
        await widget.model.restore(item);
      case MediaTileAction.delete:
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const AppText('Delete permanently?'),
            content: Text('${item.name} cannot be restored after this action.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const AppText('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const AppText('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.model.deletePermanently(item);
    }
  }

  Future<void> _addToAlbum(MediaItem item) async {
    final picked = await pickAlbum(
      context,
      widget.model.albums,
      createAlbum: widget.model.createAlbum,
    );
    final albumId = resolvePickedAlbum(picked, widget.model.albums);
    if (albumId != null) await widget.model.addToAlbum(item, albumId);
  }

  Future<void> _showViewer(
    MediaItem item, {
    List<MediaItem>? items,
    bool slideshow = false,
  }) async {
    final list = List<MediaItem>.of(items ?? widget.model.items);
    final index = list.indexWhere((candidate) => candidate.id == item.id);
    if (index < 0) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (_) => MediaViewer(
        model: widget.model,
        items: list,
        initialIndex: index,
        startSlideshow: slideshow,
      ),
    );
  }

  double _pagePadding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;
}

class _IndexProgress extends StatelessWidget {
  const _IndexProgress({required this.model});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) {
    final total = model.discoveredCount;
    final progress = total == null || total == 0
        ? null
        : (model.indexedCount / total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(value: progress, strokeWidth: 3),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                total == null
                    ? 'Indexing local files…'
                    : 'Indexed ${model.indexedCount} of $total',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessState extends StatelessWidget {
  const _AccessState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 38, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onAction,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(actionLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Map<DateTime, List<MediaItem>> _groupByDay(List<MediaItem> items) {
  final groups = <DateTime, List<MediaItem>>{};
  for (final item in items) {
    final value = (item.metadata.takenAt ?? item.metadata.modifiedAt).toLocal();
    final day = DateTime(value.year, value.month, value.day);
    groups.putIfAbsent(day, () => <MediaItem>[]).add(item);
  }
  return groups;
}

String _sortLabel(CatalogSortField field) => switch (field) {
  CatalogSortField.name => 'Sorted by name',
  CatalogSortField.size => 'Sorted by size',
  CatalogSortField.kind => 'Sorted by type',
  CatalogSortField.modifiedAt => 'Sorted by date modified',
  CatalogSortField.createdAt => 'Sorted by date added',
  CatalogSortField.takenAt => 'Sorted by date',
};

String _dateLabel(DateTime date) {
  final today = DateTime.now();
  final day = DateTime(today.year, today.month, today.day);
  if (date == day) return 'Today';
  if (date == day.subtract(const Duration(days: 1))) return 'Yesterday';
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${date.day} ${months[date.month - 1]} ${date.year}';
}
