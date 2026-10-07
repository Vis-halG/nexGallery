import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../common/media_tile.dart';
import '../common/catalog_page_footer.dart';
import 'media_viewer.dart';

class PhotosPage extends StatefulWidget {
  const PhotosPage({required this.model, required this.isDesktop,
    this.onOpenSettings, super.key});

  final GalleryModel model;
  final bool isDesktop;
  final VoidCallback? onOpenSettings;

  @override
  State<PhotosPage> createState() => _PhotosPageState();
}

class _PhotosPageState extends State<PhotosPage> {
  final _searchController = TextEditingController();
  double _gridScale = 1;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        return SafeArea(
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
                  sliver: SliverToBoxAdapter(child: _header(context)),
                ),
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: _pagePadding(context),
                  ),
                  sliver: SliverToBoxAdapter(child: _filters(context)),
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
        );
      },
    );
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
            Text(
              title,
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w900, letterSpacing: -0.6),
            ),
            Text(
              widget.model.items.isEmpty
                  ? 'Private, local and organized'
                  : '${widget.model.totalItemCount} items',
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
              tooltip: 'Refresh library',
              onPressed: widget.model.loadState == GalleryLoadState.loading
                  ? null
                  : widget.model.refresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Change grid size',
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
              IconButton.filledTonal(tooltip: 'Settings', onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.settings_outlined)),
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
          hintText: 'Search filename, folder or type',
          leading: const Icon(Icons.search_rounded),
          trailing: [
            if (_searchController.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear search',
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
      ],
    );
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
      label: Text(label),
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
    final groups = _groupByDay(widget.model.items);
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
              _dateLabel(group.key),
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
            title: const Text('Delete permanently?'),
            content: Text('${item.name} cannot be restored after this action.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) await widget.model.deletePermanently(item);
    }
  }

  Future<void> _addToAlbum(MediaItem item) async {
    if (widget.model.albums.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create an album in Library first.')),
      );
      return;
    }
    final albumId = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                'Add to album',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            for (final album in widget.model.albums)
              ListTile(
                leading: const Icon(Icons.photo_album_rounded),
                title: Text(album.name),
                subtitle: Text('${album.itemIds.length} items'),
                onTap: () => Navigator.pop(context, album.id),
              ),
          ],
        ),
      ),
    );
    if (albumId != null) await widget.model.addToAlbum(item, albumId);
  }

  Future<void> _showViewer(MediaItem item) async {
    final items = List<MediaItem>.of(widget.model.items);
    final index = items.indexWhere((candidate) => candidate.id == item.id);
    if (index < 0) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (_) =>
          MediaViewer(model: widget.model, items: items, initialIndex: index),
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
