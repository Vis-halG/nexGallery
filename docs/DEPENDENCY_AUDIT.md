# Dependency audit — 29 October 2026

The current verification runs `dart run tool/security_audit.dart`. It creates a
CycloneDX inventory and queries exact resolved Pub versions against OSV. The
local audit checked 76 hosted package versions with no findings at that time.
Release CI also supplies `releaseRuntimeClasspath` Maven coordinates. Network
errors, incomplete responses or findings fail the audit rather than reporting
success. Results are timestamped in `build/security/` and archived by release CI.

This is package-level coverage, not proof that every vendored native codec,
ONNX build or Flutter engine binary is free of vulnerabilities. The earlier
manual dependency review below remains historical context.

New dependencies/data: Flutter SDK `flutter_localizations` and its pinned `intl`
dependency (BSD-3-Clause), and public-domain Natural Earth land polygons used
entirely offline. The core APK does not download map tiles.
Android background scheduling adds AndroidX WorkManager 2.12.0 (Apache-2.0).
The 30 October resolved Pub/Maven audit checked 173 package versions. It found
GHSA-xxph-c9ww-hj94 in transitive Guava 33.3.1-android; explicitly selecting
33.7.2-android fixes it, and the repeated audit completed with zero findings.
Upstream fix: https://github.com/google/guava/releases/tag/v33.7.2.
The audit uses the system curl TLS/proxy transport with bounded retries;
connection errors and incomplete responses still fail the gate.

Flutter 3.47.4, Dart 3.13.3. Run again before each release:
`flutter pub outdated`, `flutter pub deps --no-dev`, and a review of new
native dependencies in `android/app/build.gradle.kts` and the Windows runner.

## Changes made in this audit

`flutter pub upgrade` within the existing constraints; the full test suite,
analyzer and server smoke tests passed afterwards.

| Package | Before | After |
| --- | --- | --- |
| sqlite3 (bundles the SQLite engine) | 3.5.2 | 3.7.1 |
| archive (ZIP create/extract) | 4.3.0 | 4.5.2 |
| image (decoding untrusted images) | 4.10.1 | 4.12.0 |
| video_player / video_player_win | 2.14.0 / 3.3.0 | 2.14.1 / 3.3.1 |
| code_assets, native_toolchain_c, objective_c, vector_math, video_player_avfoundation, vm_service | older patch/minor | latest compatible |

`ffi` (2.2.0) and `fake_async` (dev, 1.3.3) became direct dependencies; both
were already in the lock file transitively.

## Direct dependencies

| Package | Version | Licence | Why |
| --- | --- | --- | --- |
| sqlite3 | 3.7.1 | MIT (SQLite: public domain) | Catalogue database |
| video_player | 2.14.1 | BSD-3-Clause | Android/iOS playback (ExoPlayer) |
| video_player_win | 3.3.1 | BSD-3-Clause | Windows playback (Media Foundation) |
| archive | 4.5.2 | MIT | ZIP files, backups |
| basic_utils | 5.8.2 | MIT | Self-signed TLS certificate generation |
| cryptography | 2.9.0 | Apache-2.0 | Ed25519 device keys, AES-GCM vault, PBKDF2 |
| ffi | 2.2.0 | BSD-3-Clause | Windows file IDs, DPAPI, power requests |
| flutter_onnxruntime | 1.9.0 | MIT | Optional face/object/text models |
| image | 4.12.0 | MIT | Thumbnails, editing, perceptual hashes |
| path | 1.9.1 | BSD-3-Clause | Path handling |
| qr | 4.0.0 | BSD-3-Clause | Pairing QR code |

Android native: androidx.media3 transformer/effect 1.9.2 (Apache-2.0, video
tools), zxing-android-embedded 4.3.0 (Apache-2.0, QR scanning). Optional model
licences are in [third-party](third-party/).

## Findings

- No advertising, analytics, crash-reporting, Firebase or cloud-storage SDKs
  are present in the Dart or Android dependency graph.
- Packages with newer versions outside the current constraints are only
  transitive Flutter SDK pins (`material_color_utilities`, `test_api`).
- `pointycastle` (via basic_utils) is used only to create the PC certificate;
  TLS itself is the Dart VM's BoringSSL.
- `flutter pub outdated --json --show-all` lists 82 resolved packages; none is
  affected by a pub.dev security advisory, retracted or discontinued.
- Not covered: a CVE scan of the bundled native libraries (ONNX Runtime,
  ExoPlayer/Media3, Flutter engine). Add an SBOM scan (for example OWASP
  Dependency-Check on the Gradle build) to the release pipeline.
