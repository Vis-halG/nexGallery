# Release, update and rollback

How to produce, publish and roll back nexGallery builds. The build commands
themselves are in [the product plan, §15](NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).

## Versions

- `pubspec.yaml` `version: X.Y.Z+N`. Flutter gives the split APKs version
  codes `1000+N` (ARM32) and `2000+N` (ARM64), so `N` stays below 1000 under
  this scheme.
- Every published build increases `N`. Android refuses to install a lower
  version code, so a rollback is a new build with the previous code and a
  higher `N`.
- Tag each release `vX.Y.Z` and keep its symbols (`build/symbols/`), SHA-256
  sums and installers.

## Android

1. Create the release keystore once and keep it outside Git (two offline
   copies). Write `android/key.properties`: `storeFile`, `storePassword`,
   `keyAlias`, `keyPassword`. Losing the key means users must uninstall to
   update.
2. Build the split APKs and the App Bundle without
   `allowDevelopmentSigning`. Check with `apksigner verify --print-certs` that
   the certificate is the release key.
3. Play: upload the bundle to internal testing, then staged production
   rollout (10% → 50% → 100%). Halting a staged rollout is the first rollback
   step; a fixed build with a higher version code is the second.
4. Direct APK downloads: publish both split APKs, the Universal fallback and
   `SHA256SUMS.txt`.

## Windows

1. `dart run tool/build_server.dart` builds the background agent; the
   Windows build copies it next to `nex_gallery.exe`.
2. `flutter build windows --release`, then
   `iscc /DAppVersion=X.Y.Z /DSign windows\installer\nexgallery.iss` with a
   configured `nexsign` SignTool (code-signing certificate with timestamping).
3. The installer is per user (no administrator rights). Installing a newer
   version upgrades in place and stops the agent first. To roll back, run the
   previous signed installer; catalogue and server data are kept.
4. Uninstalling removes the sign-in entry and asks before deleting
   `%LOCALAPPDATA%\nexGallery`. Photos and files are never removed.

## In-app updates (GitHub releases)

Every push to `main` runs `.github/workflows/release.yml`. It builds split
APKs signed with the release key, the Windows installer and `update.json`,
and publishes them as the GitHub release `build-<run number>`, marked latest.

- Builds from that workflow carry `NEXGALLERY_BUILD`, `NEXGALLERY_VERSION`
  and `NEXGALLERY_UPDATES=true`. A few seconds after start they read
  `https://github.com/Vis-halG/nexGallery/releases/latest/download/update.json`
  (Settings → App updates can turn this off), offer a newer build in a banner,
  download the file for the phone's ABI or the Windows installer, and check
  its size and SHA-256 before installing. Only URLs under this repository's
  `releases/download/` are accepted.
- Android opens its own installer; the first time it asks to allow
  nexGallery to install apps. It refuses an APK signed with another key.
- Windows runs the installer with `/SILENT`; it stops the background agent,
  upgrades in place and opens nexGallery again.
- Local builds and Play builds report "development build" and never check.

One-time setup on the PC (creates the key and the GitHub secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`):

```powershell
powershell -ExecutionPolicy Bypass -File tool\setup_release_signing.ps1
```

Keep the printed password and `Documents\nexGallery-signing\nexgallery-release.jks`
somewhere safe. Phones that installed a build signed with another key (for
example a local development build) must uninstall it once before installing a
release build.

## Release checklist

- [ ] `dart format --output=none --set-exit-if-changed lib test`,
      `flutter analyze`, `flutter test` (includes the 100,000-item budget).
- [ ] `dart run windows/server/test/remote_server_smoke_test.dart` and the
      compiled agent smoke test.
- [ ] Android integration tests on an emulator and on at least one ARM32 and
      one ARM64 phone across API 24, 29, 33 and 36.
- [ ] Packet capture of a pairing, a browse, an upload and a model download
      matches [privacy](PRIVACY.md).
- [ ] [Threat model](THREAT_MODEL.md) and [dependency audit](DEPENDENCY_AUDIT.md)
      reviewed for the release.
- [ ] Play declarations ([PLAY_DECLARATIONS.md](PLAY_DECLARATIONS.md)) still
      match the merged manifest.
- [ ] APK sizes within budget; signed artifacts and sums archived.

## Battery and power guidance (for the help page)

- **Indexing:** face, object and text analysis pauses when the phone is hot,
  low on memory, in battery saver, or below 20% without a charger. "Analyze
  only while charging" in Settings defers it to charging.
- **Transfers:** "Transfer on Wi-Fi only" is on by default. Camera backup runs
  while the app is open and connected; it is not a background service.
- **Video on mobile data:** with FFmpeg on the PC, phones play a 720p copy by
  default (Settings → PC videos on mobile data).
- **PC sleep:** the PC stays awake while a phone streams or transfers and for
  about 90 seconds afterwards. "Keep this PC available" stops it sleeping for
  as long as the server runs (the screen can still turn off). Windows shows
  these requests in `powercfg /requests`.
- **Wake-on-LAN:** "Wake PC" works only on the same network and only when the
  PC's BIOS and network adapter allow it.
