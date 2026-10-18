import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/services.dart';

final class Place {
  const Place(
    this.city,
    this.country,
    this.latitude,
    this.longitude,
    this.populationK,
  );
  final String city;
  final String country;
  final double latitude;
  final double longitude;
  final int populationK;
  String get label => '$city, $country';
}

/// Reverse geocoding against a bundled GeoNames (CC BY 4.0) list of cities
/// with at least 15,000 people. Coordinates never leave the device.
final class OfflinePlaces {
  OfflinePlaces._(this._cells);

  static const asset = 'assets/places/cities.tsv.gz';
  static Future<OfflinePlaces>? _shared;

  final Map<int, List<Place>> _cells;

  static Future<OfflinePlaces> load() => _shared ??= () async {
    final data = await rootBundle.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return Isolate.run(() => parse(utf8.decode(gzip.decode(bytes))));
  }();

  /// Parses `C<TAB>code<TAB>country` lines followed by
  /// `city<TAB>code<TAB>lat<TAB>lon<TAB>thousands` lines.
  static OfflinePlaces parse(String tsv) {
    final countries = <String, String>{};
    final cells = <int, List<Place>>{};
    for (final line in const LineSplitter().convert(tsv)) {
      final fields = line.split('\t');
      if (fields.length == 3 && fields[0] == 'C') {
        countries[fields[1]] = fields[2];
        continue;
      }
      if (fields.length != 5) continue;
      final lat = double.tryParse(fields[2]), lon = double.tryParse(fields[3]);
      if (lat == null || lon == null) continue;
      final place = Place(
        fields[0],
        countries[fields[1]] ?? fields[1],
        lat,
        lon,
        int.tryParse(fields[4]) ?? 15,
      );
      (cells[_cell(lat.floor(), lon.floor())] ??= []).add(place);
    }
    return OfflinePlaces._(cells);
  }

  static int _cell(int lat, int lon) {
    final wrapped = ((lon + 180) % 360 + 360) % 360 - 180;
    return (lat + 90) * 1000 + (wrapped + 180);
  }

  /// The best city within [maxKm]. Larger cities win over nearby suburbs:
  /// distance is divided by a population weight.
  Place? nearest(double latitude, double longitude, {double maxKm = 50}) {
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      return null;
    }
    Place? best;
    var bestScore = double.infinity;
    final lat = latitude.floor(), lon = longitude.floor();
    for (var dLat = -1; dLat <= 1; dLat++) {
      for (var dLon = -1; dLon <= 1; dLon++) {
        for (final place
            in _cells[_cell(lat + dLat, lon + dLon)] ?? const <Place>[]) {
          final km = distanceKm(
            latitude,
            longitude,
            place.latitude,
            place.longitude,
          );
          if (km > maxKm) continue;
          final weight = math.sqrt(math.max(1, place.populationK / 15));
          final score = km / weight;
          if (score < bestScore) {
            bestScore = score;
            best = place;
          }
        }
      }
    }
    return best;
  }
}

double distanceKm(double lat1, double lon1, double lat2, double lon2) {
  const radius = 6371.0;
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * radius * math.asin(math.min(1, math.sqrt(a)));
}
