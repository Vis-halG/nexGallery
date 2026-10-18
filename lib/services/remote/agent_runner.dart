import 'dart:async';
import 'dart:io';

import 'agent_config.dart';
import 'network_modes.dart';
import 'nex_gallery_server.dart';
import 'owner_client.dart';
import 'tailscale.dart';
import 'tls_identity.dart';

/// Appends timestamped lines to the agent's private log, keeping one older
/// file once it grows past [maxBytes].
final class AgentLog {
  AgentLog(this.file, {this.maxBytes = 1024 * 1024});

  final File file;
  final int maxBytes;
  Future<void> _writing = Future<void>.value();

  void write(String message) {
    final line = '${DateTime.now().toUtc().toIso8601String()} $message\n';
    _writing = _writing.then((_) => _append(line)).catchError((Object _) {});
  }

  Future<void> _append(String line) async {
    await file.parent.create(recursive: true);
    if (await file.exists() && await file.length() > maxBytes) {
      final older = File('${file.path}.1');
      if (await older.exists()) await older.delete();
      await file.rename(older.path);
    }
    await file.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<void> flush() => _writing;
}

/// Runs `nexgallery_server.exe --config agent.json`: the server keeps serving
/// with the signed-in user's rights while the desktop window is closed, until
/// the owner stops it from the app.
final class AgentRunner {
  AgentRunner(
    this.configFile, {
    AgentLog? log,
    Future<TailscaleStatus> Function()? tailscale,
    this.networkCheck = const Duration(seconds: 30),
  }) : log =
           log ??
           AgentLog(
             File(
               '${configFile.parent.path}${Platform.pathSeparator}agent.log',
             ),
           ),
       _readTailscale = tailscale ?? readTailscaleStatus;

  final File configFile;
  final AgentLog log;
  final Future<TailscaleStatus> Function() _readTailscale;

  /// How often private-network mode looks for Tailscale address changes.
  final Duration networkCheck;

  final _stopped = Completer<void>();
  NexGalleryServer? _server;

  /// The running server, for tests.
  NexGalleryServer? get server => _server;

  /// Serves until [stop] or the owner's shutdown request. Returns the process
  /// exit code.
  Future<int> run() async {
    final directory = configFile.parent;
    final AgentConfig config;
    try {
      config = await AgentConfig.read(configFile);
    } on Object catch (error) {
      log.write('Cannot read ${configFile.path}: $error');
      await log.flush();
      return 78;
    }
    final identity = await TlsIdentity.loadOrCreate(directory);
    final secret = await loadOrCreateOwnerSecret(directory);
    final probe = OwnerClient(
      port: config.port,
      ownerSecret: secret,
      fingerprint: identity.fingerprint,
    );
    try {
      if (await probe.isRunning()) {
        log.write('Another nexGallery agent is already serving this user.');
        await log.flush();
        return 0;
      }
    } finally {
      probe.close();
    }

    log.write(
      'Starting: mode=${config.mode.name} port=${config.port} '
      'roots=${config.roots.length} writes=${config.allowWrites}',
    );
    var bind = await _bindAddresses(config.mode);
    try {
      while (!_stopped.isCompleted) {
        final server = await NexGalleryServer.create(
          RemoteServerConfig(
            allowedRoots: config.roots,
            dataDirectory: directory,
            port: config.port,
            listenOnLan: config.mode == ServerNetworkMode.lan,
            bindAddresses: bind,
            securityContext: identity.context,
            certificateFingerprint: identity.fingerprint,
            allowWrites: config.allowWrites,
            keepAwake: config.keepAwake,
            ownerSecret: secret,
            log: log.write,
          ),
        );
        await server.start();
        _server = server;
        log.write(
          'Listening on ${server.boundAddresses.map((a) => a.address).join(', ')}',
        );
        final shutdown = server.events.firstWhere(
          (event) => event == 'shutdown',
        );
        final changed = Completer<List<InternetAddress>?>();
        Timer? timer;
        if (config.mode == ServerNetworkMode.privateNetwork) {
          timer = Timer.periodic(networkCheck, (_) async {
            final next = await _bindAddresses(config.mode);
            if (!changed.isCompleted && !_sameAddresses(next, bind)) {
              changed.complete(next);
            }
          });
        }
        final reason = await Future.any<Object?>([
          shutdown.then((_) => 'shutdown'),
          _stopped.future.then((_) => 'stop'),
          changed.future,
        ]);
        timer?.cancel();
        await server.stop(force: true);
        _server = null;
        if (reason is String) {
          log.write('Stopped by $reason.');
          break;
        }
        bind = reason as List<InternetAddress>?;
        log.write('Network changed; restarting.');
      }
    } on Object catch (error, stackTrace) {
      log.write('Agent failed: $error\n$stackTrace');
      await log.flush();
      return 70;
    }
    await log.flush();
    return 0;
  }

  void stop() {
    if (!_stopped.isCompleted) _stopped.complete();
  }

  /// In private-network mode without Tailscale, only loopback is served so
  /// the app can still manage the agent; the tailnet is added once it
  /// connects.
  Future<List<InternetAddress>?> _bindAddresses(ServerNetworkMode mode) async {
    if (mode != ServerNetworkMode.privateNetwork) return null;
    try {
      return await bindAddressesFor(mode, await _readTailscale());
    } on StateError {
      return [InternetAddress.loopbackIPv4];
    }
  }

  static bool _sameAddresses(
    List<InternetAddress>? a,
    List<InternetAddress>? b,
  ) {
    if (a == null || b == null) return a == b;
    final left = a.map((address) => address.address).toSet();
    final right = b.map((address) => address.address).toSet();
    return left.length == right.length && left.containsAll(right);
  }
}
