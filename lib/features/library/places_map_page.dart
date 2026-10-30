import '../../l10n/app_strings.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/media_item.dart';
import '../../src/gallery_model.dart';
import '../../src/gallery_tools.dart';
import '../photos/media_viewer.dart';
import '../common/media_tile.dart';

/// Equirectangular coordinates, including the antimeridian and polar limits.
Offset projectLocation(double latitude, double longitude, Size size) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude.abs() > 90 ||
      longitude.abs() > 180) {
    throw const FormatException('Invalid photo coordinates.');
  }
  return Offset(
    (longitude + 180) / 360 * size.width,
    (90 - latitude) / 180 * size.height,
  );
}

class PlacesMapPage extends StatefulWidget {
  const PlacesMapPage({required this.model, required this.tools, super.key});
  final GalleryModel model;
  final GalleryTools tools;
  @override
  State<PlacesMapPage> createState() => _PlacesMapPageState();
}

class _PlacesMapPageState extends State<PlacesMapPage> {
  final _transform = TransformationController();
  late final _land = rootBundle.loadString('assets/maps/land.geojson').then((
    text,
  ) {
    final features = (jsonDecode(text) as Map)['features'] as List;
    final rings = <List<Offset>>[];
    for (final feature in features) {
      final geometry = feature['geometry'] as Map;
      final coordinates = geometry['coordinates'] as List;
      final polygons = geometry['type'] == 'MultiPolygon'
          ? coordinates
          : [coordinates];
      for (final polygon in polygons) {
        for (final ring in polygon as List) {
          rings.add(
            (ring as List)
                .map(
                  (point) => Offset(
                    (point[0] as num).toDouble(),
                    (point[1] as num).toDouble(),
                  ),
                )
                .toList(),
          );
        }
      }
    }
    return rings;
  });
  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _photos(List<MediaItem> items) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: [
            ListTile(
              title: Text(
                items.first.metadata.attributes['analysis.place'] ??
                    'Photos at this location',
              ),
              subtitle: Text('${items.length} photos'),
              trailing: IconButton(
                tooltip: context.tr('Close'),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(sheetContext),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: items.length,
                itemBuilder: (_, index) => InkWell(
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MediaViewer(
                          model: widget.model,
                          items: items,
                          initialIndex: index,
                        ),
                      ),
                    );
                  },
                  child: MediaThumbnail(
                    item: items[index],
                    model: widget.model,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const AppText('Photo map'),
      actions: [
        IconButton(
          tooltip: context.tr('Reset map'),
          onPressed: () => _transform.value = Matrix4.identity(),
          icon: const Icon(Icons.fit_screen),
        ),
      ],
    ),
    body: AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final groups = <String, List<MediaItem>>{};
        for (final item in widget.tools.localItems) {
          final lat = item.metadata.latitude, lon = item.metadata.longitude;
          if (!item.isAvailable ||
              item.section != MediaSection.library ||
              !widget.model.canAccessMedia(item) ||
              lat == null ||
              lon == null ||
              !lat.isFinite ||
              !lon.isFinite ||
              lat.abs() > 90 ||
              lon.abs() > 180) {
            continue;
          }
          // Nearby coordinates share a marker; zooming never launches a network
          // request and no coordinate is sent to a tile provider.
          (groups['${lat.toStringAsFixed(1)},${lon.toStringAsFixed(1)}'] ??= [])
              .add(item);
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                groups.isEmpty
                    ? 'No GPS photos yet. Run the Places scan to read photo locations.'
                    : 'Pinch or scroll to zoom. Select a marker to see photos.',
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = math.max(
                    constraints.maxWidth,
                    constraints.maxHeight * 2,
                  );
                  final size = Size(width, width / 2);
                  final scheme = Theme.of(context).colorScheme;
                  return ClipRect(
                    child: InteractiveViewer(
                      transformationController: _transform,
                      constrained: false,
                      minScale: .5,
                      maxScale: 12,
                      child: SizedBox.fromSize(
                        size: size,
                        child: Stack(
                          children: [
                            FutureBuilder(
                              future: _land,
                              builder: (context, snapshot) => CustomPaint(
                                size: size,
                                painter: _LandPainter(
                                  snapshot.data ?? const [],
                                  scheme,
                                ),
                              ),
                            ),
                            for (final items in groups.values)
                              Positioned(
                                left:
                                    projectLocation(
                                      items.first.metadata.latitude!,
                                      items.first.metadata.longitude!,
                                      size,
                                    ).dx.clamp(24, width - 24) -
                                    24,
                                top:
                                    projectLocation(
                                      items.first.metadata.latitude!,
                                      items.first.metadata.longitude!,
                                      size,
                                    ).dy.clamp(24, size.height - 24) -
                                    24,
                                child: Semantics(
                                  label:
                                      '${items.length} photos, ${items.first.metadata.attributes['analysis.place'] ?? 'location'}',
                                  button: true,
                                  child: IconButton.filled(
                                    tooltip: '${items.length} photos',
                                    onPressed: () => _photos(items),
                                    icon: const Icon(Icons.location_on),
                                    iconSize: 22,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(8),
              child: AppText('Offline map · Natural Earth public-domain data'),
            ),
          ],
        );
      },
    ),
  );
}

class _LandPainter extends CustomPainter {
  const _LandPainter(this.rings, this.scheme);
  final List<List<Offset>> rings;
  final ColorScheme scheme;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = scheme.secondaryContainer,
    );
    final grid = Paint()
      ..color = scheme.outline.withValues(alpha: .2)
      ..strokeWidth = .5;
    for (var longitude = -150; longitude < 180; longitude += 30) {
      final x = (longitude + 180) / 360 * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var latitude = -60; latitude < 90; latitude += 30) {
      final y = (90 - latitude) / 180 * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (final ring in rings) {
      final path = Path();
      for (var i = 0; i < ring.length; i++) {
        final point = projectLocation(
          ring[i].dy.clamp(-90, 90),
          ring[i].dx.clamp(-180, 180),
          size,
        );
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(path, Paint()..color = scheme.surfaceContainerHighest);
    }
  }

  @override
  bool shouldRepaint(_LandPainter old) =>
      old.rings != rings || old.scheme != scheme;
}
