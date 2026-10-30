import 'dart:io';

import '../../core/gallery_settings.dart';
import '../../core/media_item.dart';
import '../../services/remote/backup_source.dart';
import 'android_media_bridge.dart';
import 'android_catalog_item.dart';

final class AndroidBackupSource implements BackupSource {
  AndroidBackupSource(this.settings, this.items, this.bridge);
  @override
  final GallerySettings settings;
  @override
  final List<MediaItem> items;
  final AndroidMediaBridge bridge;

  static Future<AndroidBackupSource> load(
    GallerySettings settings, {
    bool Function()? cancelled,
  }) async {
    final bridge = AndroidMediaBridge.instance;
    final permission = await bridge.getPermissionStatus(
      mediaTypes: AndroidMediaType.values.toSet(),
    );
    final items = <MediaItem>[];
    for (final type in AndroidMediaType.values) {
      if (!permission.isGranted(type)) continue;
      var offset = 0;
      while (true) {
        if (cancelled?.call() == true) {
          return AndroidBackupSource(settings, items, bridge);
        }
        final page = await bridge.queryMedia(
          mediaType: type,
          offset: offset,
          limit: 500,
        );
        items.addAll(page.items.map(androidCatalogItem));
        if (!page.hasMore || page.nextOffset == null) break;
        offset = page.nextOffset!;
      }
    }
    return AndroidBackupSource(settings, items, bridge);
  }

  @override
  Future<File> materialize(MediaItem item) async =>
      File((await bridge.copyDocumentToAppCache(Uri.parse(item.uri))).path);
}
