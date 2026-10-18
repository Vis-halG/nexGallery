# nexGallery

Privacy-first Android and Windows gallery, local file manager and personal PC
server. Phases 1-5 of the product plan are implemented; this is a
development build that has not been released or signed.

The complete scope, architecture, device matrix and phases live in
[the product and build plan](docs/NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).
[Implementation status](docs/IMPLEMENTATION_STATUS.md),
[tech stack](docs/TECH_STACK.md) and
[latest verification](docs/verification-2026-10-18.md) describe the current build.
Security and release documents: [threat model](docs/THREAT_MODEL.md),
[privacy](docs/PRIVACY.md), [Play declarations](docs/PLAY_DECLARATIONS.md),
[release, update and rollback](docs/RELEASE.md) and
[dependency audit](docs/DEPENDENCY_AUDIT.md).

## What it does

- **Phone gallery:** MediaStore photos/videos and SAF folders, timeline,
  viewer, video player, albums, favorites, Archive, Trash, Memories, editing,
  Locked Folder and encrypted organization backups.
- **PC gallery:** chosen folders, drives and USB media with watchers; renamed or
  moved files keep their albums, favorites and face names.
- **Offline intelligence:** faces and People, text in photos, object labels,
  places, duplicates and similar photos, all on the device.
- **Personal PC server:** pairing by QR code with owner approval, per-phone
  permissions, signed requests, TLS pinned to the PC, background agent at
  Windows sign-in, LAN discovery, Tailscale for access away from home.
- **Transfers:** resumable phone-PC transfers, camera backup, offline copies,
  smaller video copies on mobile data (needs FFmpeg on the PC), Wake-on-LAN.
- **Safety:** read-only by default, version checks against silent overwrites,
  Defender scan before uploaded programs or archives appear, fingerprint/PIN
  before emptying Trash, DPAPI-protected PC secrets, audit log.

No account, cloud media storage, advertising or analytics.

## Install and update

Download the latest build from
[Releases](https://github.com/Vis-halG/nexGallery/releases/latest):
`nexGallery-…-arm64-v8a.apk` for most phones (`armeabi-v7a` for older ones)
and `nexGallery-…-windows-x64-setup.exe` for the PC. Every push to `main`
publishes a new release; installed apps show an "Update" banner and update
themselves (see [release](docs/RELEASE.md)).

## Targets

- Android 7.0+ (`minSdk 24`), ARM32 and ARM64.
- Windows 10/11 x64.
- One responsive Flutter interface with native platform adapters.
- Package ID `com.thenex.nex_gallery`.

## Run checks

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test                       # add --exclude-tags performance to skip the 100k budget
dart run windows/server/test/remote_server_smoke_test.dart
dart run tool/build_server.dart
dart run windows/server/test/compiled_exe_smoke_test.dart
```

Run on an Android device with `flutter run -d <device-id>`. For Windows, install
Visual Studio's Desktop development with C++ workload, run
`dart run tool/build_server.dart` (the background agent), then
`flutter run -d windows`.

## Build small Android APKs

```powershell
flutter build apk --release `
  --split-per-abi `
  --target-platform android-arm,android-arm64 `
  --obfuscate `
  --split-debug-info=build/symbols/android `
  --android-project-arg=allowDevelopmentSigning=true
```

This flag creates a non-publishable verification build. A publishable release
omits it and requires a private nexGallery keystore configured through the
ignored `android/key.properties` (see [release](docs/RELEASE.md)).

## Build the Windows installer

```powershell
dart run tool/build_server.dart
flutter build windows --release
iscc /DAppVersion=0.1.0 windows\installer\nexgallery.iss
```

The installer is per user and needs no administrator rights. CI builds an
unsigned development installer; releases are signed (see
[release](docs/RELEASE.md)).
