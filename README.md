# nexGallery

Privacy-first Android and Windows gallery, local file manager and personal PC
server. The project is now an **active local-gallery prototype** following the
product plan. Phase 1 is in progress; it is not a production release.

The complete product scope, privacy boundaries, architecture, implementation
phases, APK-size strategy, device matrix and release process live in
[the product and build plan](docs/NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).
The [implementation status](docs/IMPLEMENTATION_STATUS.md),
[tech stack](docs/TECH_STACK.md), and
[verification record](docs/verification-2026-10-02.md) describe the current build.

## Working prototype

- Android MediaStore photos/videos and user-selected SAF folders.
- Windows folder indexing with saved roots and filename/type search.
- Timeline pages of 120 items, date grouping, and explicit Load more.
- Swipeable, zoomable screen-sized photo previews and local metadata.
- Device-player handoff for video and platform open/share actions.
- Virtual albums, favorites and archive backed by a local JSON catalogue.
- Disconnected/unreadable PC folders retain metadata and album membership.
- Incomplete scans preserve unseen entries; transfer staging files are excluded.

AI, vault encryption, editing, SQLite/FTS, stable file identity, filesystem
watching and production remote access remain planned. Windows Trash currently
hides entries in the catalogue; it does not move originals to the Recycle Bin.
Android native behavior still requires the documented OS/device verification.

The [development server](windows/server/README.md) supports loopback/opt-in LAN,
token pairing, range downloads and resumable uploads. Its plain HTTP transport
and token permission model do not meet the production remote-access design yet.

## Foundation targets

- Android 7.0+ (`minSdk 24`), ARM32 and ARM64.
- Windows 10/11 x64.
- One responsive Flutter interface with native platform adapters.
- No cloud media storage, advertising or analytics.
- Package ID `com.thenex.nex_gallery`.

## Run checks

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Run on an Android device with `flutter run -d <device-id>`. For Windows, install
Visual Studio's Desktop development with C++ workload, then run
`flutter run -d windows`. In Files, add a folder to index local PC files.

## Build small Android APKs

```powershell
flutter build apk --release `
  --split-per-abi `
  --target-platform android-arm,android-arm64 `
  --obfuscate `
  --split-debug-info=build/symbols/android `
  --android-project-arg=allowDevelopmentSigning=true
```

This explicit flag creates a non-publishable verification build. A publishable
release omits the flag and requires a private nexGallery keystore configured
through the ignored `android/key.properties`.
