import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';

enum MediaTileAction {
  open,
  favorite,
  addToAlbum,
  archive,
  trash,
  restore,
  delete,
}

class MediaTile extends StatelessWidget {
  const MediaTile({
    required this.item,
    required this.model,
    required this.onAction,
    this.onSelect,
    this.selectionMode = false,
    this.selected = false,
    super.key,
  });

  final MediaItem item;
  final GalleryModel model;
  final ValueChanged<MediaTileAction> onAction;

  /// Toggles multi-selection. Long press starts it; taps toggle while active.
  final VoidCallback? onSelect;
  final bool selectionMode;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selectionMode ? selected : null,
      label:
          '${item.name}, ${_kindLabel(item.kind)}'
          '${item.isAvailable ? '' : ', drive unavailable'}',
      child: Card(
        clipBehavior: Clip.antiAlias,
        shape: selected
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: scheme.primary, width: 3),
              )
            : null,
        child: InkWell(
          onTap: selectionMode && onSelect != null
              ? onSelect
              : () => onAction(MediaTileAction.open),
          onLongPress: onSelect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedPadding(
                duration: const Duration(milliseconds: 120),
                padding: EdgeInsets.all(selected ? 8 : 0),
                child: MediaThumbnail(item: item, model: model),
              ),
              Positioned(
                top: 6,
                left: 6,
                child: selectionMode
                    ? Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected ? scheme.primary : Colors.white,
                        shadows: const [Shadow(blurRadius: 4)],
                      )
                    : _SourceBadge(source: item.source),
              ),
              if (!selectionMode)
                Positioned(
                  top: 2,
                  right: 2,
                  child: PopupMenuButton<MediaTileAction>(
                    tooltip: 'Actions for ${item.name}',
                    onSelected: onAction,
                    itemBuilder: (context) => _actions(item)
                        .map(
                          (entry) => PopupMenuItem<MediaTileAction>(
                            value: entry.$1,
                            enabled:
                                item.isAvailable ||
                                entry.$1 == MediaTileAction.open ||
                                entry.$1 == MediaTileAction.favorite ||
                                entry.$1 == MediaTileAction.addToAlbum ||
                                entry.$1 == MediaTileAction.archive,
                            child: Row(
                              children: [
                                Icon(entry.$2, size: 20),
                                const SizedBox(width: 12),
                                Text(entry.$3),
                              ],
                            ),
                          ),
                        )
                        .toList(growable: false),
                    icon: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.scrim.withValues(alpha: 0.54),
                        shape: BoxShape.circle,
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(5),
                        child: Icon(
                          Icons.more_vert_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 24, 10, 8),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.76),
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.isAvailable ? item.name : 'Drive unavailable',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (item.isFavorite) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.favorite_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ],
                      if (item.kind == MediaKind.video) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.play_circle_fill_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static List<(MediaTileAction, IconData, String)> _actions(MediaItem item) {
    if (item.section == MediaSection.trash) {
      return const [
        (MediaTileAction.open, Icons.open_in_new_rounded, 'Open'),
        (MediaTileAction.restore, Icons.restore_rounded, 'Restore'),
        (
          MediaTileAction.delete,
          Icons.delete_forever_rounded,
          'Delete forever',
        ),
      ];
    }
    return [
      const (MediaTileAction.open, Icons.open_in_new_rounded, 'Open'),
      (
        MediaTileAction.favorite,
        item.isFavorite ? Icons.heart_broken_rounded : Icons.favorite_rounded,
        item.isFavorite ? 'Remove favorite' : 'Favorite',
      ),
      const (
        MediaTileAction.addToAlbum,
        Icons.playlist_add_rounded,
        'Add to album',
      ),
      const (MediaTileAction.archive, Icons.archive_rounded, 'Archive'),
      const (
        MediaTileAction.trash,
        Icons.delete_outline_rounded,
        'Move to Trash',
      ),
    ];
  }
}

class MediaThumbnail extends StatefulWidget {
  const MediaThumbnail({
    required this.item,
    required this.model,
    this.fit = BoxFit.cover,
    this.size,
    this.sharpenTo,
    this.showFailureMessage = false,
    super.key,
  });

  final MediaItem item;
  final GalleryModel model;
  final BoxFit fit;

  /// Longest side to request in pixels; null matches the space on screen.
  final int? size;

  /// After [size] has loaded, also loads this many pixels and swaps in the
  /// sharper image, so the quick preview appears first.
  final int? sharpenTo;
  final bool showFailureMessage;

  @override
  State<MediaThumbnail> createState() => _MediaThumbnailState();
}

/// Thumbnail sizes, so neighbouring tiles share cached decodes.
const _thumbnailSizes = <int>[256, 384, 512, 768, 1024];

class _MediaThumbnailState extends State<MediaThumbnail> {
  Future<Uint8List?>? _future;
  var _loadedSize = 0;

  @override
  void didUpdateWidget(covariant MediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.uri != widget.item.uri ||
        oldWidget.item.metadata.modifiedAt != widget.item.metadata.modifiedAt ||
        oldWidget.item.isAvailable != widget.item.isAvailable ||
        oldWidget.model != widget.model) {
      _future = null;
      _loadedSize = 0;
      return;
    }
    // A page that becomes the open photo asks for the sharper image once
    // its quick preview has loaded.
    final sharper = widget.sharpenTo;
    final current = _future;
    if (current != null && sharper != null && sharper > _loadedSize) {
      current.then((_) {
        if (mounted && identical(current, _future) && sharper > _loadedSize) {
          setState(() => _ensureLoaded(sharper));
        }
      }, onError: (Object _) {});
    }
  }

  /// Requests more pixels when the tile or the viewer grows; the current
  /// image stays visible until the sharper one arrives.
  void _ensureLoaded(int size) {
    if (_future != null && size <= _loadedSize) return;
    _loadedSize = size;
    final future = _future = widget.item.isAvailable
        ? widget.model.loadThumbnail(widget.item, size: size)
        : Future<Uint8List?>.value();
    future.then((_) {
      final sharper = widget.sharpenTo;
      if (!mounted || sharper == null || sharper <= _loadedSize) return;
      if (!identical(future, _future)) return;
      setState(() => _ensureLoaded(sharper));
    }, onError: (Object _) {});
  }

  int _sizeFor(BoxConstraints constraints) {
    final explicit = widget.size;
    if (explicit != null) return explicit;
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final width = constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
    final height = constraints.hasBoundedHeight ? constraints.maxHeight : 0.0;
    final needed = (width > height ? width : height) * ratio;
    return _thumbnailSizes.firstWhere(
      (size) => size >= needed,
      orElse: () => _thumbnailSizes.last,
    );
  }

  Widget _placeholder() => _MediaPlaceholder(
    kind: widget.item.kind,
    message: !widget.item.isAvailable
        ? 'Drive unavailable'
        : widget.showFailureMessage
        ? 'Preview unavailable. Try opening with another app.'
        : null,
  );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensureLoaded(_sizeFor(constraints));
        return _image(context);
      },
    );
  }

  Widget _image(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null && bytes.isNotEmpty) {
          return Image.memory(
            bytes,
            fit: widget.fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => _placeholder(),
          );
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return _placeholder();
      },
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.kind, this.message});

  final MediaKind kind;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_kindIcon(kind), size: 42, color: scheme.onSurfaceVariant),
                if (message != null && constraints.maxHeight >= 180) ...[
                  const SizedBox(height: 8),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final MediaSource source;

  @override
  Widget build(BuildContext context) {
    final label = source == MediaSource.phone ? 'Phone' : 'PC';
    final icon = source == MediaSource.phone
        ? Icons.smartphone_rounded
        : Icons.computer_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

String _kindLabel(MediaKind kind) => switch (kind) {
  MediaKind.image => 'photo',
  MediaKind.video => 'video',
  MediaKind.document => 'document',
  MediaKind.audio => 'audio',
  MediaKind.apk => 'APK',
  MediaKind.archive => 'archive',
  MediaKind.other => 'file',
};

IconData _kindIcon(MediaKind kind) => switch (kind) {
  MediaKind.image => Icons.image_rounded,
  MediaKind.video => Icons.movie_rounded,
  MediaKind.document => Icons.description_rounded,
  MediaKind.audio => Icons.audio_file_rounded,
  MediaKind.apk => Icons.android_rounded,
  MediaKind.archive => Icons.folder_zip_rounded,
  MediaKind.other => Icons.insert_drive_file_rounded,
};
