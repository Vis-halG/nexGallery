import 'package:flutter/material.dart';

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';
import '../../src/gallery_model.dart';

class LibraryPage extends StatelessWidget {
  const LibraryPage({
    required this.model,
    required this.onShowPhotos,
    super.key,
  });

  final GalleryModel model;
  final VoidCallback onShowPhotos;

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
                    badge: 'Not installed',
                    onTap: () => _showNotInstalled(context),
                  ),
                  _CollectionCard(
                    label: 'Places',
                    description: 'From photo location',
                    icon: Icons.location_on_rounded,
                    color: const Color(0xFF2B9C76),
                    badge: 'Coming later',
                    onTap: () => _showNotInstalled(context),
                  ),
                  _CollectionCard(
                    label: 'Cleanup',
                    description: 'Duplicates and large files',
                    icon: Icons.cleaning_services_rounded,
                    color: const Color(0xFFF08A3E),
                    badge: 'Basic scan',
                    onTap: () => _showNotInstalled(context),
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
                  itemCount: model.albums.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final album = model.albums[index];
                    return Card(
                      child: ListTile(
                        minTileHeight: 68,
                        onTap: () {
                          model.showAlbum(album.id);
                          onShowPhotos();
                        },
                        leading: const CircleAvatar(
                          child: Icon(Icons.photo_album_rounded),
                        ),
                        title: Text(album.name),
                        subtitle: Text('${album.itemIds.length} items'),
                        trailing: const Icon(Icons.chevron_right_rounded),
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

  void _showNotInstalled(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'This intelligence module is not installed yet. Your files stay local.',
        ),
      ),
    );
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
    this.badge,
  });

  final String label;
  final String description;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String? badge;

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
                  if (badge case final badge?)
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          badge,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
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
