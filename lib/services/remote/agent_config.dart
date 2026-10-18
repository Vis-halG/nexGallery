import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'network_modes.dart';
import 'protected_file.dart';

/// Settings for the background server agent, written by the desktop app and
/// read by `nexgallery_server.exe --config`.
final class AgentConfig {
  const AgentConfig({
    required this.roots,
    this.mode = ServerNetworkMode.thisPc,
    this.allowWrites = false,
    this.keepAwake = false,
    this.port = 8732,
  });

  factory AgentConfig.fromJson(Map<String, dynamic> json) {
    final roots = json['roots'];
    if (json['version'] != 1 || roots is! Map || roots.isEmpty) {
      throw const FormatException('The agent configuration is invalid.');
    }
    final port = json['port'];
    if (port is! int || port < 0 || port > 65535) {
      throw const FormatException('The agent port is invalid.');
    }
    return AgentConfig(
      roots: {
        for (final entry in roots.entries) '${entry.key}': '${entry.value}',
      },
      mode: ServerNetworkMode.values.firstWhere(
        (mode) => mode.name == json['mode'],
        orElse: () => ServerNetworkMode.thisPc,
      ),
      allowWrites: json['allowWrites'] == true,
      keepAwake: json['keepAwake'] == true,
      port: port,
    );
  }

  final Map<String, String> roots;
  final ServerNetworkMode mode;
  final bool allowWrites;

  /// Stops Windows sleeping while the agent runs.
  final bool keepAwake;
  final int port;

  Map<String, Object?> toJson() => {
    'version': 1,
    'roots': roots,
    'mode': mode.name,
    'allowWrites': allowWrites,
    'keepAwake': keepAwake,
    'port': port,
  };

  static File file(Directory dataDirectory) =>
      File('${dataDirectory.path}${Platform.pathSeparator}agent.json');

  static Future<AgentConfig> read(File file) async => AgentConfig.fromJson(
    jsonDecode(await file.readAsString()) as Map<String, dynamic>,
  );

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}

/// The secret that lets only this Windows user's nexGallery app manage the
/// agent. It lives in the per-user data folder, encrypted for this Windows
/// user with DPAPI.
Future<String> loadOrCreateOwnerSecret(Directory dataDirectory) async {
  final file = File('${dataDirectory.path}${Platform.pathSeparator}owner.key');
  if (await file.exists()) {
    final value = utf8.decode(await ProtectedFile.read(file)).trim();
    if (value.length >= 32) return value;
  }
  final random = Random.secure();
  final secret = base64Url.encode(
    List<int>.generate(32, (_) => random.nextInt(256)),
  );
  await ProtectedFile.write(file, utf8.encode(secret));
  return secret;
}
