# Local-gallery prototype verification — 2 October 2026

Scope: current working tree, version `0.1.0+1`. This is a development verification
record, not a production-release approval or a physical-device certification.

## Checks completed

| Check | Result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test` | Passed; no changes required |
| `flutter analyze` | Passed; no issues |
| `flutter test` | Passed; 24 tests |
| Android ARM split release build | Passed for ARM32 and ARM64 |
| `gradlew.bat -PallowDevelopmentSigning=true lintRelease` | Passed; 0 errors, 5 warnings retained in `build/app/reports/lint-results-release.txt` |
| `zipalign -c -P 16 4` | Passed for both split APKs |
| `apksigner verify --print-certs` | Both signatures valid; Android Debug development certificate |
| APK manifest/ABI inspection | Package `com.thenex.nex_gallery`, label `nexGallery`, minimum SDK 24, target/compile SDK 36, version `0.1.0`, matching split ABIs |
| Dart server integration script | All checks passed, including pairing, revocation, path restrictions, resumable upload, checksum failures, range downloads and recovery |
| Standalone server compile | Passed; `windows/server/build/nex_gallery_server.exe` |
| Compiled server smoke script | Health, pairing and authenticated roots passed |

The runtime regressions exercise 251-item paging, filter reset, folder disconnect
and reconnect with favorite/album preservation, cancelled/limited scans, staging
file exclusion and bounded aspect-preserving image decode. Widget coverage
includes swipe navigation, desktop keyboard navigation, live favorite state,
metadata, cached-library refresh, denied access, Load more, a 320×568 layout,
enlarged text and unavailable items in a dense grid.

## Development artifacts

Output directory: `build/app/outputs/flutter-apk/`.

| Artifact | Exact bytes | MiB | Version code |
| --- | ---: | ---: | ---: |
| `app-armeabi-v7a-release.apk` | 14,604,673 | 13.93 | 1001 |
| `app-arm64-v8a-release.apk` | 17,310,649 | 16.51 | 2001 |

Both splits are under the plan's 30 MiB guard. These APKs use development signing
and cannot be published as production releases. The foundation size table in the
product plan remains a historical baseline, not the size of this prototype.

SHA-256:

```text
eaff946f2bf25dd634c788577e4b7c2e40464610b52c291f1dcd4132f759524e  app-armeabi-v7a-release.apk
fcb107a2baca08a5541d520d40c512367fff605ef3e64bf5dc1272aeb2dc6eca  app-arm64-v8a-release.apk
```

Obfuscation symbols are retained in `build/symbols/android/`. The toolchain emits
an unobfuscated DWARF warning; strip/debug-information handling must be reviewed
before publishing signed release artifacts. Gradle also reports deprecated
features that require attention before a Gradle 10 upgrade.

## Workstation and unverified boundaries

- Flutter 3.47.4, Dart 3.13.3, Java 17 and Android build tools 36.1.0 were used.
- The native Windows Flutter app was not built or launched: `flutter doctor -v`
  reports that Visual Studio with Desktop development with C++ is missing. The
  standalone Dart server compilation is a separate successful check.
- No physical Android device was connected. Installation, MediaStore/SAF user
  consent, selected-photo changes, permission revocation, native codecs and OEM
  background behavior still need device validation.
- No 100,000-item performance, AI-quality, vault, encrypted remote-network or
  production signing claim is established by these tests.
- Only the two split APKs were rebuilt here; the Universal fallback and Play
  bundle were not generated in this continuation.

See [implementation status](IMPLEMENTATION_STATUS.md) for the remaining work
under each product-plan phase.
