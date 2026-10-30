import 'dart:io';

import '../../core/gallery_settings.dart';
import '../../core/media_item.dart';

/// A background worker needs authorized media and settings, not a writable
/// gallery catalogue. It must never overwrite the foreground app's snapshot.
abstract interface class BackupSource {
  GallerySettings get settings;
  List<MediaItem> get items;
  Future<File> materialize(MediaItem item);
}
