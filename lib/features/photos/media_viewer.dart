import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_organizer.dart';
import '../../src/gallery_tools.dart';
import '../common/dialogs.dart';
import '../editing/photo_editor_page.dart';
import '../editing/video_editor_page.dart';
import '../common/media_tile.dart';
import 'local_video_player.dart';
import 'metadata_editor.dart';
import 'video_playback_controller.dart';

class MediaViewer extends StatefulWidget {
  const MediaViewer({
    required this.model,
    required this.items,
    required this.initialIndex,
    this.videoControllerFactory = createLocalVideoController,
    this.startSlideshow = false,
    super.key,
  });

  final GalleryModel model;
  final List<MediaItem> items;
  final int initialIndex;
  final VideoPlaybackControllerFactory videoControllerFactory;
  final bool startSlideshow;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  late final PageController _pages;
  late final List<MediaItem> _items;
  final _transforms = <int, TransformationController>{};
  late int _index;
  bool _zoomed = false;
  bool _editing = false;
  Timer? _slideshow;

  GalleryOrganizer? get _organizer => widget.model is GalleryOrganizer
      ? widget.model as GalleryOrganizer
      : null;

  void _toggleSlideshow() {
    if (_slideshow != null) {
      _slideshow!.cancel();
      setState(() => _slideshow = null);
      return;
    }
    setState(() {
      _slideshow = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted || _editing) return;
        if (_index + 1 < _items.length) {
          _go(1);
        } else {
          _pages.jumpToPage(0);
        }
      });
    });
  }

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
    if (widget.startSlideshow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _slideshow == null) _toggleSlideshow();
      });
    }
  }

  @override
  void dispose() {
    _slideshow?.cancel();
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
        const SingleActivator(LogicalKeyboardKey.space): _toggleSlideshow,
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
                        if (_items.length > 1)
                          IconButton(
                            tooltip: _slideshow == null
                                ? 'Play slideshow'
                                : 'Pause slideshow',
                            color: Colors.white,
                            onPressed: _toggleSlideshow,
                            icon: Icon(
                              _slideshow == null
                                  ? Icons.slideshow_rounded
                                  : Icons.pause_rounded,
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
                                case 'edit':
                                  _edit(current);
                                case 'details':
                                  _details(current);
                                case 'album':
                                  _addToAlbum(current);
                                case 'cover':
                                  _organize(
                                    _organizer!.setAlbumCover(
                                      _organizer!.activeAlbumId!,
                                      current,
                                    ),
                                    'Album cover updated',
                                  );
                                case 'remove-album':
                                  _organize(
                                    _organizer!.removeFromAlbum(
                                      _organizer!.activeAlbumId!,
                                      [current],
                                    ),
                                    'Removed from album',
                                  );
                                case 'wallpaper':
                                  _wallpaper(current);
                                case 'correct':
                                  _correct(current);
                              }
                            },
                            itemBuilder: (_) => [
                              if (_organizer != null &&
                                  current.section != MediaSection.trash) ...[
                                const PopupMenuItem(
                                  value: 'album',
                                  child: Text('Add to album'),
                                ),
                                if (_organizer!.activeAlbumId != null) ...[
                                  const PopupMenuItem(
                                    value: 'cover',
                                    child: Text('Use as album cover'),
                                  ),
                                  const PopupMenuItem(
                                    value: 'remove-album',
                                    child: Text('Remove from this album'),
                                  ),
                                ],
                                if (current.kind == MediaKind.image)
                                  const PopupMenuItem(
                                    value: 'wallpaper',
                                    child: Text('Set as wallpaper'),
                                  ),
                                const PopupMenuItem(
                                  value: 'correct',
                                  child: Text('Adjust date and location'),
                                ),
                              ],
                              if (widget.model is GalleryTools &&
                                  current.section != MediaSection.trash &&
                                  (current.kind == MediaKind.image ||
                                      current.kind == MediaKind.video))
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text(
                                    current.kind == MediaKind.video
                                        ? 'Edit video'
                                        : 'Edit photo',
                                  ),
                                ),
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
        active: index == _index && !_editing,
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
                // The open photo sharpens from the quick preview to a decode
                // of the original; neighbours stay light on memory.
                size: 1024,
                sharpenTo: index == _index ? _fullSize(context) : null,
                fit: BoxFit.contain,
                showFailureMessage: true,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _organize(Future<void> operation, String done) async {
    try {
      await operation;
      if (mounted) showMessage(context, done);
    } catch (error) {
      if (mounted) showMessage(context, friendlyError(error));
    }
  }

  Future<void> _addToAlbum(MediaItem item) async {
    final picked = await pickAlbum(
      context,
      widget.model.albums,
      createAlbum: widget.model.createAlbum,
    );
    final albumId = resolvePickedAlbum(picked, widget.model.albums);
    if (albumId == null || !mounted) return;
    await _organize(widget.model.addToAlbum(item, albumId), 'Added to album');
  }

  Future<void> _wallpaper(MediaItem item) async {
    final target = await showModalBottomSheet<WallpaperTarget>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (target, label, icon) in [
              (WallpaperTarget.home, 'Home screen', Icons.home_outlined),
              (WallpaperTarget.lock, 'Lock screen', Icons.lock_outline),
              (WallpaperTarget.both, 'Home and lock screens', Icons.wallpaper),
            ])
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.pop(context, target),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    await _organize(
      _organizer!.setWallpaper(item, target),
      'Wallpaper updated',
    );
  }

  Future<void> _correct(MediaItem item) async {
    final change = await showDialog<MetadataCorrection>(
      context: context,
      builder: (_) => MetadataEditor(item: item),
    );
    if (change == null || !mounted) return;
    await _organize(
      _organizer!.correctMetadata(
        item,
        takenAt: change.takenAt,
        location: change.location,
        clearLocation: change.clearLocation,
      ),
      'Saved in nexGallery. The original file was not changed.',
    );
  }

  Future<void> _edit(MediaItem item) async {
    setState(() => _editing = true);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => item.kind == MediaKind.video
              ? VideoEditorPage(tools: widget.model as GalleryTools, item: item)
              : PhotoEditorPage(
                  tools: widget.model as GalleryTools,
                  model: widget.model,
                  item: item,
                ),
        ),
      );
    } finally {
      if (mounted) setState(() => _editing = false);
    }
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
                      if (item.metadata.latitude != null &&
                          item.metadata.longitude != null)
                        (
                          'Location',
                          '${item.metadata.latitude!.toStringAsFixed(5)}, '
                              '${item.metadata.longitude!.toStringAsFixed(5)}',
                        ),
                      if (item.metadata.attributes['analysis.place']
                          case final place?)
                        ('Place', place),
                      if (item.metadata.attributes['analysis.people']
                          case final people? when people.isNotEmpty)
                        ('People', people),
                      if (item.metadata.attributes['analysis.labels']
                          case final labels? when labels.isNotEmpty)
                        ('Found in photo', labels),
                      if (item.metadata.attributes.keys.any(
                        (key) => key.startsWith('user.'),
                      ))
                        (
                          'Adjusted',
                          'Date or location corrected in nexGallery',
                        ),
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

  /// Enough pixels for the screen with room to zoom, bounded so one decoded
  /// photo stays under about 40 MB.
  int _fullSize(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size.longestSide * media.devicePixelRatio;
    return (screen * 1.5).clamp(2048, 3072).round();
  }

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
