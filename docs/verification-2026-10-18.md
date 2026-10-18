# Verification — 18 October 2026

Scope: working tree at version `0.1.0+1` after the Phase 2-6 work. A
development record, not release approval or device certification.

## Checks

| Check | Result |
| --- | --- |
| `dart format --output=none --set-exit-if-changed lib test` | Passed |
| `flutter analyze` | No issues |
| `flutter test` | 202 tests passed, including the 100,000-item budget |
| `dart run windows/server/test/remote_server_smoke_test.dart` | All checks passed |
| `dart run tool/build_server.dart` | Built the console CLI and the GUI-subsystem agent |
| `dart run windows/server/test/compiled_exe_smoke_test.dart` | 13 checks passed: console approval; detached agent owner API over pinned TLS, wrong secret refused, approval, signed phone, shutdown, `agent.log` |
| Microsoft Defender scanner on this PC | Clean file → clean; missing file → unavailable (exit code 2 is not treated as a threat) |
| Android ARM split release build | Passed (development signing); zipalign `-P 16`, apksigner and badging checks as in CI passed |
| `gradlew :app:lintRelease` | 0 errors, 10 warnings (newer Media3, KTX style, fixed orientation, a v21 folder). CI now lints only the app module: `flutter_onnxruntime` 1.9.0 fails `NewApi` in its own module at its minSdk 21, which does not apply to the app's minSdk 24 |
| Android universal ARM build | Passed; 40.73 MiB, under the reviewed 45 MiB guard (see plan §12) |
| Android emulator (API 35) | `integration_test/native_android_smoke_test.dart` passed: MediaStore and thumbnails, native SQLite reopen with favorites and album, video decode/play/seek/speed, app startup. Manually checked: Settings "PC videos on mobile data", and Empty Trash → confirmation → system BiometricPrompt (screen-lock PIN) → Android delete consent → deleted |

## 100,000-item catalogue (this PC)

| Operation | Before this work | Now |
| --- | ---: | ---: |
| First sync | 26.6 s | 4.7 s |
| Unchanged rescan | 12.1 s | 0.9 s |
| One favorite | 11.75 s | 0.06 s |
| Add 10,000 items to an album | — | 0.19 s |
| First page / search | 40 / 88 ms | 46 / 75 ms |
| Reopen | 2.6 s | 2.5 s |

Causes fixed: every save re-verified and re-read the whole database, deleted
and rewrote every row, and ran a page-by-page backup; rescans replaced every
item object. Saves now write only changed rows (UPSERT keeps the full-text
index), verification runs at load, backups use `VACUUM INTO`, and unchanged
items keep their objects and first-indexed time.

## Android artifacts

Output directory: `build/app/outputs/flutter-apk/`. Native libraries are now
stored compressed and release builds drop unused x86/x86_64 plugin libraries.
Before that the splits were 44.5 MB and 54.7 MB and the Universal fallback
52.7 MB, over the guards, mostly because of ONNX Runtime (28.6 MB on ARM64).

| Artifact | Bytes | MiB |
| --- | ---: | ---: |
| `app-armeabi-v7a-release.apk` | 21,841,735 | 20.83 |
| `app-arm64-v8a-release.apk` | 23,009,895 | 21.94 |
| `app-release.apk` (universal ARM) | 42,705,719 | 40.73 |

SHA-256:

```text
c871936f70616f95cd60390ca6c1d630ff9cf7f59560ed7b6e86ad82f240b910  app-armeabi-v7a-release.apk
035b1e35036b1f92fb345667820b74f9f5ae9e5d5898663c9ba6e843b5263cca  app-arm64-v8a-release.apk
bf698a0085fb0aebd560ed421953468c281a364d6dc93ea8adb94e3a67e62837  app-release.apk
```

These use the development signing key and must not be published.

## Not verified here

- Native Windows app and installer: Visual Studio's C++ workload and Inno Setup
  are not installed; CI builds both.
- A real FFmpeg transcode (FFmpeg is not installed); the proxy pipeline ran
  with a substitute transcoder.
- Physical ARM phones, API 24-34 behaviour, OEM background limits and
  BiometricPrompt on real sensors.
- Tailscale across real networks, long transfers, and AI accuracy.
