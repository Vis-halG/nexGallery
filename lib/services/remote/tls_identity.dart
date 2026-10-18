import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';

import 'protected_file.dart';
import 'sha256.dart';

final class TlsIdentity {
  TlsIdentity(this.context, this.fingerprint);
  final SecurityContext context;
  final String fingerprint;

  static Future<TlsIdentity> loadOrCreate(Directory directory) async {
    await directory.create(recursive: true);
    final certificate = File('${directory.path}/server.crt');
    final privateKey = File('${directory.path}/server.key');
    if (!await certificate.exists() || !await privateKey.exists()) {
      if (await certificate.exists() || await privateKey.exists()) {
        throw const FileSystemException(
          'Server identity is incomplete. Restore its certificate and key together.',
        );
      }
      final pair = await Isolate.run(() {
        final keys = CryptoUtils.generateRSAKeyPair();
        final csr = X509Utils.generateRsaCsrPem(
          {'CN': 'nexGallery personal PC'},
          keys.privateKey as RSAPrivateKey,
          keys.publicKey as RSAPublicKey,
        );
        return (
          X509Utils.generateSelfSignedCertificate(
            keys.privateKey,
            csr,
            3650,
            cA: false,
            serialNumber: DateTime.now().microsecondsSinceEpoch.toString(),
          ),
          CryptoUtils.encodeRSAPrivateKeyToPem(
            keys.privateKey as RSAPrivateKey,
          ),
        );
      });
      await ProtectedFile.write(privateKey, utf8.encode(pair.$2));
      await certificate.writeAsString(pair.$1, flush: true);
    }
    final context = SecurityContext()
      ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2
      ..useCertificateChain(certificate.path)
      ..usePrivateKeyBytes(await ProtectedFile.read(privateKey));
    final der = CryptoUtils.getBytesFromPEMString(
      await certificate.readAsString(),
    );
    return TlsIdentity(context, sha256Hex(der));
  }
}
