/// What the PC shows as a QR code: where to connect, the one-time code and
/// the certificate fingerprint the phone must pin.
final class PairingPayload {
  PairingPayload({
    required this.name,
    required this.addresses,
    required this.code,
    required this.fingerprint,
  });

  final String name;
  final List<Uri> addresses;
  final String code;
  final String fingerprint;

  String encode() => Uri(
    scheme: 'nexgallery',
    host: 'pair',
    queryParameters: <String, Object>{
      'v': '1',
      'n': name,
      'u': [for (final address in addresses) address.toString()],
      'c': code,
      'f': fingerprint,
    },
  ).toString();

  /// Parses a scanned or pasted pairing link. Only HTTPS addresses are kept.
  static PairingPayload parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null ||
        uri.scheme != 'nexgallery' ||
        uri.host != 'pair' ||
        uri.queryParameters['v'] != '1') {
      throw const FormatException('This is not a nexGallery pairing code.');
    }
    final code = uri.queryParameters['c'] ?? '';
    final fingerprint = (uri.queryParameters['f'] ?? '').toLowerCase();
    if (!RegExp(r'^\d{6,12}$').hasMatch(code) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(fingerprint)) {
      throw const FormatException('The pairing code is incomplete.');
    }
    final addresses = [
      for (final value in uri.queryParametersAll['u'] ?? const <String>[])
        if (Uri.tryParse(value) case final address?
            when address.scheme == 'https' && address.host.isNotEmpty)
          address,
    ];
    if (addresses.isEmpty) {
      throw const FormatException('The pairing code has no secure address.');
    }
    final name = uri.queryParameters['n'] ?? 'PC';
    return PairingPayload(
      name: name.length > 64 ? name.substring(0, 64) : name,
      addresses: addresses,
      code: code,
      fingerprint: fingerprint,
    );
  }
}
