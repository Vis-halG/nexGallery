import 'dart:io';

import 'tailscale.dart';

/// Who can reach the server. Every mode still requires pairing and approval.
enum ServerNetworkMode {
  /// Loopback only, for testing on this PC.
  thisPc,

  /// Every network interface, for a trusted home network.
  lan,

  /// Loopback plus this PC's Tailscale addresses: reachable from paired
  /// phones anywhere, never from the public internet or the local LAN.
  privateNetwork,
}

/// Interfaces to bind for [mode]; null means the server's LAN/loopback
/// default. Throws when private-network mode has no Tailscale address.
Future<List<InternetAddress>?> bindAddressesFor(
  ServerNetworkMode mode,
  TailscaleStatus? tailscale,
) async {
  if (mode != ServerNetworkMode.privateNetwork) return null;
  final tailnet = tailscale != null && tailscale.ipv4.isNotEmpty
      ? tailscale.ipv4
      : (await localTailnetAddresses())
            .where((address) => !address.contains(':'))
            .toList();
  if (tailnet.isEmpty) {
    throw StateError(
      'Tailscale is not connected on this PC. Open Tailscale, sign in, then start again.',
    );
  }
  return [
    InternetAddress.loopbackIPv4,
    for (final address in tailnet) InternetAddress(address),
  ];
}

/// Addresses phones can use, for the QR code and the address list.
Future<List<String>> serverUrlsFor(
  int port,
  ServerNetworkMode mode,
  TailscaleStatus? tailscale, {
  bool tls = true,
}) async {
  final scheme = tls ? 'https' : 'http';
  switch (mode) {
    case ServerNetworkMode.thisPc:
      return <String>['$scheme://127.0.0.1:$port'];
    case ServerNetworkMode.privateNetwork:
      return <String>[
        for (final address in tailscale?.ipv4 ?? await localTailnetAddresses())
          if (!address.contains(':')) '$scheme://$address:$port',
        if (tailscale?.dnsName case final name? when name.isNotEmpty)
          '$scheme://$name:$port',
      ];
    case ServerNetworkMode.lan:
      final urls = <String>[];
      for (final interface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      )) {
        for (final address in interface.addresses) {
          if (!isTailnetAddress(address.address)) {
            urls.add('$scheme://${address.address}:$port');
          }
        }
      }
      return urls.isEmpty
          ? <String>['$scheme://<PC-LAN-IP>:$port']
          : urls.toSet().toList(growable: false);
  }
}
