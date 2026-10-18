import 'dart:io';

import 'package:path/path.dart' as p;

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);
typedef ProcessLauncher = Future<void> Function(
  String executable,
  List<String> arguments,
);

/// Installs the per-user background server: it starts at Windows sign-in
/// from `HKCU\...\Run` and runs with the signed-in user's own rights.
final class AgentManager {
  AgentManager({
    ProcessRunner? run,
    ProcessLauncher? launch,
    this.executableOverride,
  }) : _run = run ?? Process.run,
       _launch = launch ?? _launchDetached;

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'nexGalleryServer';
  static const executableName = 'nexgallery_server.exe';

  final ProcessRunner _run;
  final ProcessLauncher _launch;

  /// Used by tests and developer builds.
  final String? executableOverride;

  static Future<void> _launchDetached(
    String executable,
    List<String> arguments,
  ) async {
    await Process.start(executable, arguments, mode: ProcessStartMode.detached);
  }

  /// The installer places the agent next to the app executable.
  Future<File?> findExecutable() async {
    final candidates = [
      ?executableOverride,
      ?Platform.environment['NEXGALLERY_SERVER_EXE'],
      p.join(p.dirname(Platform.resolvedExecutable), executableName),
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return File(path);
    }
    return null;
  }

  static List<String> arguments(File config) => ['--config', config.path];

  String _command(File executable, File config) =>
      '"${executable.path}" --config "${config.path}"';

  Future<bool> isRegistered() async {
    final result = await _run('reg', ['query', _runKey, '/v', _valueName]);
    return result.exitCode == 0;
  }

  Future<void> register(File executable, File config) async {
    final result = await _run('reg', [
      'add',
      _runKey,
      '/v',
      _valueName,
      '/t',
      'REG_SZ',
      '/d',
      _command(executable, config),
      '/f',
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Windows did not allow nexGallery to start at sign-in.',
        '${result.stderr}'.trim(),
      );
    }
  }

  Future<void> unregister() async {
    await _run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
  }

  Future<void> start(File executable, File config) =>
      _launch(executable.path, arguments(config));
}
