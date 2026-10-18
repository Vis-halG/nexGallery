import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/remote/agent_config.dart';
import '../services/remote/nex_gallery_server.dart';
import '../services/remote/network_modes.dart';
import '../services/remote/owner_client.dart';
import '../services/remote/pairing_payload.dart';
import '../services/remote/security.dart';
import '../services/remote/tailscale.dart';
import '../services/remote/tls_identity.dart';
import '../services/remote/upload_quarantine.dart';
import 'agent_manager.dart';

export '../services/remote/network_modes.dart' show ServerNetworkMode;

enum DesktopServerState { stopped, starting, running, error }

/// The server the UI manages: in this app's process, or the background agent.
abstract interface class _ServerHandle {
  Stream<void> get changes;
  Future<List<PairingRequest>> pending();
  Future<List<DeviceIdentity>> devices();
  Future<PairingCode> newCode();
  Future<void> approve(String id, Set<String> scopes, List<String>? roots);
  Future<void> deny(String id);
  Future<void> revoke(String tokenId);
  Future<void> updatePermissions(
    String tokenId,
    Set<String> scopes,
    List<String>? roots,
  );
  Future<List<Map<String, Object?>>> audit(int limit);
  Future<List<QuarantinedUpload>> quarantined();
  Future<String> release(String root, String id);
  Future<void> discard(String root, String id);
  Future<void> stop();
}

final class _InProcess implements _ServerHandle {
  _InProcess(this.server);
  final NexGalleryServer server;

  @override
  Stream<void> get changes => server.events;
  @override
  Future<List<PairingRequest>> pending() async => [
    for (final pending in server.pendingPairings) pending.request,
  ];
  @override
  Future<List<DeviceIdentity>> devices() async => server.devices;
  @override
  Future<PairingCode> newCode() async => server.createPairingCode();
  @override
  Future<void> approve(String id, Set<String> scopes, List<String>? roots) =>
      server.approvePairing(id, scopes: scopes, roots: roots);
  @override
  Future<void> deny(String id) => server.denyPairing(id);
  @override
  Future<void> revoke(String tokenId) => server.revokeDevice(tokenId);
  @override
  Future<void> updatePermissions(
    String tokenId,
    Set<String> scopes,
    List<String>? roots,
  ) => server.updateDevicePermissions(tokenId, scopes: scopes, roots: roots);
  @override
  Future<List<Map<String, Object?>>> audit(int limit) =>
      server.readAudit(limit: limit);
  @override
  Future<List<QuarantinedUpload>> quarantined() => server.quarantined();
  @override
  Future<String> release(String root, String id) =>
      server.releaseQuarantined(root, id);
  @override
  Future<void> discard(String root, String id) =>
      server.deleteQuarantined(root, id);
  // Stopping is immediate; phones resume interrupted transfers later.
  @override
  Future<void> stop() => server.stop(force: true);
}

final class _Agent implements _ServerHandle {
  _Agent(this.client);
  final OwnerClient client;

  // The agent is another process; its state is polled.
  @override
  Stream<void> get changes => Stream<void>.periodic(const Duration(seconds: 3));
  @override
  Future<List<PairingRequest>> pending() => client.pendingPairings();
  @override
  Future<List<DeviceIdentity>> devices() => client.devices();
  @override
  Future<PairingCode> newCode() => client.createPairingCode();
  @override
  Future<void> approve(String id, Set<String> scopes, List<String>? roots) =>
      client.approve(id, scopes: scopes, roots: roots);
  @override
  Future<void> deny(String id) => client.deny(id);
  @override
  Future<void> revoke(String tokenId) => client.revoke(tokenId);
  @override
  Future<void> updatePermissions(
    String tokenId,
    Set<String> scopes,
    List<String>? roots,
  ) => client.updatePermissions(tokenId, scopes: scopes, roots: roots);
  @override
  Future<List<Map<String, Object?>>> audit(int limit) =>
      client.audit(limit: limit);
  @override
  Future<List<QuarantinedUpload>> quarantined() => client.quarantined();
  @override
  Future<String> release(String root, String id) =>
      client.releaseQuarantined(root, id);
  @override
  Future<void> discard(String root, String id) =>
      client.deleteQuarantined(root, id);
  @override
  Future<void> stop() async {
    try {
      await client.shutdown();
    } finally {
      client.close();
    }
  }
}

final class DesktopServerController extends ChangeNotifier {
  DesktopServerController({
    Directory? dataDirectory,
    Future<TailscaleStatus> Function()? tailscaleReader,
    AgentManager? agentManager,
    this.port = 8732,
  }) : _dataDirectory = dataDirectory ?? _defaultDirectory(),
       _readTailscale = tailscaleReader ?? readTailscaleStatus,
       _agents = agentManager ?? AgentManager();

  final Directory _dataDirectory;
  final Future<TailscaleStatus> Function() _readTailscale;
  final AgentManager _agents;
  final int port;
  _ServerHandle? _handle;
  StreamSubscription<void>? _changes;
  DesktopServerState _state = DesktopServerState.stopped;
  PairingCode? _pairingCode;
  String? _error;
  List<String> _sharedPaths = const <String>[];
  ServerNetworkMode _mode = ServerNetworkMode.thisPc;
  bool _allowWrites = false;
  bool _autoStart = false;
  bool _keepAwake = false;
  bool _background = false;
  bool _agentAvailable = false;
  List<String> _urls = const <String>[];
  List<PairingRequest> _pending = const [];
  List<DeviceIdentity> _devices = const [];
  List<QuarantinedUpload> _quarantined = const [];
  TailscaleStatus? _tailscale;
  String? fingerprint;

  DesktopServerState get state => _state;
  PairingCode? get pairingCode => _pairingCode;
  String? get error => _error;
  List<String> get sharedPaths => _sharedPaths;
  bool get listenOnLan => _mode == ServerNetworkMode.lan;
  ServerNetworkMode get mode => _mode;
  bool get allowWrites => _allowWrites;
  bool get autoStart => _autoStart;

  /// "Keep PC available": Windows does not sleep while the server runs.
  bool get keepAwake => _keepAwake;
  List<String> get urls => _urls;
  bool get isRunning => _state == DesktopServerState.running;
  List<PairingRequest> get pendingPairings => _pending;
  List<DeviceIdentity> get devices => _devices;

  /// Uploads waiting for a security check or the owner's decision.
  List<QuarantinedUpload> get quarantined => _quarantined;
  TailscaleStatus? get tailscale => _tailscale;
  Directory get dataDirectory => _dataDirectory;

  /// The server keeps running after the app closes and starts at sign-in.
  bool get runsInBackground => _background;

  /// Whether the background agent is installed next to the app.
  bool get agentAvailable => _agentAvailable;

  /// Root ids in the order of [sharedPaths], as phones see them.
  Map<String, String> get roots => <String, String>{
    for (var index = 0; index < _sharedPaths.length; index++)
      'shared_${index + 1}': _sharedPaths[index],
  };

  /// The link encoded in the pairing QR code.
  String? get pairingLink {
    final code = _pairingCode, print = fingerprint;
    if (!isRunning || code == null || print == null) return null;
    final addresses = [
      for (final url in _urls)
        if (Uri.tryParse(url) case final uri? when !uri.host.contains('<')) uri,
    ];
    if (addresses.isEmpty) return null;
    return PairingPayload(
      name: Platform.localHostname,
      addresses: addresses,
      code: code.code,
      fingerprint: print,
    ).encode();
  }

  File get _preferences =>
      File('${_dataDirectory.path}${Platform.pathSeparator}desktop.json');

  /// Restores the folders and options chosen last time. A running background
  /// agent is adopted; otherwise the server starts when the owner asked.
  Future<void> load() async {
    try {
      if (await _preferences.exists()) {
        final value = jsonDecode(
          await _preferences.readAsString(),
        ) as Map<String, dynamic>;
        _sharedPaths = List.unmodifiable(
          (value['folders'] as List? ?? const []).whereType<String>(),
        );
        _mode = ServerNetworkMode.values.firstWhere(
          (mode) => mode.name == value['mode'],
          orElse: () => ServerNetworkMode.thisPc,
        );
        _allowWrites = value['allowWrites'] == true;
        _autoStart = value['autoStart'] == true;
        _keepAwake = value['keepAwake'] == true;
      }
    } on FormatException {
      // A damaged preferences file falls back to defaults.
    }
    _agentAvailable =
        Platform.isWindows && await _agents.findExecutable() != null;
    notifyListeners();
    if (_agentAvailable && await _agents.isRegistered()) {
      if (await _adoptAgent(launchIfStopped: true)) return;
    }
    if (_autoStart && _sharedPaths.isNotEmpty) {
      await start(
        sharedPaths: _sharedPaths,
        mode: _mode,
        allowWrites: _allowWrites,
      );
    }
  }

  Future<void> setAutoStart(bool value) async {
    _autoStart = value;
    notifyListeners();
    await _savePreferences();
  }

  /// Applies at once by restarting a running server; phones reconnect and
  /// resume transfers.
  Future<void> setKeepAwake(bool value) async {
    if (value == _keepAwake) return;
    _keepAwake = value;
    notifyListeners();
    if (isRunning) {
      await start(
        sharedPaths: _sharedPaths,
        mode: _mode,
        allowWrites: _allowWrites,
      );
    } else {
      await _savePreferences();
    }
  }

  Future<void> _savePreferences() async {
    await _dataDirectory.create(recursive: true);
    final temporary = File('${_preferences.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'folders': _sharedPaths,
        'mode': _mode.name,
        'allowWrites': _allowWrites,
        'autoStart': _autoStart,
        'keepAwake': _keepAwake,
      }),
      flush: true,
    );
    if (await _preferences.exists()) await _preferences.delete();
    await temporary.rename(_preferences.path);
  }

  Future<void> refreshTailscale() async {
    _tailscale = await _readTailscale();
    notifyListeners();
  }

  Future<void> start({
    required List<String> sharedPaths,
    bool listenOnLan = false,
    ServerNetworkMode? mode,
    bool allowWrites = false,
  }) async {
    if (_state == DesktopServerState.starting) return;
    final selectedMode =
        mode ??
        (listenOnLan ? ServerNetworkMode.lan : ServerNetworkMode.thisPc);
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
    _mode = selectedMode;
    _allowWrites = allowWrites;
    notifyListeners();
    try {
      await _savePreferences();
      if (_background) {
        await _startAgent();
        return;
      }
      if (selectedMode == ServerNetworkMode.privateNetwork) {
        _tailscale = await _readTailscale();
      }
      final bind = await bindAddressesFor(selectedMode, _tailscale);
      final identity = await TlsIdentity.loadOrCreate(_dataDirectory);
      fingerprint = identity.fingerprint;
      final server = await NexGalleryServer.create(
        RemoteServerConfig(
          allowedRoots: roots,
          dataDirectory: _dataDirectory,
          port: port,
          listenOnLan: selectedMode == ServerNetworkMode.lan,
          bindAddresses: bind,
          securityContext: identity.context,
          certificateFingerprint: identity.fingerprint,
          allowWrites: allowWrites,
          keepAwake: _keepAwake,
          // The app manages the in-process server directly; nothing else on
          // this PC can use the owner HTTP endpoints.
          ownerSecret: _randomSecret(),
        ),
      );
      await server.start();
      _urls = await serverUrlsFor(server.boundPort!, selectedMode, _tailscale);
      await _attach(_InProcess(server));
    } catch (error) {
      _fail(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> _attach(_ServerHandle handle) async {
    _handle = handle;
    _changes = handle.changes.listen((_) => unawaited(_sync()));
    _pairingCode = await handle.newCode();
    _state = DesktopServerState.running;
    await _sync();
  }

  Future<void> _sync() async {
    final handle = _handle;
    if (handle == null) return;
    try {
      _pending = await handle.pending();
      _devices = await handle.devices();
      _quarantined = await handle.quarantined();
    } on Object catch (error) {
      if (handle is _Agent) {
        _error = 'The background server stopped responding: $error';
      }
    }
    notifyListeners();
  }

  /// Moves the server into (or out of) the background agent.
  Future<void> setRunInBackground(bool value) async {
    if (value == _background) return;
    final executable = await _agents.findExecutable();
    if (value && executable == null) {
      _error = 'The background server is not installed with this build.';
      notifyListeners();
      return;
    }
    final wasRunning = isRunning;
    await stop();
    _background = value;
    try {
      if (value) {
        await _agents.register(executable!, AgentConfig.file(_dataDirectory));
      } else {
        await _agents.unregister();
      }
    } catch (error) {
      _fail(error.toString());
      return;
    }
    notifyListeners();
    if ((wasRunning || value) && _sharedPaths.isNotEmpty) {
      await start(
        sharedPaths: _sharedPaths,
        mode: _mode,
        allowWrites: _allowWrites,
      );
    }
  }

  Future<void> _startAgent() async {
    final executable = await _agents.findExecutable();
    if (executable == null) {
      throw StateError(
        'The background server is not installed with this build.',
      );
    }
    // Validates Tailscale before handing over to the agent.
    if (_mode == ServerNetworkMode.privateNetwork) {
      await bindAddressesFor(_mode, _tailscale = await _readTailscale());
    }
    await TlsIdentity.loadOrCreate(_dataDirectory);
    final config = AgentConfig(
      roots: roots,
      mode: _mode,
      allowWrites: _allowWrites,
      keepAwake: _keepAwake,
      port: port == 0 ? 8732 : port,
    );
    await config.write(AgentConfig.file(_dataDirectory));
    await loadOrCreateOwnerSecret(_dataDirectory);
    await _agents.start(executable, AgentConfig.file(_dataDirectory));
    if (!await _adoptAgent(launchIfStopped: false)) {
      throw StateError('The background server did not start.');
    }
  }

  /// Connects to a running agent; waits up to ten seconds for it to start.
  Future<bool> _adoptAgent({required bool launchIfStopped}) async {
    final configFile = AgentConfig.file(_dataDirectory);
    if (!await configFile.exists()) return false;
    final AgentConfig config;
    try {
      config = await AgentConfig.read(configFile);
    } on FormatException {
      return false;
    }
    final identity = await TlsIdentity.loadOrCreate(_dataDirectory);
    final client = OwnerClient(
      port: config.port,
      ownerSecret: await loadOrCreateOwnerSecret(_dataDirectory),
      fingerprint: identity.fingerprint,
    );
    var running = await client.isRunning();
    if (!running && launchIfStopped) {
      final executable = await _agents.findExecutable();
      if (executable != null) await _agents.start(executable, configFile);
    }
    for (var attempt = 0; !running && attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      running = await client.isRunning();
    }
    if (!running) {
      client.close();
      return false;
    }
    _background = true;
    fingerprint = identity.fingerprint;
    _sharedPaths = List.unmodifiable(config.roots.values);
    _mode = config.mode;
    _allowWrites = config.allowWrites;
    _keepAwake = config.keepAwake;
    if (_mode == ServerNetworkMode.privateNetwork) {
      _tailscale = await _readTailscale();
    }
    _urls = await serverUrlsFor(config.port, _mode, _tailscale);
    await _attach(_Agent(client));
    return true;
  }

  Future<void> createPairingCode() async {
    final handle = _handle;
    if (handle == null) return;
    _pairingCode = await handle.newCode();
    notifyListeners();
  }

  Future<void> approve(
    String requestId, {
    required Set<String> scopes,
    List<String>? roots,
  }) async {
    await _handle?.approve(requestId, scopes, roots);
    // A used code cannot pair another phone; show a fresh one.
    await createPairingCode();
    await _sync();
  }

  Future<void> deny(String requestId) async {
    await _handle?.deny(requestId);
    await _sync();
  }

  Future<void> revoke(String tokenId) async {
    await _handle?.revoke(tokenId);
    await _sync();
  }

  Future<void> updatePermissions(
    String tokenId, {
    required Set<String> scopes,
    List<String>? roots,
  }) async {
    await _handle?.updatePermissions(tokenId, scopes, roots);
    await _sync();
  }

  Future<List<Map<String, Object?>>> readAudit({int limit = 200}) async =>
      await _handle?.audit(limit) ?? const [];

  /// Moves a held upload into its shared folder; returns where it went.
  Future<String?> releaseUpload(QuarantinedUpload item) async {
    final path = await _handle?.release(item.root, item.id);
    await _sync();
    return path;
  }

  Future<void> discardUpload(QuarantinedUpload item) async {
    await _handle?.discard(item.root, item.id);
    await _sync();
  }

  Future<void> stop() async {
    final handle = _handle;
    _handle = null;
    await _changes?.cancel();
    _changes = null;
    _pairingCode = null;
    _urls = const <String>[];
    _pending = const [];
    _quarantined = const [];
    if (handle != null) {
      try {
        await handle.stop();
      } on Object {
        // An agent that already exited is stopped.
      }
    }
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
    final handle = _handle;
    _handle = null;
    unawaited(_changes?.cancel());
    // Closing the app leaves a background agent running on purpose.
    if (handle is _InProcess) unawaited(handle.stop());
    if (handle is _Agent) handle.client.close();
    super.dispose();
  }
}

Directory _defaultDirectory() {
  final localAppData =
      Platform.environment['LOCALAPPDATA'] ??
      Platform.environment['APPDATA'] ??
      Directory.systemTemp.path;
  return Directory(
    '$localAppData${Platform.pathSeparator}nexGallery'
    '${Platform.pathSeparator}server',
  );
}

String _randomSecret() {
  final random = Random.secure();
  return base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));
}
