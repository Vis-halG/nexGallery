import 'dart:convert';
import 'dart:io';

/// Exports a CycloneDX inventory and checks exact resolved Pub/Maven versions
/// against OSV. Only public package names/versions leave the machine.
/// https://google.github.io/osv.dev/post-v1-querybatch/
Future<void> main(List<String> arguments) async {
  final deps = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'deps',
    '--json',
  ]);
  if (deps.exitCode != 0) {
    throw StateError('Cannot read resolved dependencies: ${deps.stderr}');
  }
  final graph = jsonDecode('${deps.stdout}') as Map;
  final components = <Map<String, Object?>>[];
  final queries = <Map<String, Object?>>[];
  for (final package in graph['packages'] as List) {
    if (package['source'] != 'hosted') continue;
    final name = package['name'] as String,
        version = package['version'] as String;
    components.add({
      'type': 'library',
      'name': name,
      'version': version,
      'purl': 'pkg:pub/$name@$version',
    });
    queries.add({
      'package': {'ecosystem': 'Pub', 'name': name},
      'version': version,
    });
  }
  final gradle = arguments
      .where((v) => v.startsWith('--gradle-report='))
      .firstOrNull;
  if (gradle != null) {
    final report = await File(gradle.substring('--gradle-report='.length))
        .readAsString();
    final coordinate = RegExp(
      r'([a-zA-Z0-9_.-]+):([a-zA-Z0-9_.-]+):([a-zA-Z0-9_.+-]+)(?: -> ([a-zA-Z0-9_.+-]+))?',
    );
    final seen = <String>{};
    for (final match in coordinate.allMatches(report)) {
      final group = match[1]!,
          artifact = match[2]!,
          version = match[4] ?? match[3]!;
      if (!seen.add('$group:$artifact:$version')) continue;
      components.add({
        'type': 'library',
        'group': group,
        'name': artifact,
        'version': version,
        'purl': 'pkg:maven/$group/$artifact@$version',
      });
      queries.add({
        'package': {'ecosystem': 'Maven', 'name': '$group:$artifact'},
        'version': version,
      });
    }
  }
  await Directory('build/security').create(recursive: true);
  await File('build/security/sbom.cdx.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'bomFormat': 'CycloneDX',
      'specVersion': '1.6',
      'version': 1,
      'metadata': {'timestamp': DateTime.now().toUtc().toIso8601String()},
      'components': components,
    }),
  );
  final findings = <Map<String, Object?>>[];
  for (var start = 0; start < queries.length; start += 100) {
    final batch = queries.sublist(
      start,
      (start + 100).clamp(0, queries.length),
    );
    // Use the system TLS/proxy transport consistently on Windows and CI.
    // Bounded retries tolerate transient API failures without skipping a
    // package or accepting an incomplete audit. No shell or insecure TLS.
    final requestFile = File('build/security/osv-request.json');
    await requestFile.writeAsString(jsonEncode({'queries': batch}));
    final response = await Process.run(
      Platform.isWindows ? 'curl.exe' : 'curl',
      [
        '--silent',
        '--show-error',
        '--fail',
        '--retry',
        '2',
        '--retry-all-errors',
        '--connect-timeout',
        '15',
        '--max-time',
        '60',
        '--header',
        'Content-Type: application/json',
        '--data-binary',
        '@${requestFile.path}',
        'https://api.osv.dev/v1/querybatch',
      ],
    );
    if (response.exitCode != 0) {
      throw StateError(
        'OSV transport failed; audit is incomplete. ${response.stderr}',
      );
    }
    final results =
        (jsonDecode(response.stdout as String) as Map)['results'] as List;
    if (results.length != batch.length) {
      throw const FormatException('Incomplete OSV response.');
    }
    for (var i = 0; i < results.length; i++) {
      final result = results[i] as Map;
      if (result['next_page_token'] != null) {
        throw StateError('OSV response needs pagination; audit is incomplete.');
      }
      final vulns = result['vulns'] as List? ?? const [];
      if (vulns.isNotEmpty) {
        findings.add({'query': batch[i], 'vulnerabilities': vulns});
      }
    }
  }
  await File('build/security/osv-results.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'checkedAt': DateTime.now().toUtc().toIso8601String(),
      'packages': queries.length,
      'findings': findings,
      'coverage': 'Resolved hosted Dart packages and supplied Maven report. Does not certify vendored C/C++ libraries, codecs or the Flutter engine.',
    }),
  );
  if (findings.isNotEmpty) {
    stderr.writeln(const JsonEncoder.withIndent('  ').convert(findings));
    exitCode = 1;
  } else {
    stdout.writeln(
      'PASS: ${queries.length} package versions checked against OSV. SBOM: build/security/sbom.cdx.json',
    );
  }
}
