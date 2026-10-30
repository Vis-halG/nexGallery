# Install once, then update in the app

Android APKs and the Windows installer are published at
https://github.com/Vis-halG/nexGallery/releases/latest after the release gates pass.
Choose ARM64 for most phones, ARM32 for older 32-bit Android, or Universal ARM
when unsure. Windows requires 64-bit Windows 10/11.

Release builds check at startup, and again after at least 30 minutes when the
app returns to the foreground. A new build opens an update dialog. Selecting
Update downloads the correct APK/installer, verifies its size and SHA-256,
flushes queued catalogue/settings writes, and starts installation. Android
requires the system install confirmation and, initially, permission to install
from nexGallery. Windows closes the app, upgrades in place, then reopens it.
The download is verified again immediately before installation.

Later hides that build's automatic offer. Settings > App updates > Check now
can show it again. Automatic checks can be turned off. Offline failures leave
the gallery usable and offer retry. A SHA-256 mismatch never launches an installer.

## One-time transition from the previous testing builds

The previously supplied 0.1.0 testing APK and Windows setup were built without
automatic update checks. Install the first update-enabled release manually once.
Future releases use the popup.

The old local Android APK used the development certificate; the release APK uses
the permanent nexGallery key. Android rejects an in-place update across those
certificates. Before switching, export albums/favorites in Settings and export
Locked Folder contents using its encrypted backup. Then remove the development
app, install the release APK and restore those backups. Original gallery media
is not removed by uninstalling nexGallery. App-private copies, cache, settings
and pairing credentials are removed, so save anything needed and pair with the
PC again. **Never uninstall before exporting private content you want to keep.**

The Windows installer upgrades the existing per-user installation and preserves
`%LOCALAPPDATA%\nexGallery`. It also preserves an existing background-server sign-in
choice while relocating the server's native-library bundle.

## Signing and publishing

`tool/setup_release_signing.ps1` creates the permanent Android key outside Git
and uploads it only to encrypted GitHub Actions secrets. It never prints the
password and saves a Windows-user-protected recovery password beside the key.
Keep an independent offline recovery backup. Do not replace the key after release.

Optional trusted Windows Authenticode signing uses the GitHub secrets
`WINDOWS_CERT_BASE64` and `WINDOWS_CERT_PASSWORD`. Without an owner-provided
certificate, the direct-download Windows installer remains unsigned; update
downloads still have verified SHA-256 and repository-restricted URLs. This is
not a claim of a trusted Windows publisher signature.

Push to main publishes only after analyzer/tests, performance, security audit,
real FFmpeg and native Android checks pass. Failed checks do not replace the
latest release. Each build includes the ARM APKs, Universal fallback, Windows
setup, checksums and `update.json`. The same Android key and increasing version
code are used for every subsequent update.
