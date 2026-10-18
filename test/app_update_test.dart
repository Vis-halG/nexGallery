import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/core/gallery_settings.dart';
import 'package:nex_gallery/services/remote/sha256.dart';
import 'package:nex_gallery/services/updates/app_update.dart';
import 'package:path/path.dart' as p;

Map<String, Object?> _asset(String url, List<int> bytes) => {
  'url': url,
  'sha256': sha256Hex(bytes),
  'size': bytes.length,
};

void main() {
  test('manifests accept only this repository\'s release files', () {
    const base =
        'https://github.com/Vis-halG/nexGallery/releases/download/build-7/';
    final apk = utf8.encode('apk');
    final release = UpdateRelease.fromJson({
      'schema': 1,
      'version': '0.1.0',
      'build': 7,
      'notes': '- Sharper photos',
      'android': {
        'arm64-v8a': _asset(
          '${base}nexGallery-0.1.0-build7-arm64-v8a.apk',
          apk,
        ),
        'armeabi-v7a': _asset(
          '${base}nexGallery-0.1.0-build7-armeabi-v7a.apk',
          apk,
        ),
      },
      'windows': {'x64': _asset('${base}nexGallery-0.1.0.7-setup.exe', apk)},
    });
    expect(release.label, '0.1.0 (build 7)');
    expect(
      release
          .assetFor(android: true, abis: ['arm64-v8a', 'armeabi-v7a'])!
          .fileName,
      'nexGallery-0.1.0-build7-arm64-v8a.apk',
    );
    expect(
      release.assetFor(android: true, abis: ['armeabi-v7a'])!.fileName,
      endsWith('armeabi-v7a.apk'),
    );
    expect(release.assetFor(android: true, abis: ['x86_64']), isNull);
    expect(release.assetFor(android: false)!.fileName, endsWith('setup.exe'));

    for (final bad in [
      {'url': 'https://example.com/evil.apk', 'sha256': 'a' * 64, 'size': 1},
      {'url': '${base}ok.apk', 'sha256': 'not-a-hash', 'size': 1},
      {'url': '${base}ok.apk', 'sha256': 'a' * 64, 'size': 0},
      // Climbs out of this repository's releases once resolved.
      {
        'url': '$base../../../../evil/repo/releases/download/x/evil.apk',
        'sha256': 'a' * 64,
        'size': 1,
      },
      {'url': '${base}ok.apk?x=1', 'sha256': 'a' * 64, 'size': 1},
    ]) {
      expect(
        () => UpdateRelease.fromJson({
          'schema': 1,
          'build': 8,
          'android': {'arm64-v8a': bad},
        }),
        throwsFormatException,
        reason: '$bad',
      );
    }
    expect(
      () => UpdateRelease.fromJson({'schema': 2, 'build': 8}),
      throwsFormatException,
    );
  });

  test('automatic checks are on by default and remembered', () {
    expect(const GallerySettings().checkForUpdates, isTrue);
    final off = GallerySettings.fromJson(
      const GallerySettings(checkForUpdates: false).toJson(),
    );
    expect(off.checkForUpdates, isFalse);
    expect(GallerySettings.fromJson(const {}).checkForUpdates, isTrue);
  });

  group('AppUpdater', () {
    late Directory workspace;
    late HttpServer server;
    late String prefix;
    var manifest = <String, Object?>{};
    var files = <String, List<int>>{};
    var manifestStatus = 200;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('nex_updates_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      prefix = 'http://127.0.0.1:${server.port}/releases/';
      manifestStatus = 200;
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/update.json') {
          request.response.statusCode = manifestStatus;
          request.response.write(jsonEncode(manifest));
        } else if (files[path] case final bytes?) {
          request.response.add(bytes);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });
    tearDown(() async {
      await server.close(force: true);
      await workspace.delete(recursive: true);
    });

    AppUpdater updater({required int current, List<File>? installed}) =>
        AppUpdater(
          isAndroid: true,
          abis: const ['arm64-v8a'],
          currentBuild: current,
          downloads: Directory(p.join(workspace.path, 'updates')),
          manifest: Uri.parse('http://127.0.0.1:${server.port}/update.json'),
          allowedPrefix: prefix,
          installer: (file) async => installed?.add(file),
        );

    void publish(int build, List<int> apk, {List<int>? served}) {
      final name = 'nexGallery-0.1.0-build$build-arm64-v8a.apk';
      files = {'/releases/$name': served ?? apk};
      manifest = {
        'schema': 1,
        'version': '0.1.0',
        'build': build,
        'notes': '- Sharper photos',
        'android': {'arm64-v8a': _asset('$prefix$name', apk)},
      };
    }

    test('downloads a newer build, verifies it and installs it', () async {
      final apk = List<int>.generate(300000, (i) => i % 251);
      publish(9, apk);
      final installed = <File>[];
      final app = updater(current: 7, installed: installed);
      expect(await app.check(), isTrue);
      expect(app.status, UpdateStatus.available);
      expect(app.offering, isTrue);
      expect(app.release!.label, '0.1.0 (build 9)');

      await app.download();
      expect(app.status, UpdateStatus.ready);
      expect(app.progress, 1);
      await app.install();
      expect(installed.single.readAsBytesSync(), apk);

      // A verified download is reused after a restart.
      final again = updater(current: 7);
      await again.check();
      expect(again.status, UpdateStatus.ready);
    });

    test('a download that does not match the checksum is deleted', () async {
      publish(9, utf8.encode('real apk'), served: utf8.encode('evil apk'));
      final installed = <File>[];
      final app = updater(current: 7, installed: installed);
      await app.check();
      await app.download();
      expect(app.status, UpdateStatus.failed);
      expect(app.error, contains('checksum'));
      expect(app.offering, isTrue, reason: 'the banner offers a retry');
      await app.install();
      expect(installed, isEmpty);
      final left = Directory(p.join(workspace.path, 'updates')).listSync();
      expect(left, isEmpty);
    });

    test('the installed or an older build is not offered', () async {
      publish(7, utf8.encode('apk'));
      final app = updater(current: 7);
      expect(await app.check(), isFalse);
      expect(app.status, UpdateStatus.upToDate);
      expect(app.offering, isFalse);

      manifestStatus = 404;
      expect(await app.check(), isFalse);
      expect(app.status, UpdateStatus.upToDate, reason: 'no release yet');
    });

    test('Later hides the banner until a newer build appears', () async {
      publish(8, utf8.encode('apk'));
      final app = updater(current: 7);
      await app.check();
      app.dismiss();
      expect(app.offering, isFalse);
      await app.check();
      expect(app.offering, isFalse);
      publish(9, utf8.encode('apk'));
      await app.check();
      expect(app.offering, isTrue);
    });
  });
}
