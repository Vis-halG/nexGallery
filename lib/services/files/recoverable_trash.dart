import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/media_item.dart';
import 'file_tools.dart';

/// App-owned physical Trash, independent of the Windows Recycle Bin.
final class RecoverableTrash {
  Future<MediaItem> put(MediaItem item) async {
    if (item.section == MediaSection.trash) return item;
    final source = File.fromUri(Uri.parse(item.uri));
    final directory = Directory(
      p.join(source.parent.path, '.nexgallery-trash'),
    );
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Trash folder cannot be a link.');
    }
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('Trash requires a regular file.');
    }
    await directory.create();
    final payload = File(p.join(directory.path, '${uniqueId()}.payload'));
    final journal = File('${payload.path}.json');
    await journal.writeAsString(jsonEncode(item.toJson()), flush: true);
    try {
      await source.rename(payload.path);
    } catch (_) {
      await journal.delete();
      rethrow;
    }
    return item.copyWith(
      uri: payload.uri.toString(),
      section: MediaSection.trash,
      deletedAt: DateTime.now().toUtc(),
      metadata: item.metadata.copyWith(
        attributes: {
          ...item.metadata.attributes,
          'trash.originalUri': item.uri,
          'trash.journal': journal.path,
        },
      ),
    );
  }

  /// Reconcile a crash between moving a file and committing its catalogue row.
  /// Journals are accepted only beside their original, within a selected root.
  Stream<MediaItem> recover(String selectedRoot) async* {
    if (!await Directory(selectedRoot).exists()) return;
    final root = await Directory(selectedRoot).resolveSymbolicLinks();
    final pending = <Directory>[Directory(root)];
    var count = 0;
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      await for (final entry in directory.list(followLinks: false)) {
        if (++count > 1000000) {
          throw const FileSystemException(
            'Trash recovery scan exceeds the item limit.',
          );
        }
        if (entry is! Directory) continue;
        if (p.basename(entry.path) != '.nexgallery-trash') {
          if (!p.basename(entry.path).startsWith('.')) pending.add(entry);
          continue;
        }
        await for (final journal in entry.list(followLinks: false)) {
          if (journal is! File ||
              !RegExp(r'^[a-f0-9]{32}\.payload\.json$')
                  .hasMatch(p.basename(journal.path))) {
            continue;
          }
          try {
            if (await journal.length() > 1 << 20) continue;
            final original = MediaItem.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(await journal.readAsString()) as Map,
              ),
            );
            final originalFile = File.fromUri(Uri.parse(original.uri));
            if (!p.isWithin(root, originalFile.path) ||
                !p.equals(originalFile.parent.path, entry.parent.path)) {
              continue;
            }
            final payload = File(
              journal.path.substring(0, journal.path.length - 5),
            );
            if (await FileSystemEntity.type(payload.path, followLinks: false) ==
                FileSystemEntityType.file) {
              yield original.copyWith(
                uri: payload.uri.toString(),
                section: MediaSection.trash,
                deletedAt: (await journal.stat()).modified.toUtc(),
                metadata: original.metadata.copyWith(
                  attributes: {
                    ...original.metadata.attributes,
                    'trash.originalUri': original.uri,
                    'trash.journal': journal.path,
                  },
                ),
              );
            } else if (await FileSystemEntity.type(
                  originalFile.path,
                  followLinks: false,
                ) ==
                FileSystemEntityType.file) {
              yield original;
              await journal.delete();
            }
          } on FormatException {
            continue;
          } on TypeError {
            continue;
          }
        }
      }
    }
  }

  Future<MediaItem> restore(MediaItem item) async {
    final original = item.metadata.attributes['trash.originalUri'];
    if (original == null) return item.copyWith(section: MediaSection.library);
    final target = File.fromUri(Uri.parse(original));
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException(
        'Restore cannot overwrite an existing original.',
      );
    }
    await File.fromUri(Uri.parse(item.uri)).rename(target.path);
    final attributes = {...item.metadata.attributes}
      ..remove('trash.originalUri')
      ..remove('trash.journal');
    return item.copyWith(
      uri: original,
      section: MediaSection.library,
      deletedAt: null,
      metadata: item.metadata.copyWith(attributes: attributes),
    );
  }

  Future<void> finish(MediaItem item) async {
    final journal = item.metadata.attributes['trash.journal'];
    if (journal != null && await File(journal).exists()) {
      await File(journal).delete();
    }
  }
}
