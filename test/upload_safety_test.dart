import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nex_gallery/services/remote/nex_gallery_client.dart';
import 'package:nex_gallery/services/remote/nex_gallery_server.dart';
import 'package:nex_gallery/services/remote/power.dart';
import 'package:nex_gallery/services/remote/security.dart';
import 'package:nex_gallery/services/remote/upload_quarantine.dart';
import 'package:path/path.dart' as p;

final class _FakeScanner implements UploadScanner {
  _FakeScanner(this.verdict);

  ScanVerdict verdict;
  final scanned = <String>[];
  Completer<void>? gate;

  @override
  String get name => 'Test scanner';

  @override
  Future<ScanVerdict> scan(File file) async {
    scanned.add(await file.readAsString());
    await gate?.future;
    return verdict;
  }
}

final class _NoScanner implements UploadScanner {
  @override
  String get name => 'Unavailable scanner';
  @override
  Future<ScanVerdict> scan(File file) async => ScanVerdict.unavailable;
}

final class _CountingPower implements PowerRequest {
  var held = 0;
  var peak = 0;
  @override
  void acquire() => peak = ++held > peak ? held : peak;
  @override
  void release() => held--;
  @override
  void dispose() {}
}

void main() {
  late Directory workspace;
  late Directory shared;
  late NexGalleryServer server;
  late NexGalleryRemoteClient phone;
  late _FakeScanner scanner;
  late _CountingPower power;
  var started = false;

  Future<void> startServer(UploadScanner uploadScanner) async {
    server = await NexGalleryServer.create(
      RemoteServerConfig(
        allowedRoots: {'shared': shared.path},
        dataDirectory: Directory(p.join(workspace.path, 'state')),
        port: 0,
        allowWrites: true,
        uploadScanner: uploadScanner,
        powerRequest: power,
      ),
    );
    await server.start();
    started = true;
    phone = NexGalleryRemoteClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
    );
    final pairing = phone.pair(
      code: server.createPairingCode().code,
      deviceName: 'Phone',
      pollInterval: const Duration(milliseconds: 20),
    );
    while (server.pendingPairings.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await server.approvePairing(
      server.pendingPairings.single.requestId,
      scopes: DeviceScope.all,
    );
    await pairing;
  }

  Future<UploadResult> send(String name, String content) async {
    final source = File(p.join(workspace.path, 'source-$name'));
    await source.writeAsString(content);
    return phone.upload(root: 'shared', remotePath: name, source: source);
  }

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('nex_upload_safety_');
    shared = await Directory(p.join(workspace.path, 'shared')).create();
    scanner = _FakeScanner(ScanVerdict.clean);
    power = _CountingPower();
  });

  tearDown(() async {
    if (started) {
      phone.close();
      await server.stop(force: true);
      started = false;
    }
    await workspace.delete(recursive: true);
  });

  test('risky file types are recognised; photos are not', () {
    for (final name in ['setup.EXE', 'a/b/run.ps1', 'x.zip', 'app.apk']) {
      expect(needsUploadScan(name), isTrue, reason: name);
    }
    for (final name in ['IMG_1.jpg', 'clip.mp4', 'notes.txt', 'exe']) {
      expect(needsUploadScan(name), isFalse, reason: name);
    }
  });

  test('Defender verdicts come from its report, not only the exit code', () {
    expect(
      parseDefenderResult(
        0,
        'Scan starting...\nScan finished.\n'
        r'Scanning C:\x\hello.zip found no threats.',
      ),
      ScanVerdict.clean,
    );
    expect(
      parseDefenderResult(
        2,
        'Scan starting...\nScan finished.\n'
        r'Scanning C:\x\eicar.com found 1 threats.'
        '\n<===========================LIST OF DETECTED THREATS====>\n'
        'Threat                  : Virus:DOS/EICAR_Test_File',
      ),
      ScanVerdict.threat,
    );
    // A failed scan also exits with 2.
    expect(
      parseDefenderResult(
        2,
        'Scan starting...\nCmdTool: Failed with hr = 0x80508023. Check '
        r'C:\Users\me\AppData\Local\Temp\MpCmdRun.log for more information',
      ),
      ScanVerdict.unavailable,
    );
    expect(parseDefenderResult(0, ''), ScanVerdict.unavailable);
  });

  test('photos go straight to the folder without a scan', () async {
    await startServer(scanner);
    final result = await send('photo.jpg', 'pixels');
    expect(result.quarantined, isFalse);
    expect(
      await File(p.join(shared.path, 'photo.jpg')).readAsString(),
      'pixels',
    );
    expect(scanner.scanned, isEmpty);
    // Listing held uploads never adds folders to the owner's roots.
    expect(await server.quarantined(), isEmpty);
    expect(
      await Directory(p.join(shared.path, '.nexgallery-quarantine')).exists(),
      isFalse,
    );
  });

  test('a clean program appears only after its scan', () async {
    scanner.gate = Completer<void>();
    await startServer(scanner);
    final result = await send('tool.exe', 'MZ program');
    expect(result.quarantined, isTrue);
    expect(result.scan, 'scanning');
    // Hidden from phones and from the folder while it is being scanned.
    expect(await File(p.join(shared.path, 'tool.exe')).exists(), isFalse);
    expect(await phone.list(root: 'shared'), isEmpty);
    expect(
      (await server.quarantined()).single.status,
      QuarantineStatus.scanning,
    );

    scanner.gate!.complete();
    await server.scansSettled;
    expect(
      await File(p.join(shared.path, 'tool.exe')).readAsString(),
      'MZ program',
    );
    expect(scanner.scanned, ['MZ program']);
    if (Platform.isWindows) {
      final attributes = await Process.run('attrib', [
        p.join(shared.path, '.nexgallery-quarantine'),
      ]);
      // attrib prints the flags in the first columns, then the path.
      expect('${attributes.stdout}'.substring(0, 12), contains('H'));
    }
    expect(await server.quarantined(), isEmpty);
    if (Platform.isWindows) {
      expect(
        await File('${p.join(shared.path, 'tool.exe')}:Zone.Identifier')
            .readAsString(),
        contains('ZoneId=3'),
      );
    }
  });

  test('a flagged upload stays blocked and can only be deleted', () async {
    scanner.verdict = ScanVerdict.threat;
    await startServer(scanner);
    await send('invoice.zip', 'not really a zip');
    await server.scansSettled;
    final item = (await server.quarantined()).single;
    expect(item.status, QuarantineStatus.blocked);
    expect(item.deviceName, 'Phone');
    await expectLater(
      server.releaseQuarantined('shared', item.id),
      throwsA(anything),
    );
    expect(await File(p.join(shared.path, 'invoice.zip')).exists(), isFalse);
    await server.deleteQuarantined('shared', item.id);
    expect(await server.quarantined(), isEmpty);
    final audit = await server.readAudit();
    expect(
      audit.map((entry) => entry['action']),
      containsAll(<String>['files.upload.quarantine', 'files.upload.scan']),
    );
  });

  test('without a scanner the owner releases, keeping both names', () async {
    await startServer(_NoScanner());
    final result = await send('script.ps1', 'Write-Host hi');
    expect(result.scan, 'scanning');
    await server.scansSettled;
    final item = (await server.quarantined()).single;
    expect(item.status, QuarantineStatus.held);
    // The name was taken while the upload waited.
    await File(p.join(shared.path, 'script.ps1')).writeAsString('existing');
    final path = await server.releaseQuarantined('shared', item.id);
    expect(path, 'script (2).ps1');
    expect(
      await File(p.join(shared.path, 'script (2).ps1')).readAsString(),
      'Write-Host hi',
    );
    expect(
      await File(p.join(shared.path, 'script.ps1')).readAsString(),
      'existing',
    );
  });

  test('changes made against an older listing are refused', () async {
    await startServer(scanner);
    final file = File(p.join(shared.path, 'notes.txt'));
    await file.writeAsString('first');
    final listed = (await phone.list(root: 'shared')).single;
    expect(listed.version, isNotNull);

    await file.writeAsString('second, longer version');
    await expectLater(
      phone.move(
        root: 'shared',
        sourcePath: 'notes.txt',
        destinationPath: 'renamed.txt',
        version: listed.version,
      ),
      throwsA(
        isA<RemoteApiException>().having((e) => e.code, 'code', 'file_changed'),
      ),
    );
    await expectLater(
      phone.trash(listed),
      throwsA(
        isA<RemoteApiException>().having((e) => e.code, 'code', 'file_changed'),
      ),
    );
    expect(await file.readAsString(), 'second, longer version');

    final fresh = (await phone.list(root: 'shared')).single;
    await phone.move(
      root: 'shared',
      sourcePath: 'notes.txt',
      destinationPath: 'renamed.txt',
      version: fresh.version,
    );
    expect(await File(p.join(shared.path, 'renamed.txt')).exists(), isTrue);
  });

  test('downloads send an ETag, honour If-Match and keep the PC awake', () async {
    await startServer(scanner);
    await File(p.join(shared.path, 'movie.mp4')).writeAsString('frames');
    final entry = (await phone.list(root: 'shared')).single;
    final response = await phone.readStream(entry);
    expect(
      response.headers.value(HttpHeaders.etagHeader),
      '"${entry.version}"',
    );
    expect(await utf8.decodeStream(response), 'frames');
    expect(power.peak, 1);
    expect(server.keepsPcAwake, isTrue, reason: 'grace period after a stream');

    // A phone without a device key can use plain HTTP conditional requests.
    final plain = NexGalleryRemoteClient(
      baseUri: Uri.parse('http://127.0.0.1:${server.boundPort}'),
    );
    addTearDown(plain.close);
    final ticket = await plain.startPairing(
      code: server.createPairingCode().code,
      deviceName: 'Plain',
      signRequests: false,
    );
    await server.approvePairing(ticket!.requestId);
    expect(await plain.checkPairing(ticket), isTrue);
    final http = HttpClient();
    addTearDown(http.close);
    Future<int> status(String ifMatch) async {
      final request = await http.getUrl(
        Uri.parse(
          'http://127.0.0.1:${server.boundPort}/v1/download?root=shared&path=movie.mp4',
        ),
      );
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${plain.token}')
        ..set(HttpHeaders.ifMatchHeader, ifMatch);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await status('"${entry.version}"'), 200);
    expect(await status('*'), 200);
    expect(await status('"6:1"'), 412);
  });
}
