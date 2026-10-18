import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../remote/sha256.dart';

/// Set by the release workflow (`--dart-define=NEXGALLERY_BUILD=<run>`); 0 in
/// local builds.
const appBuild = int.fromEnvironment('NEXGALLERY_BUILD');
const appVersion = String.fromEnvironment(
  'NEXGALLERY_VERSION',
  defaultValue: '0.1.0',
);

/// Only builds published by the release workflow update themselves; Play
/// builds and local builds never contact GitHub.
const updatesEnabled = bool.fromEnvironment('NEXGALLERY_UPDATES');

/// The newest release's manifest. GitHub redirects `latest` to it.
final updateManifestUri = Uri.parse(
  'https://github.com/Vis-halG/nexGallery/releases/latest/download/update.json',
);

/// Release files must come from this repository's releases.
const releasePrefix =
    'https://github.com/Vis-halG/nexGallery/releases/download/';

final class UpdateAsset {
  const UpdateAsset({
    required this.url,
    required this.sha256,
    required this.size,
    required this.fileName,
  });

  factory UpdateAsset.fromJson(
    Map<String, dynamic> json, {
    String prefix = releasePrefix,
  }) {
    final url = json['url'];
    final hash = json['sha256'];
    final size = json['size'];
    if (url is! String ||
        !url.startsWith(prefix) ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        size is! int ||
        size <= 0) {
      throw const FormatException('The update manifest is invalid.');
    }
    // Parsing resolves `..`, so the prefix is checked again on the result:
    // a path that climbs out of this repository's releases is refused.
    final uri = Uri.parse(url);
    final normalized = uri.toString();
    final rest = normalized.startsWith(prefix)
        ? normalized.substring(prefix.length).split('/')
        : const <String>[];
    if (rest.isEmpty ||
        rest.length > 2 ||
        rest.any((part) => part.isEmpty) ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('The update URL is invalid.');
    }
    final name = uri.pathSegments.last;
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
      throw const FormatException('The update file name is invalid.');
    }
    return UpdateAsset(url: url, sha256: hash, size: size, fileName: name);
  }

  final String url;
  final String sha256;
  final int size;
  final String fileName;
}

/// One published build, from `update.json`.
final class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.build,
    required this.notes,
    required this.android,
    required this.windows,
  });

  factory UpdateRelease.fromJson(
    Map<String, dynamic> json, {
    String prefix = releasePrefix,
  }) {
    if (json['schema'] != 1 || json['build'] is! int) {
      throw const FormatException('Unsupported update manifest.');
    }
    Map<String, UpdateAsset> assets(Object? value) => {
      if (value is Map)
        for (final entry in value.entries)
          '${entry.key}': UpdateAsset.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
            prefix: prefix,
          ),
    };
    return UpdateRelease(
      version: json['version'] as String? ?? '',
      build: json['build'] as int,
      notes: json['notes'] as String? ?? '',
      android: assets(json['android']),
      windows: assets(json['windows']),
    );
  }

  final String version;
  final int build;
  final String notes;

  /// By Android ABI, for example `arm64-v8a`.
  final Map<String, UpdateAsset> android;

  /// By architecture, `x64`.
  final Map<String, UpdateAsset> windows;

  String get label => '$version (build $build)';

  /// The file for this device, or null when this release has none.
  UpdateAsset? assetFor({required bool android, List<String> abis = const []}) {
    if (!android) return windows['x64'];
    for (final abi in abis) {
      final asset = this.android[abi];
      if (asset != null) return asset;
    }
    return null;
  }
}

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  ready,
  installing,
  failed,
}

/// Hands a verified download to the platform installer.
typedef UpdateInstaller = Future<void> Function(File file);

/// Checks GitHub for a newer build, downloads it, verifies its SHA-256 and
/// starts the platform installer.
final class AppUpdater extends ChangeNotifier {
  /// The app's updater, when this build updates itself.
  static AppUpdater? instance;

  AppUpdater({
    required this.isAndroid,
    required this.installer,
    required this.downloads,
    this.currentBuild = appBuild,
    this.abis = const [],
    Uri? manifest,
    this.allowedPrefix = releasePrefix,
    HttpClient Function()? httpClient,
  }) : manifest = manifest ?? updateManifestUri,
       _httpClient = httpClient ?? HttpClient.new;

  final bool isAndroid;
  final UpdateInstaller installer;

  /// Where update files are kept until installed.
  final Directory downloads;
  final int currentBuild;
  final List<String> abis;
  final Uri manifest;

  /// Update files are accepted only from URLs starting with this.
  final String allowedPrefix;
  final HttpClient Function() _httpClient;

  UpdateStatus _status = UpdateStatus.idle;
  UpdateRelease? _release;
  UpdateAsset? _asset;
  File? _file;
  double _progress = 0;
  String? _error;
  bool _dismissed = false;

  UpdateStatus get status => _status;
  UpdateRelease? get release => _release;
  double get progress => _progress;
  String? get error => _error;

  /// True when the banner should be shown.
  bool get offering =>
      !_dismissed &&
      (_status == UpdateStatus.available ||
          (_status == UpdateStatus.failed && _asset != null) ||
          _status == UpdateStatus.downloading ||
          _status == UpdateStatus.ready ||
          _status == UpdateStatus.installing);

  void dismiss() {
    _dismissed = true;
    notifyListeners();
  }

  void _set(UpdateStatus status, {String? error}) {
    _status = status;
    _error = error;
    notifyListeners();
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = _httpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode == HttpStatus.notFound) {
        await response.drain<void>();
        throw const _NoRelease();
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('GitHub answered ${response.statusCode}.');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
        if (bytes.length > 256 * 1024) {
          throw const FormatException('The update manifest is too large.');
        }
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) {
        throw const FormatException('The update manifest is invalid.');
      }
      return value;
    } finally {
      client.close(force: true);
    }
  }

  /// Returns true when a newer build for this device is available.
  Future<bool> check() async {
    if (_status == UpdateStatus.checking ||
        _status == UpdateStatus.downloading ||
        _status == UpdateStatus.installing) {
      return _status != UpdateStatus.checking;
    }
    _set(UpdateStatus.checking);
    try {
      final release = UpdateRelease.fromJson(
        await _getJson(manifest),
        prefix: allowedPrefix,
      );
      final asset = release.assetFor(android: isAndroid, abis: abis);
      if (release.build <= currentBuild || asset == null) {
        _release = release;
        _set(UpdateStatus.upToDate);
        return false;
      }
      final changed = _release?.build != release.build;
      _release = release;
      _asset = asset;
      if (changed) _dismissed = false;
      final cached = File('${downloads.path}/${asset.fileName}');
      if (await cached.exists() &&
          await cached.length() == asset.size &&
          await Sha256.fileHex(cached) == asset.sha256) {
        _file = cached;
        _progress = 1;
        _set(UpdateStatus.ready);
      } else {
        _set(UpdateStatus.available);
      }
      return true;
    } on _NoRelease {
      _set(UpdateStatus.upToDate);
      return false;
    } on Object catch (error) {
      _set(UpdateStatus.failed, error: _message(error));
      return false;
    }
  }

  /// Downloads the update and checks its size and SHA-256 before it can be
  /// installed. A file that fails the check is deleted.
  Future<void> download() async {
    final asset = _asset;
    if (asset == null || _status == UpdateStatus.downloading) return;
    _progress = 0;
    _set(UpdateStatus.downloading);
    await downloads.create(recursive: true);
    final target = File('${downloads.path}/${asset.fileName}');
    final part = File('${target.path}.part');
    final client = _httpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      request.followRedirects = true;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('GitHub answered ${response.statusCode}.');
      }
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > asset.size) {
            throw const FormatException(
              'The download is larger than expected.',
            );
          }
          sink.add(chunk);
          _progress = received / asset.size;
          notifyListeners();
        }
      } finally {
        await sink.close();
      }
      if (received != asset.size ||
          await Sha256.fileHex(part) != asset.sha256) {
        throw const FormatException(
          'The download did not match the published checksum.',
        );
      }
      if (await target.exists()) await target.delete();
      _file = await part.rename(target.path);
      _progress = 1;
      _set(UpdateStatus.ready);
    } on Object catch (error) {
      if (await part.exists()) await part.delete();
      _set(UpdateStatus.failed, error: _message(error));
    } finally {
      client.close(force: true);
    }
  }

  /// Starts the installer for a verified download.
  Future<void> install() async {
    final file = _file;
    if (file == null || _status != UpdateStatus.ready) return;
    _set(UpdateStatus.installing);
    try {
      await installer(file);
      // Android returns after showing its installer; the app restarts when
      // the update is installed.
      _set(UpdateStatus.ready);
    } on Object catch (error) {
      _set(UpdateStatus.failed, error: _message(error));
    }
  }

  /// Deletes downloads of builds that are already installed.
  Future<void> cleanUp() async {
    if (!await downloads.exists()) return;
    await for (final entity in downloads.list()) {
      if (entity is File && entity.path != _file?.path) {
        try {
          await entity.delete();
        } on FileSystemException {
          // A file in use is removed next time.
        }
      }
    }
  }

  static String _message(Object error) => switch (error) {
    SocketException() => 'No connection to GitHub.',
    TimeoutException() => 'GitHub did not respond.',
    HttpException(:final message) => message,
    FormatException(:final message) => message,
    _ => '$error',
  };
}

final class _NoRelease implements Exception {
  const _NoRelease();
}

/// Runs the Inno Setup installer silently over this per-user installation
/// and closes the app; the installer starts nexGallery again when it is done.
Future<void> runWindowsInstaller(File installer) async {
  await Process.start(installer.path, const [
    '/SILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/CLOSEAPPLICATIONS',
  ], mode: ProcessStartMode.detached);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(0);
}
