import '../../core/media_item.dart';

enum MemoryKind { onThisDay, monthRecap, trip, person, favorites }

final class Memory {
  const Memory({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.items,
  });

  final String id;
  final MemoryKind kind;
  final String title;
  final String subtitle;

  /// Chronological, so a slideshow plays the story in order.
  final List<MediaItem> items;

  MediaItem get cover => items.firstWhere(
    (item) => item.isFavorite && item.kind == MediaKind.image,
    orElse: () => items.firstWhere(
      (item) => item.kind == MediaKind.image,
      orElse: () => items[items.length ~/ 2],
    ),
  );
}

const _months = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

DateTime memoryDate(MediaItem item) =>
    (item.metadata.takenAt ?? item.metadata.modifiedAt).toLocal();

/// Builds local memories from dates, favorites, named people
/// (`analysis.people`) and offline places (`analysis.place`).
List<Memory> buildMemories(
  Iterable<MediaItem> source, {
  required DateTime now,
}) {
  final media =
      source
          .where(
            (item) =>
                item.isAvailable &&
                item.section == MediaSection.library &&
                (item.kind == MediaKind.image || item.kind == MediaKind.video),
          )
          .toList()
        ..sort((a, b) => memoryDate(a).compareTo(memoryDate(b)));
  final today = DateTime(now.year, now.month, now.day);
  final memories = <Memory>[];

  final byYear = <int, List<MediaItem>>{};
  for (final item in media) {
    final date = memoryDate(item);
    if (date.year >= now.year) continue;
    final anniversary = DateTime(now.year, date.month, date.day);
    if (anniversary.difference(today).inDays.abs() <= 3) {
      (byYear[date.year] ??= []).add(item);
    }
  }
  for (final year in byYear.keys.toList()..sort((a, b) => b.compareTo(a))) {
    final items = byYear[year]!;
    if (items.length < 3) continue;
    final years = now.year - year;
    memories.add(
      Memory(
        id: 'on-this-day-$year',
        kind: MemoryKind.onThisDay,
        title: years == 1 ? '1 year ago' : '$years years ago',
        subtitle: 'This week in $year · ${_count(items)}',
        items: _sample(items, 80),
      ),
    );
  }

  final lastMonth = DateTime(now.year, now.month - 1);
  final recap = media.where((item) {
    final date = memoryDate(item);
    return date.year == lastMonth.year && date.month == lastMonth.month;
  }).toList();
  if (recap.length >= 8) {
    memories.add(
      Memory(
        id: 'month-${lastMonth.year}-${lastMonth.month}',
        kind: MemoryKind.monthRecap,
        title: '${_months[lastMonth.month - 1]} ${lastMonth.year}',
        subtitle: 'Your month in ${_count(recap)}',
        items: _sample(recap, 60),
      ),
    );
  }

  memories.addAll(_trips(media));

  final people = <String, List<MediaItem>>{};
  for (final item in media) {
    final names = item.metadata.attributes['analysis.people'] ?? '';
    for (final name in names.split(',').map((v) => v.trim())) {
      if (name.isNotEmpty) (people[name] ??= []).add(item);
    }
  }
  final ranked = people.entries.where((e) => e.value.length >= 6).toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final entry in ranked.take(5)) {
    memories.add(
      Memory(
        id: 'person-${entry.key.toLowerCase()}',
        kind: MemoryKind.person,
        title: 'With ${entry.key}',
        subtitle: _count(entry.value),
        items: _sample(entry.value, 80),
      ),
    );
  }

  final favorites = <int, List<MediaItem>>{};
  for (final item in media.where((item) => item.isFavorite)) {
    (favorites[memoryDate(item).year] ??= []).add(item);
  }
  for (final year in (favorites.keys.toList()..sort((a, b) => b - a)).take(3)) {
    final items = favorites[year]!;
    if (items.length < 6) continue;
    memories.add(
      Memory(
        id: 'favorites-$year',
        kind: MemoryKind.favorites,
        title: 'Favorites from $year',
        subtitle: _count(items),
        items: _sample(items, 80),
      ),
    );
  }
  return memories;
}

/// A trip is a run of photos at one place other than the most common ("home")
/// place, with no gap longer than three days.
List<Memory> _trips(List<MediaItem> media) {
  final located = media
      .where((item) => (item.metadata.attributes['analysis.place'] ?? '') != '')
      .toList();
  if (located.isEmpty) return const [];
  final counts = <String, int>{};
  for (final item in located) {
    final place = item.metadata.attributes['analysis.place']!;
    counts[place] = (counts[place] ?? 0) + 1;
  }
  final home = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  final trips = <Memory>[];
  List<MediaItem>? run;
  String? runPlace;
  void finish() {
    final items = run;
    if (items != null && items.length >= 5) {
      final start = memoryDate(items.first);
      final city = runPlace!.split(',').first.trim();
      trips.add(
        Memory(
          id: 'trip-${runPlace!.toLowerCase()}-${start.millisecondsSinceEpoch}',
          kind: MemoryKind.trip,
          title: 'Trip to $city',
          subtitle:
              '${_months[start.month - 1]} ${start.year} · ${_count(items)}',
          items: _sample(items, 80),
        ),
      );
    }
    run = null;
    runPlace = null;
  }

  for (final item in located) {
    final place = item.metadata.attributes['analysis.place']!;
    if (place == home) continue;
    final current = run;
    if (current != null &&
        (place != runPlace ||
            memoryDate(item).difference(memoryDate(current.last)).inDays > 3)) {
      finish();
    }
    (run ??= []).add(item);
    runPlace = place;
  }
  finish();
  return trips.reversed.take(5).toList();
}

List<MediaItem> _sample(List<MediaItem> items, int maximum) {
  if (items.length <= maximum) return List.unmodifiable(items);
  final step = items.length / maximum;
  return List.unmodifiable([
    for (var i = 0; i < maximum; i++) items[(i * step).floor()],
  ]);
}

String _count(List<MediaItem> items) {
  final videos = items.where((item) => item.kind == MediaKind.video).length;
  final photos = items.length - videos;
  return [
    if (photos > 0) '$photos ${photos == 1 ? 'photo' : 'photos'}',
    if (videos > 0) '$videos ${videos == 1 ? 'video' : 'videos'}',
  ].join(' and ');
}
