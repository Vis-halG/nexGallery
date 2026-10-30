import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../../core/catalog_models.dart';
import '../../core/media_item.dart';
import 'path_guard.dart';
import 'security.dart';
import 'sha256.dart';

final class CatalogApiException implements Exception {
  const CatalogApiException(this.status, this.code, this.message);
  final int status;
  final String code, message;
}

typedef CatalogLoader = Future<CatalogSnapshot> Function();

/// Bounded cursor paging and an in-memory delta journal. Tokens are HMAC-bound
/// to the device, permissions, query and server lifetime. A stale client must
/// resync rather than silently miss deletions or skip rows during an edit.
final class RemoteCatalogIndex {
  RemoteCatalogIndex(
    this.guard,
    this.load, {
    this.refreshInterval = const Duration(seconds: 3),
    this.journalLimit = 4096,
  });
  final PathGuard guard;
  final CatalogLoader load;
  final Duration refreshInterval;
  final int journalLimit;
  final _key = SecretKey(
    List.generate(32, (_) => Random.secure().nextInt(256)),
  );
  final _entities = <String, Map<String, Object?>>{};
  final _journal =
      ListQueue<
        ({
          int sequence,
          String key,
          Map<String, Object?> value,
          Map<String, Object?>? previous,
          bool deleted,
        })
      >();
  DateTime? _loaded;
  Future<void>? _refreshing;
  int _sequence = 0, _floor = 0;

  void invalidate() => _loaded = null;

  Future<void> refresh() async {
    if (_refreshing case final running?) return running;
    if (_loaded != null &&
        DateTime.now().difference(_loaded!) < refreshInterval) {
      return;
    }
    final work = _refresh();
    _refreshing = work;
    try {
      await work;
    } finally {
      _refreshing = null;
    }
  }

  Future<void> _refresh() async {
    final snapshot = await load();
    final next = <String, Map<String, Object?>>{};
    final localIds = <String, List<Map<String, Object?>>>{};
    for (final item in snapshot.items) {
      if (!item.isAvailable ||
          item.section != MediaSection.library ||
          !const [MediaKind.image, MediaKind.video].contains(item.kind)) {
        continue;
      }
      final uri = Uri.tryParse(item.uri);
      if (uri == null || uri.scheme != 'file') continue;
      var path = File.fromUri(uri).absolute.path;
      if (!guard.roots.values.any(
        (root) => p.isWithin(root.canonicalPath, path),
      )) {
        // Windows can return an 8.3 path (RUNNER~1, for example) for TEMP
        // while the guard holds the long canonical path. Resolve aliases
        // before filtering, then still authorize through PathGuard below.
        try {
          path = await File(path).resolveSymbolicLinks();
        } on FileSystemException {
          continue;
        }
      }
      for (final root in guard.roots.values) {
        if (!p.isWithin(root.canonicalPath, path)) continue;
        final relative = p
            .relative(path, from: root.canonicalPath)
            .replaceAll('\\', '/');
        try {
          final checked = await guard.resolve(
            root.id,
            relative,
            allowRoot: false,
          );
          if (await FileSystemEntity.type(checked, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
        } on RemotePathException {
          continue;
        }
        final id = sha256Hex(utf8.encode('${root.id}/$relative'));
        final value = <String, Object?>{
          'id': id, 'entity': 'item', 'root': root.id, 'path': relative,
          'name': item.name, 'kind': item.kind.name, 'type': 'file',
          'size': item.metadata.sizeBytes,
          'version':
              '${item.metadata.sizeBytes}:${item.metadata.modifiedAt.toUtc().microsecondsSinceEpoch}',
          'modifiedAt': item.metadata.modifiedAt.toUtc().toIso8601String(),
          'takenAt': (item.metadata.takenAt ?? item.metadata.modifiedAt)
              .toUtc()
              .toIso8601String(),
          'favorite': item.isFavorite,
          'width': item.metadata.width, 'height': item.metadata.height,
          // Never serialize raw URIs, filesystem attributes, OCR, face vectors
          // or paths outside the explicitly shared root.
        };
        next['item:$id'] = value;
        (localIds[item.id] ??= []).add(value);
      }
    }
    for (final album in snapshot.albums) {
      final members = [for (final id in album.itemIds) ...?localIds[id]];
      if (members.isEmpty) continue;
      next['album:${album.id}'] = {
        'id': album.id,
        'entity': album.kind == AlbumKind.person ? 'person' : 'album',
        'name': album.name,
        'members': members
            .map((v) => {'id': v['id'], 'root': v['root']})
            .toList(),
      };
    }
    // Named people are written into catalogue tags by the local face editor.
    // Sharing these groups never requires sending biometric embeddings.
    final people = <String, List<Map<String, Object?>>>{};
    final hasPersonAlbums = snapshot.albums.any(
      (album) => album.kind == AlbumKind.person,
    );
    for (final item in snapshot.items) {
      if (hasPersonAlbums) break;
      final tags = item.metadata.attributes['analysis.people'];
      if (tags == null) continue;
      for (final name
          in tags.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty)) {
        (people[name] ??= []).addAll(localIds[item.id] ?? const []);
      }
    }
    for (final entry in people.entries) {
      if (entry.value.isEmpty) continue;
      final id = sha256Hex(utf8.encode(entry.key));
      next['person:$id'] = {
        'id': id,
        'entity': 'person',
        'name': entry.key,
        'members': entry.value
            .map((v) => {'id': v['id'], 'root': v['root']})
            .toList(),
      };
    }
    void record(String key, Map<String, Object?> value, bool deleted) {
      _journal.add((
        sequence: ++_sequence,
        key: key,
        value: value,
        previous: _entities[key],
        deleted: deleted,
      ));
    }

    for (final entry in next.entries) {
      if (jsonEncode(_entities[entry.key]) != jsonEncode(entry.value)) {
        record(entry.key, entry.value, false);
      }
    }
    for (final entry in _entities.entries) {
      if (!next.containsKey(entry.key)) record(entry.key, entry.value, true);
    }
    while (_journal.length > journalLimit) {
      _floor = _journal.removeFirst().sequence;
    }
    _entities
      ..clear()
      ..addAll(next);
    _loaded = DateTime.now();
  }

  String _scope(DeviceIdentity identity) => jsonEncode([
    identity.id,
    identity.scopes.toList()..sort(),
    identity.roots == null ? null : (identity.roots!.toList()..sort()),
  ]);

  Map<String, Object?>? _visible(
    Map<String, Object?> value,
    DeviceIdentity identity,
    String? root,
  ) {
    if (value['entity'] == 'item') {
      final id = value['root'] as String;
      return identity.canUseRoot(id) && (root == null || root == id)
          ? value
          : null;
    }
    final members = (value['members'] as List)
        .cast<Map<String, Object?>>()
        .where(
          (v) =>
              identity.canUseRoot(v['root'] as String) &&
              (root == null || v['root'] == root),
        )
        .toList();
    if (members.isEmpty) return null;
    return {
      'id': value['id'],
      'entity': value['entity'],
      'name': value['name'],
      'count': members.length,
      'cover': members.first,
    };
  }

  Future<String> _token(Map<String, Object?> value) async {
    final payload = base64Url.encode(utf8.encode(jsonEncode(value)));
    final mac = await Hmac.sha256().calculateMac(
      utf8.encode(payload),
      secretKey: _key,
    );
    return '$payload.${base64Url.encode(mac.bytes)}';
  }

  Future<Map<String, dynamic>> _parse(String token) async {
    try {
      if (token.length > 4096) throw const FormatException();
      final parts = token.split('.');
      if (parts.length != 2) throw const FormatException();
      final mac = await Hmac.sha256().calculateMac(
        utf8.encode(parts[0]),
        secretKey: _key,
      );
      if (!constantTimeEquals(parts[1], base64Url.encode(mac.bytes))) {
        throw const FormatException();
      }
      return jsonDecode(utf8.decode(base64Url.decode(parts[0])))
          as Map<String, dynamic>;
    } catch (_) {
      throw const CatalogApiException(
        409,
        'resync_required',
        'The catalogue token expired. Refresh this PC library.',
      );
    }
  }

  Future<Map<String, Object?>> page(
    String collection,
    Map<String, String> query,
    DeviceIdentity identity,
  ) async {
    await refresh();
    final limit = _limit(query);
    final root = query['root'],
        album = query['album'],
        person = query['person'];
    final search = (query['q'] ?? '').trim().toLowerCase();
    if (search.length > 256) throw const FormatException('Search is too long.');
    final signature = jsonEncode([
      collection,
      _scope(identity),
      root,
      album,
      person,
      search,
      limit,
    ]);
    var offset = 0;
    if (query['cursor'] case final cursor?) {
      final value = await _parse(cursor);
      if (value['query'] != signature ||
          value['sequence'] != _sequence ||
          value['offset'] is! int) {
        throw const CatalogApiException(
          409,
          'resync_required',
          'The PC library changed. Refresh to continue.',
        );
      }
      offset = value['offset'] as int;
    }
    var rows = _entities.values
        .map((v) => _visible(v, identity, root))
        .whereType<Map<String, Object?>>()
        .where((v) => v['entity'] == collection)
        .toList();
    if (collection == 'item' && (album != null || person != null)) {
      final group = _entities.values
          .where(
            (v) =>
                v['id'] == (album ?? person) &&
                v['entity'] == (album != null ? 'album' : 'person'),
          )
          .firstOrNull;
      final allowed = group == null
          ? <Object?>{}
          : (group['members'] as List)
                .cast<Map<String, Object?>>()
                .where(
                  (v) =>
                      identity.canUseRoot(v['root'] as String) &&
                      (root == null || v['root'] == root),
                )
                .map((v) => v['id'])
                .toSet();
      rows = rows.where((v) => allowed.contains(v['id'])).toList();
    }
    if (search.isNotEmpty) {
      rows = rows
          .where((v) => (v['name'] as String).toLowerCase().contains(search))
          .toList();
    }
    rows.sort((a, b) {
      final order = collection == 'item'
          ? (b['takenAt'] as String).compareTo(a['takenAt'] as String)
          : (a['name'] as String).compareTo(b['name'] as String);
      return order != 0
          ? order
          : (a['id'] as String).compareTo(b['id'] as String);
    });
    if (offset < 0 || offset > rows.length) {
      throw const FormatException('Invalid catalogue offset.');
    }
    final end = min(offset + limit, rows.length);
    return {
      'items': rows.sublist(offset, end),
      'total': rows.length,
      'nextCursor': end < rows.length
          ? await _token({
              'query': signature,
              'sequence': _sequence,
              'offset': end,
            })
          : null,
      'changeToken': await _token({
        'scope': _scope(identity),
        'sequence': _sequence,
      }),
    };
  }

  Future<Map<String, Object?>> changes(
    Map<String, String> query,
    DeviceIdentity identity,
  ) async {
    await refresh();
    final limit = _limit(query);
    final token = query['since'];
    if (token == null) {
      throw const FormatException('A change token is required.');
    }
    final parsed = await _parse(token);
    final since = parsed['sequence'];
    if (parsed['scope'] != _scope(identity) ||
        since is! int ||
        since < _floor ||
        since > _sequence) {
      throw const CatalogApiException(
        409,
        'resync_required',
        'Change history expired or permissions changed. Refresh the PC library.',
      );
    }
    final result = <Map<String, Object?>>[];
    var through = since;
    for (final change in _journal.where((c) => c.sequence > since)) {
      final visible = _visible(change.value, identity, null);
      final wasVisible = change.previous == null
          ? null
          : _visible(change.previous!, identity, null);
      final deleted = change.deleted || (visible == null && wasVisible != null);
      if (visible != null || wasVisible != null) {
        result.add({
          'deleted': deleted,
          'entity': change.value['entity'],
          'id': change.value['id'],
          if (!deleted) 'value': visible,
        });
      }
      through = change.sequence;
      if (result.length >= limit) break;
    }
    if (result.length < limit) through = _sequence;
    return {
      'changes': result,
      'hasMore': through < _sequence,
      'changeToken': await _token({
        'scope': _scope(identity),
        'sequence': through,
      }),
    };
  }

  int _limit(Map<String, String> query) {
    final limit = int.tryParse(query['limit'] ?? '100');
    if (limit == null || limit < 1 || limit > 200) {
      throw const FormatException('Limit must be between 1 and 200.');
    }
    return limit;
  }
}
