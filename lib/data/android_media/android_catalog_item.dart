import '../../core/media_item.dart';
import 'android_media_bridge.dart';

MediaItem androidCatalogItem(AndroidMediaItem item) {
  final now = DateTime.now().toUtc();
  final name = item.displayName ?? item.title ?? '${item.type.name}-${item.id}';
  final dot = name.lastIndexOf('.');
  return MediaItem(
    id: 'android_${item.type.name}_${item.id}',
    name: name,
    uri: item.uri.toString(),
    relativePath: item.relativePath ?? item.bucketName ?? '',
    kind: switch (item.type) {
      AndroidMediaType.image => MediaKind.image,
      AndroidMediaType.video => MediaKind.video,
      AndroidMediaType.audio => MediaKind.audio,
    },
    source: MediaSource.phone,
    indexedAt: now,
    metadata: MediaMetadata(
      sizeBytes: item.sizeBytes ?? 0,
      modifiedAt: item.dateModifiedSeconds == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(
              item.dateModifiedSeconds! * 1000,
              isUtc: true,
            ),
      createdAt: item.dateAddedSeconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              item.dateAddedSeconds! * 1000,
              isUtc: true,
            ),
      takenAt: item.dateTakenMilliseconds == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              item.dateTakenMilliseconds!,
              isUtc: true,
            ),
      duration: item.durationMilliseconds == null
          ? null
          : Duration(milliseconds: item.durationMilliseconds!),
      width: item.width,
      height: item.height,
      mimeType: item.mimeType,
      extension: dot <= 0 || dot == name.length - 1
          ? null
          : name.substring(dot + 1).toLowerCase(),
      attributes: {
        if (item.bucketName != null) 'bucket': item.bucketName!,
        if (item.artist != null) 'artist': item.artist!,
        if (item.album != null) 'album': item.album!,
      },
    ),
  );
}
