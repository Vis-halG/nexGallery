import '../../l10n/app_strings.dart';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../services/organization/memories.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../common/media_tile.dart';
import '../photos/media_viewer.dart';

/// Horizontal memories strip shown above the timeline.
class MemoryCarousel extends StatelessWidget {
  const MemoryCarousel({required this.model, this.padding = 16, super.key});

  final GalleryModel model;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final memories = (model as GalleryOrganizer).memories;
    return SizedBox(
      height: 196,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(padding, 16, padding, 4),
        scrollDirection: Axis.horizontal,
        itemCount: memories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: 136,
          child: _MemoryCard(model: model, memory: memories[index]),
        ),
      ),
    );
  }
}

class MemoriesPage extends StatelessWidget {
  const MemoriesPage({required this.model, super.key});

  final GalleryModel model;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const AppText('Memories')),
    body: AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final memories = (model as GalleryOrganizer).memories;
        if (memories.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: AppText(
                'Memories appear when your library has photos from this week in earlier years, a busy last month, trips, named people or favorites. They are made on this device.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          itemCount: memories.length,
          itemBuilder: (context, index) =>
              _MemoryCard(model: model, memory: memories[index]),
        );
      },
    ),
  );
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({required this.model, required this.memory});

  final GalleryModel model;
  final Memory memory;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${memory.title}, ${memory.subtitle}',
    excludeSemantics: true,
    child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => MemoryDetailPage(model: model, memory: memory),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            MediaThumbnail(item: memory.cover, model: model),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.center,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black87],
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    memory.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                  Text(
                    memory.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
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

class MemoryDetailPage extends StatelessWidget {
  const MemoryDetailPage({
    required this.model,
    required this.memory,
    super.key,
  });

  final GalleryModel model;
  final Memory memory;

  Future<void> _open(
    BuildContext context,
    List<MediaItem> items,
    int index, {
    bool slideshow = false,
  }) => showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.88),
    builder: (_) => MediaViewer(
      model: model,
      items: items,
      initialIndex: index,
      startSlideshow: slideshow,
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(memory.title),
      actions: [
        IconButton(
          tooltip: context.tr('Play slideshow'),
          onPressed: () => _open(
            context,
            memory.items.where(model.canAccessMedia).toList(),
            0,
            slideshow: true,
          ),
          icon: const Icon(Icons.slideshow_rounded),
        ),
      ],
    ),
    body: AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final items = memory.items.where(model.canAccessMedia).toList();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              sliver: SliverToBoxAdapter(child: Text(memory.subtitle)),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) => Semantics(
                  button: true,
                  label: items[index].name,
                  child: InkWell(
                    onTap: () => _open(context, items, index),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: MediaThumbnail(item: items[index], model: model),
                    ),
                  ),
                ),
              ),
            ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 32)),
          ],
        );
      },
    ),
  );
}
