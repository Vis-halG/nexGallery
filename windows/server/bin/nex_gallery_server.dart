import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nex_gallery/services/remote/nex_gallery_server.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _usage();
    return;
  }

  try {
    final options = _Options.parse(arguments);
    final server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: options.roots,
        dataDirectory: Directory(options.dataDirectory),
        port: options.port,
        listenOnLan: options.lan,
      ),
    );
    await server.start();
    final code = server.createPairingCode();

    stdout.writeln('nexGallery PC server is running.');
    stdout.writeln('Allowed roots:');
    for (final entry in options.roots.entries) {
      stdout.writeln('  ${entry.key}: ${Directory(entry.value).absolute.path}');
    }
    stdout.writeln('Pairing code: ${code.code}');
    stdout.writeln('Expires: ${code.expiresAt.toLocal()}');
    stdout.writeln('QR payloads (encode one complete JSON line in a QR code):');
    for (final url in await _serverUrls(server.boundPort!, options.lan)) {
      stdout.writeln(
        jsonEncode(<String, Object?>{
          'version': 1,
          'serverUrl': url,
          'pairPath': '/v1/pair',
          'code': code.code,
          'expiresAt': code.expiresAt.toUtc().toIso8601String(),
          'tls': false,
        }),
      );
    }
    if (options.lan) {
      stdout.writeln(
        'SECURITY: LAN mode uses plain HTTP. Keep it on a trusted private LAN; '
        'do not port-forward this server to the internet.',
      );
    } else {
      stdout.writeln(
        'Loopback-only mode is active. Restart with --lan for trusted-LAN access.',
      );
    }
    stdout.writeln('Press Ctrl+C to stop.');

    final stopped = Completer<void>();
    late final StreamSubscription<ProcessSignal> interruptSubscription;
    interruptSubscription = ProcessSignal.sigint.watch().listen((_) async {
      if (!stopped.isCompleted) {
        await server.stop();
        stopped.complete();
      }
    });
    await stopped.future;
    await interruptSubscription.cancel();
  } on FormatException catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    _usage();
    exitCode = 64;
  } on ArgumentError catch (error) {
    stderr.writeln('Configuration error: ${error.message}');
    exitCode = 64;
  } on SocketException catch (error) {
    stderr.writeln('Could not start server: ${error.message}');
    exitCode = 69;
  }
}

Future<List<String>> _serverUrls(int port, bool lan) async {
  if (!lan) {
    return <String>['http://127.0.0.1:$port'];
  }
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
      : urls.toSet().toList();
}

void _usage() {
  stdout.writeln('''
Usage:
  dart run windows/server/bin/nex_gallery_server.dart \\
    --root photos=D:\\Photos --root documents=D:\\Documents [options]

Required:
  --root ID=PATH      Allow one folder. Repeat for more folders.

Options:
  --port NUMBER       Listening port (default: 8732; 0 selects a free port).
  --data-dir PATH     Token and audit storage directory.
  --lan               Bind to the private LAN. Default is loopback only.
  --help              Show this help.

This server does not provide TLS and must not be exposed by public port forwarding.
''');
}

final class _Options {
  const _Options({
    required this.roots,
    required this.dataDirectory,
    required this.port,
    required this.lan,
  });

  final Map<String, String> roots;
  final String dataDirectory;
  final int port;
  final bool lan;

  static _Options parse(List<String> arguments) {
    final roots = <String, String>{};
    var port = 8732;
    var lan = false;
    String? dataDirectory;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '--root':
          final value = _next(arguments, ++index, '--root');
          final separator = value.indexOf('=');
          if (separator <= 0 || separator == value.length - 1) {
            throw const FormatException('--root must use ID=PATH.');
          }
          final id = value.substring(0, separator);
          if (roots.containsKey(id)) {
            throw FormatException('Duplicate root id: $id');
          }
          roots[id] = value.substring(separator + 1);
        case '--port':
          final value = _next(arguments, ++index, '--port');
          port = int.tryParse(value) ?? -1;
          if (port < 0 || port > 65535) {
            throw const FormatException('--port must be between 0 and 65535.');
          }
        case '--data-dir':
          dataDirectory = _next(arguments, ++index, '--data-dir');
        case '--lan':
          lan = true;
        default:
          throw FormatException('Unknown option: $argument');
      }
    }
    if (roots.isEmpty) {
      throw const FormatException('At least one --root is required.');
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    dataDirectory ??= localAppData == null || localAppData.isEmpty
        ? '${Directory.current.path}${Platform.pathSeparator}.nexgallery-server'
        : '$localAppData${Platform.pathSeparator}nexGallery${Platform.pathSeparator}server';
    return _Options(
      roots: Map<String, String>.unmodifiable(roots),
      dataDirectory: dataDirectory,
      port: port,
      lan: lan,
    );
  }

  static String _next(List<String> values, int index, String option) {
    if (index >= values.length) {
      throw FormatException('$option requires a value.');
    }
    return values[index];
  }
}
