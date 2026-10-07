import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/remote/nex_gallery_server.dart';

enum DesktopServerState { stopped, starting, running, error }

final class DesktopServerController extends ChangeNotifier {
  NexGalleryServer? _server;
  DesktopServerState _state = DesktopServerState.stopped;
  PairingCode? _pairingCode;
  String? _error;
  List<String> _sharedPaths = const <String>[];
  bool _listenOnLan = false;
  List<String> _urls = const <String>[];

  DesktopServerState get state => _state;
  PairingCode? get pairingCode => _pairingCode;
  String? get error => _error;
  List<String> get sharedPaths => _sharedPaths;
  bool get listenOnLan => _listenOnLan;
  List<String> get urls => _urls;
  bool get isRunning => _state == DesktopServerState.running;

  Future<void> start({
    required List<String> sharedPaths,
    required bool listenOnLan,
  }) async {
    if (_state == DesktopServerState.starting) return;
    final folders = <Directory>[];
    for (final value in sharedPaths) {
      final path = value.trim();
      if (path.isEmpty) continue;
      final folder = Directory(path);
      if (!await folder.exists()) {
        _fail('Shared folder does not exist: $path');
        return;
      }
      if (!folders.any(
        (existing) =>
            existing.absolute.path.toLowerCase() ==
            folder.absolute.path.toLowerCase(),
      )) {
        folders.add(folder);
      }
    }
    if (folders.isEmpty) {
      _fail('Add at least one existing folder.');
      return;
    }
    await stop();
    _state = DesktopServerState.starting;
    _error = null;
    _sharedPaths = List<String>.unmodifiable(
      folders.map((folder) => folder.absolute.path),
    );
    _listenOnLan = listenOnLan;
    notifyListeners();
    try {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      final dataDirectory = Directory(
        '$localAppData${Platform.pathSeparator}nexGallery'
        '${Platform.pathSeparator}server',
      );
      final server = await NexGalleryServer.create(
        RemoteServerConfig(
          allowedRoots: <String, String>{
            for (var index = 0; index < folders.length; index += 1)
              'shared_${index + 1}': folders[index].absolute.path,
          },
          dataDirectory: dataDirectory,
          port: 8732,
          listenOnLan: listenOnLan,
        ),
      );
      await server.start();
      _server = server;
      _pairingCode = server.createPairingCode();
      _urls = await _resolveUrls(server.boundPort!, listenOnLan);
      _state = DesktopServerState.running;
      notifyListeners();
    } catch (error) {
      _fail(error.toString());
    }
  }

  void createPairingCode() {
    final server = _server;
    if (server == null) return;
    _pairingCode = server.createPairingCode();
    notifyListeners();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _pairingCode = null;
    _urls = const <String>[];
    if (server != null) await server.stop();
    if (_state != DesktopServerState.error) {
      _state = DesktopServerState.stopped;
    }
    notifyListeners();
  }

  void _fail(String message) {
    _error = message.replaceFirst('SocketException: ', '');
    _state = DesktopServerState.error;
    notifyListeners();
  }

  @override
  void dispose() {
    final server = _server;
    _server = null;
    if (server != null) unawaited(server.stop(force: true));
    super.dispose();
  }
}

Future<List<String>> _resolveUrls(int port, bool lan) async {
  if (!lan) return <String>['http://127.0.0.1:$port'];
  final urls = <String>[];
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  )) {
    for (final address in interface.addresses) {
      urls.add('http://${address.address}:$port');
    }
  }
  return urls.isEmpty
      ? <String>['http://<PC-LAN-IP>:$port']
      : urls.toSet().toList(growable: false);
}
