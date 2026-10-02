# nexGallery

Privacy-first Android and Windows gallery, local file manager and personal PC
server. The project is currently at the **compilable foundation** stage; planned
features are not presented as implemented.

The complete product scope, privacy boundaries, architecture, implementation
phases, APK-size strategy, device matrix and release process live in
[the product and build plan](docs/NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).

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
