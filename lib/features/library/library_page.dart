import 'package:flutter/material.dart';

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../common/media_tile.dart';
import '../vault/vault_page.dart';
import 'analysis_page.dart';
import 'memories_page.dart';
import 'storage_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    required this.model,
    required this.onShowPhotos,
    super.key,
  });

  final GalleryModel model;
  final VoidCallback onShowPhotos;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _albumFilter = '';
  Object? _byIdSource;
  Map<String, MediaItem> _byId = const {};

  GalleryModel get model => widget.model;
  VoidCallback get onShowPhotos => widget.onShowPhotos;

  List<MediaAlbum> get _albums => model.albums
      .where(
        (album) => album.name.toLowerCase().contains(
          _albumFilter.trim().toLowerCase(),
        ),
      )
      .toList();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) => SafeArea(
        child: CustomScrollView(
          key: const PageStorageKey('library'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                _padding(context),
                20,
                _padding(context),
                8,
              ),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Library',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.6,
                                ),
                          ),
                          Text(
                            'Your local collections and file categories',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: 'Create album',
                      onPressed: () => _createAlbum(context),
                      icon: const Icon(Icons.create_new_folder_rounded),
                    ),
                  ],
                ),
              ),
            ),
            _sectionTitle(context, 'Collections'),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: _padding(context)),
              sliver: SliverGrid(
                delegate: SliverChildListDelegate.fixed([
                  if (model is GalleryOrganizer)
                    _CollectionCard(
                      label: 'Memories',
                      description: 'Moments made on this device',
                      icon: Icons.auto_stories_rounded,
                      color: const Color(0xFFE5533F),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MemoriesPage(model: model),
                        ),
                      ),
                    ),
                  _CollectionCard(
                    label: 'Favorites',
                    description: 'Items you marked',
                    icon: Icons.favorite_rounded,
                    color: const Color(0xFFFF4F7B),
                    onTap: () => _showCollection(GalleryCollection.favorites),
                  ),
                  _CollectionCard(
                    label: 'Archive',
                    description: 'Hidden from timeline',
                    icon: Icons.archive_rounded,
                    color: const Color(0xFF7065C8),
                    onTap: () => _showCollection(GalleryCollection.archive),
                  ),
                  _CollectionCard(
                    label: 'Trash',
                    description: 'Recoverable items',
                    icon: Icons.delete_outline_rounded,
                    color: const Color(0xFF68707D),
                    onTap: () => _showCollection(GalleryCollection.trash),
                  ),
                  _CollectionCard(
                    label: 'People',
                    description: 'Optional local AI pack',
                    icon: Icons.people_alt_rounded,
                    color: const Color(0xFF3F82E5),
                    onTap: () => _analysis(context, AnalysisKind.people),
                  ),
                  _CollectionCard(
                    label: 'Places',
                    description: 'From photo location',
                    icon: Icons.location_on_rounded,
                    color: const Color(0xFF2B9C76),
                    onTap: () => _analysis(context, AnalysisKind.places),
                  ),
                  _CollectionCard(
                    label: 'Cleanup',
                    description: 'Duplicates, look-alikes and large files',
                    icon: Icons.cleaning_services_rounded,
                    color: const Color(0xFFF08A3E),
                    onTap: () => _analysis(context, AnalysisKind.cleanup),
                  ),
                  _CollectionCard(
                    label: 'Smart search',
                    description: 'Find things and text in photos',
                    icon: Icons.manage_search_rounded,
                    color: const Color(0xFF8E5BD8),
                    onTap: () => _analysis(context, AnalysisKind.search),
                  ),
                  if (model is GalleryOrganizer)
                    _CollectionCard(
                      label: 'Storage',
                      description: 'Space used and cleanup ideas',
                      icon: Icons.pie_chart_rounded,
                      color: const Color(0xFF2B7BB9),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StoragePage(model: model),
                        ),
                      ),
                    ),
                  if (model is GalleryTools)
                    _CollectionCard(
                      label: 'Locked Folder',
                      description: 'Encrypted private copies',
                      icon: Icons.lock_rounded,
                      color: const Color(0xFF7065C8),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => VaultPage(
                            tools: model as GalleryTools,
                            model: model,
                          ),
                        ),
                      ),
                    ),
                ]),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _columns(context),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: _columns(context) <= 2 ? 1.2 : 1.45,
                ),
              ),
            ),
            _sectionTitle(context, 'File categories'),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: _padding(context)),
              sliver: SliverGrid.builder(
                itemCount: model.categories.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _columns(context),
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.65,
                ),
                itemBuilder: (context, index) {
                  final category = model.categories[index];
                  return _CategoryCard(
                    category: category,
                    onTap: () {
                      model.showKinds(<MediaKind>{category.kind});
                      onShowPhotos();
                    },
                  );
                },
              ),
            ),
            _sectionTitle(context, 'Albums'),
            if (model.albums.length > 6)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  _padding(context),
                  0,
                  _padding(context),
                  12,
                ),
                sliver: SliverToBoxAdapter(
                  child: SearchBar(
                    hintText: 'Search albums',
                    leading: const Icon(Icons.search_rounded),
                    onChanged: (value) => setState(() => _albumFilter = value),
                  ),
                ),
              ),
            if (model.albums.isEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: _padding(context)),
                sliver: SliverToBoxAdapter(
                  child: _EmptyAlbums(onCreate: () => _createAlbum(context)),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: _padding(context)),
                sliver: SliverList.separated(
                  itemCount: _albums.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final album = _albums[index];
                    final cover = _cover(album);
                    return Card(
                      child: ListTile(
                        minTileHeight: 68,
                        onTap: () {
                          model.showAlbum(album.id);
                          onShowPhotos();
                        },
                        leading: SizedBox.square(
                          dimension: 48,
                          child: cover == null
                              ? const CircleAvatar(
                                  child: Icon(Icons.photo_album_rounded),
                                )
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: MediaThumbnail(
                                    item: cover,
                                    model: model,
                                    size: 160,
                                  ),
                                ),
                        ),
                        title: Text(album.name),
                        subtitle: Text('${album.itemIds.length} items'),
                        trailing: model is GalleryOrganizer && !album.isReadOnly
                            ? PopupMenuButton<String>(
                                tooltip: 'Album actions',
                                onSelected: (action) =>
                                    _albumAction(album, action),
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'rename',
                                    child: Text('Rename'),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete album'),
                                  ),
                                ],
                              )
                            : const Icon(Icons.chevron_right_rounded),
                      ),
                    );
                  },
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
          ],
        ),
      ),
    );
  }

  SliverPadding _sectionTitle(BuildContext context, String label) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(
        _padding(context),
        26,
        _padding(context),
        12,
      ),
      sliver: SliverToBoxAdapter(
        child: Text(
          label,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  /// The chosen cover, else the newest accessible member.
  MediaItem? _cover(MediaAlbum album) {
    if (model is! GalleryTools) return null;
    final ids = album.coverItemId != null
        ? [album.coverItemId!, ...album.itemIds.reversed]
        : album.itemIds.reversed;
    // The runtime publishes a new album list per catalogue change.
    if (!identical(_byIdSource, model.albums)) {
      _byIdSource = model.albums;
      _byId = {
        for (final item in (model as GalleryTools).localItems) item.id: item,
      };
    }
    final byId = _byId;
    for (final id in ids) {
      final item = byId[id];
      if (item != null &&
          (item.kind == MediaKind.image || item.kind == MediaKind.video)) {
        return item;
      }
    }
    return null;
  }

  Future<void> _albumAction(MediaAlbum album, String action) async {
    final organizer = model as GalleryOrganizer;
    try {
      if (action == 'rename') {
        final name = await promptText(
          context,
          title: 'Rename album',
          label: 'Album name',
          initialValue: album.name,
        );
        if (name != null) await organizer.renameAlbum(album.id, name);
      } else if (action == 'delete') {
        final confirmed = await confirmAction(
          context,
          title: 'Delete "${album.name}"?',
          message: 'Only the album is removed. Its photos and videos stay in your library.',
          action: 'Delete album',
        );
        if (confirmed) await organizer.deleteAlbum(album.id);
      }
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    }
  }

  void _showCollection(GalleryCollection collection) {
    model.showCollection(collection);
    onShowPhotos();
  }

  Future<void> _createAlbum(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create album'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Album name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await model.createAlbum(name);
    }
  }

  void _analysis(BuildContext context, AnalysisKind kind) {
    if (model is GalleryTools) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => AnalysisPage(
            kind: kind,
            model: model,
            tools: model as GalleryTools,
            onSearch: (query) {
              model.showCollection(GalleryCollection.timeline);
              model.setSearchText(query);
              onShowPhotos();
            },
          ),
        ),
      );
    }
  }

  double _padding(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;

  int _columns(BuildContext context) =>
      switch (MediaQuery.sizeOf(context).width) {
        < 520 => 2,
        < 900 => 3,
        < 1250 => 4,
        _ => 5,
      };
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.label,
    required this.description,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CircleAvatar(
                    backgroundColor: color.withValues(alpha: 0.16),
                    foregroundColor: color,
                    child: Icon(icon),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                label,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.category, required this.onTap});

  final CategorySummary category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(_icon(category.kind), size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _label(category.kind),
                      maxLines: 1,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${category.itemCount} • ${_bytes(category.totalBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyAlbums extends StatelessWidget {
  const _EmptyAlbums({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const CircleAvatar(child: Icon(Icons.photo_album_outlined)),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'No albums yet',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text('Create a virtual album without moving originals.'),
                ],
              ),
            ),
            TextButton(onPressed: onCreate, child: const Text('Create')),
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
  MediaKind.audio => Icons.audiotrack_rounded,
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
