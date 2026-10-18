import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'nex_gallery_server.dart' show discoveryRequest;

final class DiscoveredPc {
  const DiscoveredPc({
    required this.name,
    required this.address,
    required this.port,
    required this.tls,
    this.fingerprint,
  });

  final String name;
  final InternetAddress address;
  final int port;
  final bool tls;
  final String? fingerprint;

  Uri get uri =>
      Uri(scheme: tls ? 'https' : 'http', host: address.address, port: port);

  /// Short form the user compares with the fingerprint on the PC screen.
  String? get shortFingerprint {
    final value = fingerprint;
    if (value == null || value.length < 8) return null;
    return '${value.substring(0, 4)} ${value.substring(4, 8)}'.toUpperCase();
  }
}

/// Broadcasts a discovery request on the local network and collects replies
/// from nexGallery PCs for [timeout].
Future<List<DiscoveredPc>> discoverPcs({
  Duration timeout = const Duration(seconds: 2),
  int port = 8733,
  InternetAddress? target,
}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final found = <String, DiscoveredPc>{};
  final done = Completer<void>();
  final subscription = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null || datagram.data.length > 2048) return;
    try {
      final value = jsonDecode(utf8.decode(datagram.data));
      if (value is! Map || value['service'] != 'nexgallery') return;
      final pcPort = value['port'];
      if (pcPort is! int || pcPort <= 0 || pcPort > 65535) return;
      final name = '${value['name'] ?? 'PC'}';
      found['${datagram.address.address}:$pcPort'] = DiscoveredPc(
        name: name.length > 64 ? name.substring(0, 64) : name,
        address: datagram.address,
        port: pcPort,
        tls: value['tls'] == true,
        fingerprint: value['fingerprint'] is String
            ? (value['fingerprint'] as String).toLowerCase()
            : null,
      );
    } on FormatException {
      // Ignore unrelated datagrams.
    }
  });
  try {
    final message = utf8.encode(discoveryRequest);
    final destination = target ?? InternetAddress('255.255.255.255');
    // Repeat once: broadcasts are unreliable on busy Wi-Fi.
    socket.send(message, destination, port);
    Timer(timeout ~/ 2, () => socket.send(message, destination, port));
    Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
  } finally {
    await subscription.cancel();
    socket.close();
  }
  return found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

/// Builds a Wake-on-LAN magic packet: six 0xFF bytes and the MAC 16 times.
Uint8List magicPacket(String mac) {
  final parts = mac.split(RegExp(r'[:-]'));
  if (parts.length != 6) {
    throw const FormatException('Enter a MAC address like AA:BB:CC:DD:EE:FF.');
  }
  final bytes = [
    for (final part in parts)
      int.tryParse(part, radix: 16) ??
          (throw const FormatException('Invalid MAC address.')),
  ];
  if (bytes.any((value) => value < 0 || value > 255)) {
    throw const FormatException('Invalid MAC address.');
  }
  return Uint8List.fromList([
    for (var i = 0; i < 6; i++) 0xFF,
    for (var i = 0; i < 16; i++) ...bytes,
  ]);
}

/// Sends magic packets to the local broadcast address on ports 9 and 7. The PC
/// must have Wake-on-LAN enabled and be on the same network.
Future<void> wakeOnLan(String mac, {InternetAddress? broadcast}) async {
  final packet = magicPacket(mac);
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  try {
    socket.broadcastEnabled = true;
    final target = broadcast ?? InternetAddress('255.255.255.255');
    for (final port in [9, 7]) {
      socket.send(packet, target, port);
    }
  } finally {
    socket.close();
  }
}
