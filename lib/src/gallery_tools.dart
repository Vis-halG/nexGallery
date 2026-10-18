import 'dart:io';
import 'dart:typed_data';

import '../core/media_item.dart';

/// Optional feature contract; lightweight gallery fixtures need only GalleryModel.
abstract interface class GalleryTools {
  List<MediaItem> get localItems;
  Future<Directory> toolsDirectory();
  Future<File> materialize(MediaItem item);
  Future<String> saveEditedCopy(MediaItem original, Uint8List bytes);
  Future<String> saveVideoCopy(MediaItem original, File edited);
  Future<void> annotate(MediaItem item, MediaMetadata metadata);

  /// Stores many analysis results in one catalogue save. Only `analysis.*`
  /// attributes and coordinates are taken from [updates]; user corrections win.
  Future<void> annotateAll(
    Map<String, MediaMetadata Function(MediaMetadata)> updates,
  );
}
