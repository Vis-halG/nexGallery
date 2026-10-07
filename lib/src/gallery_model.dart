import 'package:flutter/foundation.dart';

import '../core/catalog_models.dart';
import '../core/media_item.dart';
import '../core/gallery_settings.dart';

enum GalleryLoadState {
  starting,
  permissionRequired,
  loading,
  ready,
  empty,
  error,
  unsupported,
}

enum GalleryCollection { timeline, favorites, archive, trash }

/// Small presentation contract shared by the adaptive phone and desktop UI.
/// Platform/storage details stay in [NexGalleryRuntime].
abstract interface class GalleryModel implements Listenable {
  GalleryLoadState get loadState;
  GalleryCollection get collection;
  String get searchText;
  String? get statusMessage;
  String? get errorMessage;
  bool get hasLimitedAccess;
  bool get isIndexing;
  int get indexedCount;
  int? get discoveredCount;
  List<MediaItem> get items;
  int get totalItemCount;
  bool get hasMoreItems;
  List<MediaAlbum> get albums;
  List<CategorySummary> get categories;
  GallerySettings get settings;
  List<String> get windowsFolders;

  Future<void> initialize();
  Future<void> requestAccessAndRefresh();
  Future<void> refresh();
  void loadMoreItems();
  Future<void> addWindowsFolder(String path);
  Future<void> removeWindowsFolder(String path);
  Future<void> updateSettings(GallerySettings value);
  Future<void> openAccessSettings();
  Future<Duration> readVideoPosition(MediaItem item);
  Future<void> saveVideoPosition(MediaItem item, Duration position);
  bool canAccessMedia(MediaItem item);
  void setSearchText(String value);
  void showCollection(GalleryCollection value);
  void showKinds(Set<MediaKind> kinds);
  void showAlbum(String albumId);
  Future<void> toggleFavorite(MediaItem item);
  Future<void> archive(MediaItem item);
  Future<bool> moveToTrash(MediaItem item);
  Future<bool> restore(MediaItem item);
  Future<bool> deletePermanently(MediaItem item);
  Future<void> createAlbum(String name);
  Future<void> addToAlbum(MediaItem item, String albumId);
  Future<void> open(MediaItem item);
  Future<void> share(MediaItem item);
  Future<Uint8List?> loadThumbnail(MediaItem item, {int size = 384});
}
