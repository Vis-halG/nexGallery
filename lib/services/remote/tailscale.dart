import 'dart:convert';
import 'dart:io';

final class TailscalePeer {
  const TailscalePeer({
    required this.name,
    required this.addresses,
    required this.online,
    required this.connection,
    this.relay,
    this.os,
  });

  final String name;
  final List<String> addresses;
  final bool online;

  /// `direct` (peer-to-peer), `relay` (encrypted DERP relay) or `idle`.
  final String connection;
  final String? relay;
  final String? os;
}

final class TailscaleStatus {
  const TailscaleStatus({
    required this.installed,
    this.running = false,
    this.state,
    this.selfName,
    this.dnsName,
    this.addresses = const [],
    this.peers = const [],
    this.error,
  });

  static const notInstalled = TailscaleStatus(installed: false);

  final bool installed;
  final bool running;

  /// Tailscale's backend state, for example `Running` or `NeedsLogin`.
  final String? state;
  final String? selfName;
  final String? dnsName;
  final List<String> addresses;
  final List<TailscalePeer> peers;
  final String? error;

  List<String> get ipv4 =>
      addresses.where((address) => !address.contains(':')).toList();

  TailscalePeer? peerFor(String address) {
    for (final peer in peers) {
      if (peer.addresses.contains(address)) return peer;
    }
    return null;
  }
}

/// True for Tailscale CGNAT (100.64.0.0/10) and ULA (fd7a:115c:a1e0::/48)
/// addresses.
bool isTailnetAddress(String address) {
  final parsed = InternetAddress.tryParse(address);
  if (parsed == null) return false;
  final bytes = parsed.rawAddress;
  if (parsed.type == InternetAddressType.IPv4) {
    return bytes[0] == 100 && (bytes[1] & 0xC0) == 64;
  }
  return bytes.length == 16 &&
      bytes[0] == 0xfd &&
      bytes[1] == 0x7a &&
      bytes[2] == 0x11 &&
      bytes[3] == 0x5c &&
      bytes[4] == 0xa1 &&
      bytes[5] == 0xe0;
}

TailscaleStatus parseTailscaleStatus(String json) {
  final value = jsonDecode(json);
  if (value is! Map) {
    throw const FormatException('Unexpected Tailscale status.');
  }
  List<String> ips(Object? list) =>
      list is List ? list.whereType<String>().toList() : const [];
  String trimDot(String? value) =>
      value == null ? '' : value.replaceAll(RegExp(r'\.$'), '');
  final self = value['Self'];
  final peers = <TailscalePeer>[];
  final rawPeers = value['Peer'];
  if (rawPeers is Map) {
    for (final peer in rawPeers.values.whereType<Map>()) {
      final online = peer['Online'] == true;
      final current = '${peer['CurAddr'] ?? ''}';
      final relay = '${peer['Relay'] ?? ''}';
      peers.add(
        TailscalePeer(
          name: '${peer['HostName'] ?? trimDot(peer['DNSName'] as String?)}',
          addresses: ips(peer['TailscaleIPs']),
          online: online,
          connection: !online
              ? 'idle'
              : current.isNotEmpty
              ? 'direct'
              : relay.isNotEmpty
              ? 'relay'
              : 'idle',
          relay: relay.isEmpty ? null : relay,
          os: peer['OS'] as String?,
        ),
      );
    }
  }
  final state = value['BackendState'] as String?;
  return TailscaleStatus(
    installed: true,
    running: state == 'Running',
    state: state,
    selfName: self is Map ? self['HostName'] as String? : null,
    dnsName: self is Map ? trimDot(self['DNSName'] as String?) : null,
    addresses: self is Map
        ? ips(self['TailscaleIPs'])
        : ips(value['TailscaleIPs']),
    peers: peers,
  );
}

/// Reads `tailscale status --json` from the official Windows client.
Future<TailscaleStatus> readTailscaleStatus() async {
  final candidates = <String>[
    if (Platform.isWindows) ...[
      '${Platform.environment['ProgramFiles'] ?? r'C:\Program Files'}\\Tailscale\\tailscale.exe',
      '${Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)'}\\Tailscale\\tailscale.exe',
    ],
    'tailscale',
  ];
  for (final executable in candidates) {
    if (executable.contains(r'\') && !await File(executable).exists()) continue;
    try {
      final result = await Process.run(executable, [
        'status',
        '--json',
      ], stdoutEncoding: utf8).timeout(const Duration(seconds: 8));
      final output = '${result.stdout}'.trim();
      if (output.startsWith('{')) return parseTailscaleStatus(output);
      return TailscaleStatus(
        installed: true,
        error: '${result.stderr}'.trim().isEmpty
            ? 'Tailscale is not running.'
            : '${result.stderr}'.trim(),
      );
    } on ProcessException {
      continue;
    } on FormatException catch (error) {
      return TailscaleStatus(installed: true, error: error.message);
    }
  }
  return TailscaleStatus.notInstalled;
}

/// Tailnet addresses assigned to this machine's network interfaces, used
/// when the Tailscale CLI is unavailable.
Future<List<String>> localTailnetAddresses() async => [
  for (final interface in await NetworkInterface.list(
    includeLoopback: false,
    type: InternetAddressType.any,
  ))
    for (final address in interface.addresses)
      if (isTailnetAddress(address.address)) address.address,
];
