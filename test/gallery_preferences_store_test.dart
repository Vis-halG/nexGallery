import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/data/gallery_preferences_store.dart';

void main() {
  late Directory directory;
  late GalleryPreferencesStore store;
  late File target;
  late File backup;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'nexgallery_preferences_',
    );
    store = GalleryPreferencesStore(directory.path);
    target = File('${directory.path}${Platform.pathSeparator}settings.json');
    backup = File('${target.path}.bak');
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'new store returns default settings and empty organization state',
    () async {
      final preferences = await store.load();
      expect(preferences.settings.toJson(), const GallerySettings().toJson());
      expect(preferences.roots, isEmpty);
      expect(preferences.videoPositions, isEmpty);
    },
  );

  test(
    'settings roots and video positions round-trip across sessions',
    () async {
      final value = _preferences();
      await store.save(value);
      await store.close();
      final reopened = GalleryPreferencesStore(directory.path);
      try {
        expect((await reopened.load()).toJson(), value.toJson());
      } finally {
        await reopened.close();
      }
    },
  );

  test(
    'preferences copy caller collections before queued persistence',
    () async {
      final roots = <String>['C:\\Pictures'];
      final positions = <String, int>{'clip:1': 123};
      final value = GalleryPreferences(roots: roots, videoPositions: positions);
      roots.clear();
      positions.clear();
      await store.save(value);
      final restored = await store.load();
      expect(restored.roots, <String>['C:\\Pictures']);
      expect(restored.videoPositions, <String, int>{'clip:1': 123});
    },
  );

  test('legacy roots.txt imports trimmed roots and is preserved', () async {
    final legacy = File('${directory.path}${Platform.pathSeparator}roots.txt');
    const original = '  C:\\Pictures  \n\nD:\\Family\n';
    await legacy.writeAsString(original);
    final imported = await store.load();
    expect(imported.roots, <String>['C:\\Pictures', 'D:\\Family']);
    expect(imported.settings.toJson(), const GallerySettings().toJson());
    await store.save(imported);
    await legacy.writeAsString('E:\\New root');
    expect((await store.load()).roots, imported.roots);
    expect(await legacy.readAsString(), 'E:\\New root');
  });

  test(
    'future primary schema remains untouched even with valid old backup',
    () async {
      final future = _preferences().toJson()..['schemaVersion'] = 999;
      final source = jsonEncode(future);
      final backupSource = jsonEncode(_preferences().toJson());
      await target.writeAsString(source);
      await backup.writeAsString(backupSource);
      await expectLater(store.load(), throwsUnsupportedError);
      await expectLater(store.save(GalleryPreferences()), throwsStateError);
      expect(await target.readAsString(), source);
      expect(await backup.readAsString(), backupSource);
    },
  );

  test('future primary is protected when save is called before load', () async {
    final future = _preferences().toJson()..['schemaVersion'] = 999;
    final source = jsonEncode(future);
    await target.writeAsString(source);
    await expectLater(
      store.save(GalleryPreferences()),
      throwsA(anyOf(isA<StateError>(), isA<UnsupportedError>())),
    );
    expect(await target.readAsString(), source);
  });

  test('corrupt primary restores a valid backup before later writes', () async {
    const corrupt = '{incomplete settings';
    final source = jsonEncode(_preferences().toJson());
    await target.writeAsString(corrupt);
    await backup.writeAsString(source);
    expect((await store.load()).toJson(), _preferences().toJson());
    expect(jsonDecode(await target.readAsString()), _preferences().toJson());
    expect(await backup.readAsString(), source);
    expect(store.recoveredSettingsPath, isNotNull);
    expect(await File(store.recoveredSettingsPath!).readAsString(), corrupt);
    final next = GalleryPreferences(roots: <String>['E:\\Next']);
    await store.save(next);
    expect((await store.load()).toJson(), next.toJson());
    expect(jsonDecode(await backup.readAsString()), _preferences().toJson());
  });

  test('missing primary restores a valid crash backup', () async {
    final source = jsonEncode(_preferences().toJson());
    await backup.writeAsString(source);
    expect((await store.load()).toJson(), _preferences().toJson());
    expect(await target.exists(), isTrue);
    expect(jsonDecode(await target.readAsString()), _preferences().toJson());
  });

  test(
    'corrupt settings without valid backup block overwriting defaults',
    () async {
      const corrupt = '{incomplete settings';
      await target.writeAsString(corrupt);
      await expectLater(store.load(), throwsFormatException);
      await expectLater(store.save(GalleryPreferences()), throwsStateError);
      expect(await target.readAsString(), corrupt);
    },
  );

  test(
    'queued writes preserve order and close drains every authorized write',
    () async {
      final first = store.save(
        GalleryPreferences(roots: <String>['C:\\First']),
      );
      final second = store.save(_preferences());
      final closing = store.close();
      await Future.wait(<Future<void>>[first, second, closing]);
      final reopened = GalleryPreferencesStore(directory.path);
      try {
        expect((await reopened.load()).toJson(), _preferences().toJson());
        expect(
          (jsonDecode(await backup.readAsString()) as Map)['roots'],
          <String>['C:\\First'],
        );
        await expectLater(store.save(GalleryPreferences()), throwsStateError);
      } finally {
        await reopened.close();
      }
    },
  );

  test('load waits for earlier queued saves', () async {
    final saving = store.save(_preferences());
    final reading = store.load();
    expect((await reading).toJson(), _preferences().toJson());
    await saving;
  });

  for (final malformed in <Map<String, Object?>>[
    <String, Object?>{
      'roots': <Object?>['C:\\Pictures', 7],
    },
    <String, Object?>{
      'roots': <String, String>{'folder': 'C:\\Pictures'},
    },
    <String, Object?>{
      'settings': <String, Object?>{'autoRefresh': 'yes'},
    },
    <String, Object?>{
      'videoPositions': <String, Object?>{'clip': -1},
    },
    <String, Object?>{
      'videoPositions': <String, Object?>{'clip': '120'},
    },
  ]) {
    test(
      'malformed ${malformed.keys.single} recovers valid settings backup',
      () async {
        final object = _preferences().toJson()..addAll(malformed);
        await target.writeAsString(jsonEncode(object));
        await backup.writeAsString(jsonEncode(_preferences().toJson()));
        expect((await store.load()).toJson(), _preferences().toJson());
        expect(
          jsonDecode(await target.readAsString()),
          _preferences().toJson(),
        );
        expect(store.recoveredSettingsPath, isNotNull);
      },
    );
  }

  test('malformed containers without backup block data replacement', () async {
    final object = _preferences().toJson()..['roots'] = 7;
    final source = jsonEncode(object);
    await target.writeAsString(source);
    await expectLater(store.load(), throwsFormatException);
    await expectLater(store.save(GalleryPreferences()), throwsStateError);
    expect(await target.readAsString(), source);
  });

  test(
    'successful explicit reload after repair clears write protection',
    () async {
      await target.writeAsString('{corrupt settings');
      await expectLater(store.load(), throwsFormatException);
      await target.writeAsString(jsonEncode(_preferences().toJson()));
      expect((await store.load()).toJson(), _preferences().toJson());
      final next = GalleryPreferences(roots: const <String>['F:\\Repaired']);
      await store.save(next);
      expect((await store.load()).toJson(), next.toJson());
    },
  );

  test(
    'oversized new settings cannot replace an existing valid primary',
    () async {
      await store.save(_preferences());
      final source = await target.readAsString();
      await expectLater(
        store.save(GalleryPreferences(roots: <String>['X' * (1 << 20)])),
        throwsFormatException,
      );
      expect(await target.readAsString(), source);
      expect((await store.load()).toJson(), _preferences().toJson());
    },
  );
}

GalleryPreferences _preferences() => GalleryPreferences(
  settings: const GallerySettings(
    appearance: GalleryAppearance.dark,
    autoRefresh: false,
    includeHiddenFiles: true,
  ),
  roots: const <String>['C:\\Pictures', 'D:\\Family'],
  videoPositions: const <String, int>{'clip:123': 45678, 'movie:234': 0},
);
