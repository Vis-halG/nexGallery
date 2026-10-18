import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/agent_config.dart';
import 'package:nex_gallery/services/remote/protected_file.dart';
import 'package:nex_gallery/services/remote/tls_identity.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nex_protected_');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'Windows secrets are DPAPI-encrypted and older plain files migrate',
    () async {
      final file = File(p.join(directory.path, 'secret.key'));
      await ProtectedFile.write(file, utf8.encode('top secret'));
      final stored = await file.readAsBytes();
      expect(ProtectedFile.isProtected(stored), isTrue);
      expect(
        utf8.decode(stored, allowMalformed: true),
        isNot(contains('top secret')),
      );
      expect(utf8.decode(await ProtectedFile.read(file)), 'top secret');

      final legacy = File(p.join(directory.path, 'legacy.key'));
      await legacy.writeAsString('older plain value');
      expect(
        utf8.decode(await ProtectedFile.read(legacy)),
        'older plain value',
      );
      expect(ProtectedFile.isProtected(await legacy.readAsBytes()), isTrue);
      expect(
        utf8.decode(await ProtectedFile.read(legacy)),
        'older plain value',
      );
    },
    skip: !Platform.isWindows,
  );

  test('the owner secret and TLS key survive reloading', () async {
    final secret = await loadOrCreateOwnerSecret(directory);
    expect(secret.length, greaterThanOrEqualTo(32));
    expect(await loadOrCreateOwnerSecret(directory), secret);

    final identity = await TlsIdentity.loadOrCreate(directory);
    final key = await File(p.join(directory.path, 'server.key')).readAsBytes();
    expect(ProtectedFile.isProtected(key), Platform.isWindows);
    final again = await TlsIdentity.loadOrCreate(directory);
    expect(again.fingerprint, identity.fingerprint);

    // The protected key still serves TLS.
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      again.context,
    );
    addTearDown(server.close);
    server.listen((socket) => socket.destroy());
    final client = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
      onBadCertificate: (_) => true,
    );
    client.destroy();
  });
}
