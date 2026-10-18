import 'dart:typed_data';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import '../services/organization/memories.dart';

enum WallpaperTarget { home, lock, both }

/// Optional organization contract for batch actions, albums and corrections.
/// Lightweight gallery fixtures only need GalleryModel.
abstract interface class GalleryOrganizer {
  String? get activeAlbumId;

  /// Memories built locally from the accessible library; cached per change.
  List<Memory> get memories;
  CatalogSortField get sortField;
  CatalogSortDirection get sortDirection;

  void setSort(CatalogSortField field, CatalogSortDirection direction);
  Future<void> renameAlbum(String albumId, String name);
  Future<void> deleteAlbum(String albumId);
  Future<void> setAlbumCover(String albumId, MediaItem? item);
  Future<void> addAllToAlbum(Iterable<MediaItem> items, String albumId);
  Future<void> removeFromAlbum(String albumId, Iterable<MediaItem> items);
  Future<void> setFavorites(Iterable<MediaItem> items, bool favorite);
  Future<void> archiveAll(Iterable<MediaItem> items);
  Future<int> moveAllToTrash(Iterable<MediaItem> items);
  Future<int> emptyTrash();
  Future<void> shareAll(Iterable<MediaItem> items);

  /// Stores a user correction in the catalogue. Originals are never rewritten.
  Future<void> correctMetadata(
    MediaItem item, {
    DateTime? takenAt,
    (double, double)? location,
    bool clearLocation = false,
  });
  Future<void> setWallpaper(MediaItem item, WallpaperTarget target);

  /// Encrypted export of albums, favorites, archive and user corrections.
  Future<Uint8List> exportOrganization(String password);
  Future<int> importOrganization(Uint8List backup, String password);
}
