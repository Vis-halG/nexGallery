import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:nex_gallery/core/media_item.dart';
import 'package:nex_gallery/services/editing/image_editor.dart';
import 'package:nex_gallery/services/files/file_tools.dart';
import 'package:nex_gallery/services/files/recoverable_trash.dart';
import 'package:nex_gallery/services/vault/vault_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_features_');
  });
  tearDown(() async {
    await workspace.delete(recursive: true);
  });
  String path(String name) => p.join(workspace.path, name);
  test(
    'copy and move preserve content, reject collisions and descendants',
    () async {
      final source = await Directory(path('source')).create();
      await File(p.join(source.path, 'a.txt')).writeAsString('original bytes');
      final files = FileTools();
      await files.copy(source.path, path('copy'));
      expect(await File(path('copy/a.txt')).readAsString(), 'original bytes');
      await expectLater(
        files.copy(source.path, path('copy')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        files.copy(source.path, p.join(source.path, 'nested')),
        throwsA(isA<FileSystemException>()),
      );
      await files.copy(source.path, path('moved'), move: true);
      expect(await source.exists(), isFalse);
      expect(await File(path('moved/a.txt')).readAsString(), 'original bytes');
    },
  );
  test(
    'ZIP round trip preserves nested files and prevents overwrites',
    () async {
      final source = await Directory(path('source/nested'))
          .create(recursive: true);
      await File(p.join(source.path, 'a.txt')).writeAsString('hello ZIP');
      final files = FileTools();
      await files.createZip(path('source'), path('bundle.zip'));
      await files.extractZip(path('bundle.zip'), path('unpacked'));
      expect(
        await File(path('unpacked/source/nested/a.txt')).readAsString(),
        'hello ZIP',
      );
      await expectLater(
        files.extractZip(path('bundle.zip'), path('unpacked')),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        files.createZip(path('source'), path('source/inside.zip')),
        throwsA(isA<FileSystemException>()),
      );
    },
  );
  test('ZIP rejects traversal, absolute paths, links and oversized contents with rollback', () async {
    final files = FileTools();
    for (final name in [
      '../outside.txt',
      '/absolute.txt',
      'C:/escape.txt',
      'a/../../escape',
      'a/CON.txt',
    ]) {
      final archive = Archive()..add(ArchiveFile(name, 3, [1, 2, 3]));
      await File(path('unsafe.zip')).writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        files.extractZip(path('unsafe.zip'), path('output')),
        throwsA(isA<FormatException>()),
      );
      expect(await Directory(path('output')).exists(), isFalse);
    }
    final large = Archive()
      ..add(ArchiveFile('large.txt', 20, List.filled(20, 0)));
    await File(path('large.zip')).writeAsBytes(ZipEncoder().encode(large));
    await expectLater(
      files.extractZip(path('large.zip'), path('output'), maximumBytes: 10),
      throwsA(isA<FormatException>()),
    );
    final link = ArchiveFile('link', 5, utf8.encode('../x'))..mode = 0xa1ff;
    await File(path('link.zip'))
        .writeAsBytes(ZipEncoder().encode(Archive()..add(link)));
    await expectLater(
      files.extractZip(path('link.zip'), path('output')),
      throwsA(isA<FormatException>()),
    );
    expect(await Directory(path('output')).exists(), isFalse);
    expect(
      (await workspace.list().toList()).where(
        (v) => p.basename(v.path).startsWith('.nexgallery-'),
      ),
      isEmpty,
    );
  });
  test('Trash physically moves files, recovers journals and refuses replacement overwrite', () async {
    final source = await File(path('photo.jpg')).writeAsString('original');
    final item = MediaItem(
      id: 'photo',
      name: 'photo.jpg',
      uri: source.uri.toString(),
      relativePath: 'photo.jpg',
      kind: MediaKind.image,
      source: MediaSource.pc,
      metadata: MediaMetadata(
        sizeBytes: 8,
        modifiedAt: (await source.stat()).modified,
      ),
      indexedAt: DateTime.now(),
    );
    final trash = RecoverableTrash();
    final trashed = await trash.put(item);
    expect(await source.exists(), isFalse);
    expect(
      await File.fromUri(Uri.parse(trashed.uri)).readAsString(),
      'original',
    );
    final recovered = await trash.recover(workspace.path).toList();
    expect(recovered.single.uri, trashed.uri);
    expect(recovered.single.section, MediaSection.trash);
    await source.writeAsString('replacement');
    await expectLater(
      trash.restore(trashed),
      throwsA(isA<FileSystemException>()),
    );
    expect(await source.readAsString(), 'replacement');
    await source.delete();
    final restored = await trash.restore(trashed);
    expect(restored.uri, item.uri);
    expect(await source.readAsString(), 'original');
    await trash.finish(trashed);
    expect(
      await File(trashed.metadata.attributes['trash.journal']!).exists(),
      isFalse,
    );
  });
  test('photo editing crops and rotates a new image without modifying source bytes', () {
    final photo = img.Image(width: 4, height: 2);
    img.fill(photo, color: img.ColorRgb8(200, 40, 30));
    final original = Uint8List.fromList(img.encodePng(photo));
    final saved = Uint8List.fromList(original);
    final edited = editImage(
      original,
      const ImageEdit(quarterTurns: 1, left: 0, top: 0, right: 0.5, bottom: 1),
    );
    final decoded = img.decodePng(edited)!;
    expect((decoded.width, decoded.height), (2, 2));
    expect(original, saved);
    expect(img.decodePng(original)!.width, 4);
  });
  test('vault authenticates passwords and chunks, hides names and cleans failed exports', () async {
    final vault = VaultStore(Directory(path('vault')), iterations: 100000);
    const password = 'correct horse battery';
    await vault.unlock(password, create: true);
    final bytes = Uint8List.fromList(
      List.generate(VaultStore.chunkBytes + 17, (i) => i % 251),
    );
    final source = await File(path('original')).writeAsBytes(bytes);
    await vault.add(source, 'private-photo.jpg');
    final entry = vault.entries.single;
    expect(
      await File(path('vault/vault.json')).readAsString(),
      isNot(contains('private-photo.jpg')),
    );
    final exported = await vault.decrypt(entry, File(path('export')));
    expect(await exported.readAsBytes(), bytes);
    vault.lock();
    expect(vault.entries, isEmpty);
    await expectLater(vault.unlock('wrong password'), throwsA(anything));
    expect(vault.unlocked, isFalse);
    await vault.unlock(password);
    expect(vault.entries.single.name, 'private-photo.jpg');
    final payload = File(path('vault/${entry.id}.vault'));
    final valid = await payload.readAsBytes();
    final damaged = Uint8List.fromList(valid)..[20] ^= 1;
    await payload.writeAsBytes(damaged);
    await expectLater(
      vault.decrypt(entry, File(path('bad-export'))),
      throwsA(anything),
    );
    expect(await File(path('bad-export')).exists(), isFalse);
    expect(await File(path('bad-export.part')).exists(), isFalse);
    await payload.writeAsBytes(valid.sublist(0, valid.length - 5));
    await expectLater(
      vault.decrypt(entry, File(path('truncated'))),
      throwsA(isA<FormatException>()),
    );
    await payload.writeAsBytes(valid);
    await expectLater(
      vault.add(File(path('missing')), 'missing.jpg'),
      throwsA(isA<FileSystemException>()),
    );
    final retry = await vault.decrypt(entry, File(path('retry')));
    expect(await retry.length(), bytes.length);
    final manifest = File(path('vault/vault.json'));
    await manifest.rename('${manifest.path}.previous');
    vault.lock();
    expect(await vault.exists(), isTrue);
    await vault.unlock(password);
    await vault.remove(vault.entries.single);
    expect(await payload.exists(), isFalse);
    vault.lock();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
