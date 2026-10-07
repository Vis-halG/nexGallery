import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../common/media_tile.dart';
import 'local_video_player.dart';
import 'video_playback_controller.dart';

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    required this.model,
    required this.items,
    required this.initialIndex,
    this.videoControllerFactory = createLocalVideoController,
    super.key,
  });

  final GalleryModel model;
  final List<MediaItem> items;
  final int initialIndex;
  final VideoPlaybackControllerFactory videoControllerFactory;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _pages;
  late final List<MediaItem> _items;
  final _transforms = <int, TransformationController>{};
  late int _index;
  bool _zoomed = false;

  MediaItem get _current {
    final snapshot = _items[_index];
    for (final item in widget.model.items) {
      if (item.id == snapshot.id) return item;
    }
    return snapshot;
  }

  @override
  void initState() {
    super.initState();
    _items = List<MediaItem>.of(widget.items);
    _index = widget.initialIndex;
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final controller in _transforms.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _go(int offset) {
    final next = _index + offset;
    if (next < 0 || next >= _items.length) return;
    _pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
      },
      child: Focus(
        autofocus: true,
        child: Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: AnimatedBuilder(
              animation: widget.model,
              builder: (context, _) {
                final current = _current;
                final authorized = widget.model.canAccessMedia(current);
                return Column(
                  children: [
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Close viewer',
                          color: Colors.white,
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                        Expanded(
                          child: Text(
                            authorized ? current.name : 'Media unavailable',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        if (authorized)
                          IconButton(
                            tooltip: current.isFavorite
                                ? 'Remove favorite'
                                : 'Favorite',
                            color: Colors.white,
                            onPressed: () async {
                              if (!widget.model.canAccessMedia(current)) return;
                              final index = _index;
                              await widget.model.toggleFavorite(current);
                              if (!mounted) return;
                              setState(() {
                                _items[index] = current.copyWith(
                                  isFavorite: !current.isFavorite,
                                );
                              });
                            },
                            icon: Icon(
                              current.isFavorite
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                            ),
                          ),
                        if (authorized)
                          PopupMenuButton<String>(
                            tooltip: 'Viewer actions',
                            iconColor: Colors.white,
                            onSelected: (action) {
                              if (!widget.model.canAccessMedia(current)) return;
                              switch (action) {
                                case 'share':
                                  widget.model.share(current);
                                case 'open':
                                  widget.model.open(current);
                                case 'details':
                                  _details(current);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'share',
                                enabled: current.isAvailable,
                                child: const Text('Share'),
                              ),
                              PopupMenuItem(
                                value: 'open',
                                enabled: current.isAvailable,
                                child: const Text('Open with another app'),
                              ),
                              const PopupMenuItem(
                                value: 'details',
                                child: Text('Details'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    Expanded(
                      child: PageView.builder(
                        key: const ValueKey('media-viewer-pages'),
                        controller: _pages,
                        itemCount: _items.length,
                        physics: _zoomed && authorized
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        onPageChanged: (index) => setState(() {
                          _index = index;
                          _zoomed =
                              (_transforms[index]?.value.getMaxScaleOnAxis() ??
                                  1) >
                              1.05;
                        }),
                        itemBuilder: (context, index) => _page(index),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: 'Previous item',
                            color: Colors.white,
                            onPressed: _index > 0 ? () => _go(-1) : null,
                            icon: const Icon(Icons.chevron_left_rounded),
                          ),
                          Expanded(
                            child: Text(
                              authorized
                                  ? '${_index + 1} of ${_items.length} · '
                                        '${current.source == MediaSource.phone ? 'Phone' : 'PC'}'
                                  : 'Access changed',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Next item',
                            color: Colors.white,
                            onPressed: _index + 1 < _items.length
                                ? () => _go(1)
                                : null,
                            icon: const Icon(Icons.chevron_right_rounded),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _page(int index) {
    final item = index == _index ? _current : _items[index];
    if (!widget.model.canAccessMedia(item)) {
      return _accessUnavailable(item);
    }
    if (item.kind == MediaKind.video) {
      return LocalVideoPlayer(
        key: ValueKey('video-${item.id}'),
        item: item,
        active: index == _index,
        controllerFactory: widget.videoControllerFactory,
        readPosition: widget.model.readVideoPosition,
        savePosition: widget.model.saveVideoPosition,
        openExternal: () {
          if (widget.model.canAccessMedia(item)) widget.model.open(item);
        },
        poster: MediaThumbnail(
          item: item,
          model: widget.model,
          size: 1024,
          fit: BoxFit.contain,
          showFailureMessage: true,
        ),
      );
    }
    final transform = _transforms.putIfAbsent(
      index,
      TransformationController.new,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onDoubleTap: () {
            transform.value = Matrix4.identity();
            if (index == _index) setState(() => _zoomed = false);
          },
          child: InteractiveViewer(
            transformationController: transform,
            panEnabled: _zoomed && index == _index,
            minScale: 1,
            maxScale: 5,
            onInteractionUpdate: (_) {
              final zoomed = transform.value.getMaxScaleOnAxis() > 1.05;
              if (index == _index && zoomed != _zoomed) {
                setState(() => _zoomed = zoomed);
              }
            },
            child: SizedBox.expand(
              child: MediaThumbnail(
                key: ValueKey(item.id),
                item: item,
                model: widget.model,
                size: 1024,
                fit: BoxFit.contain,
                showFailureMessage: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _details(MediaItem item) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) => !widget.model.canAccessMedia(item)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _accessUnavailable(item, dark: false),
              ),
            )
          : SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.8,
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  children: [
                    Text(
                      'Details',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    for (final detail in <(String, String)>[
                      ('Name', item.name),
                      (
                        'Source',
                        item.source == MediaSource.phone ? 'Phone' : 'PC',
                      ),
                      (
                        'Folder',
                        item.relativePath.isEmpty
                            ? 'Unknown'
                            : item.relativePath,
                      ),
                      ('Size', '${item.metadata.sizeBytes} bytes'),
                      (
                        'Date',
                        (item.metadata.takenAt ?? item.metadata.modifiedAt)
                            .toLocal()
                            .toString(),
                      ),
                      if (item.metadata.width != null &&
                          item.metadata.height != null)
                        (
                          'Dimensions',
                          '${item.metadata.width} × ${item.metadata.height}',
                        ),
                      if (item.metadata.duration != null)
                        (
                          'Duration',
                          '${item.metadata.duration!.inSeconds} seconds',
                        ),
                      if (item.metadata.mimeType != null)
                        ('Type', item.metadata.mimeType!),
                      if (!item.isAvailable)
                        ('Status', 'Drive or folder unavailable'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              detail.$1,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                            SelectableText(detail.$2),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
    ),
  );

  Widget _accessUnavailable(MediaItem item, {bool dark = true}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        item.source == MediaSource.phone
            ? 'Media access has changed. Select this item again in Android settings.'
            : 'The drive or folder is unavailable.',
        textAlign: TextAlign.center,
        style: TextStyle(color: dark ? Colors.white70 : null),
      ),
    ),
  );
}
