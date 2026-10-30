# nexGallery ? Complete Product and Build Plan

Historical product target; status updated 29 October 2026. The
Flutter app uses a versioned SQLite catalogue, Android MediaStore/SAF, Windows
selected folders/watchers, paged media views, integrated local playback and
settings. Native validation and production release readiness are separate from
feature implementation. The full six-phase product scope below remains the target.
See [implementation status](IMPLEMENTATION_STATUS.md),
[the current stack](TECH_STACK.md), and
[latest verification](verification-2026-10-29.md) for implemented boundaries.

| Area | Implemented foundation | Remaining product work |
| --- | --- | --- |
| Shared app | Paged timeline, viewer/player, 100k performance, English/Hindi UI, optional catalogue encryption | Manual accessibility review and additional languages |
| Android | MediaStore/SAF permissions, gallery/file tools, signed updates, scheduled WorkManager backup/transfer handoff, encrypted offline copies, native emulator checks | Physical-device/OEM battery matrix |
| Windows | Scans/watchers, stable file identity, packaged background agent, installer and updates | Trusted signing certificate and manual device review |
| Organization | Albums/favorites/archive, recoverable Trash, editing/vault/memories and encrypted organization backup | Device certification and recovery drills |
| Remote access | Owner approval, device keys/scopes, pinned TLS, resumable transfers, paged catalogue and delta feed | Real-network/long-duration certification and encrypted offline media cache |
| Offline intelligence | Optional verified models, People corrections, OCR/places/cleanup and offline map | Labelled real-library recognition-quality evaluation |

## 1. Product definition

nexGallery is a privacy-first gallery and file manager for Android and Windows.
It combines three experiences:

1. **This Phone** — all user-accessible photos, videos, audio, documents, APKs,
   archives and folders on the Android device.
2. **My PC** — encrypted remote access to folders and drives explicitly shared
   by the user's Windows PC.
3. **All Files** — unified search and browsing with a visible `Phone` or `PC`
   source badge on every result.

Original media remains on the device where it is stored. nexGallery has no
third-party media-storage backend, advertising SDK or analytics SDK. Remote
viewing and user-authorized backup necessarily transfer encrypted bytes between
the paired PC and phone, but nexGallery does not store those files in its own
cloud. A private-network relay may forward ciphertext when a direct connection
is unavailable; it cannot decrypt the content.

“Full control” means control of user-authorized personal folders. It never means
remote command execution or unrestricted access to Windows system folders,
credentials, other users' profiles or Android app sandboxes.

## 2. Supported platforms

### Android

- Android 7.0 / API 24 through API 36 is the defined build and test range.
- Newer Android versions are evaluated for each release before support is claimed.
- `armeabi-v7a` for 32-bit Android devices.
- `arm64-v8a` for 64-bit Android devices.
- Phone and tablet responsive layouts.
- Package ID: `com.thenex.nex_gallery`.

The installed Flutter 3.47.4 toolchain officially uses API 24 as its minimum.
API 23 is outside this toolchain's supported range. Supporting Android 6 would
require a separate legacy Flutter branch and older dependencies, which would
increase maintenance and security risk.

Named physical-device validation targets:

| Device | Expected baseline | Required artifact | Specific checks |
| --- | --- | --- | --- |
| Realme 1 | Android 8.1+ | Matching ARM split | Media permission, low-memory indexing, background limits |
| Realme 3 | Android 9+ | Matching ARM split | SD card, battery manager, transfer resume |
| Nokia 7.2 | Android 9+ | ARM64 preferred | Large-library scroll, video seek, biometric vault |
| Vivo Y3s | Android 10+; some installations may use 32-bit userspace | ARM32 and ARM64 must both be published | Install correct ABI, OEM background killing, low storage |

No software can honestly guarantee every Android model. The release promise is
a published API/ABI matrix, automated coverage and named physical-device tests.
Android x86/x86_64 hardware and ChromeOS are not release targets yet; x86_64 is
used only for emulator tests.

Android storage access by OS version:

| Android version | Planned access path |
| --- | --- |
| API 24-28 | Runtime `READ_EXTERNAL_STORAGE`; writes only after the required runtime/user authorization |
| API 29-32 | MediaStore and scoped storage; `READ_EXTERNAL_STORAGE` only where the OS requires it |
| API 33+ | Granular `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` and `READ_MEDIA_AUDIO` requests only for selected features |
| API 34+ | Selected Photos Access is supported when the user grants only chosen media |
| All supported APIs | SAF for user-selected documents/folders; `ACCESS_MEDIA_LOCATION` requested only when original EXIF location is needed |

Optional all-files mode uses `MANAGE_EXTERNAL_STORAGE` only in a separately
reviewed file-manager distribution and remains subject to store policy.

### Windows

- Windows 10 and Windows 11 x64 first.
- Responsive Flutter desktop UI.
- A separate per-user `NexGallery Server` agent so remote access can remain
  available while the desktop window is closed and retain access to that user's
  selected folders, mapped drives and removable media.
- Windows ARM64 is a later target after its native dependencies are verified.

## 3. Android gallery and file features

### Photos and videos

- Day, month and year timeline.
- Pinch-to-change grid density.
- Camera, Screenshots, WhatsApp, Downloads, Selfies, Portraits, Documents,
  GIFs, Videos and Recently Added categories.
- Folder and album views.
- Full-screen photo viewer with zoom, swipe and metadata.
- Video player with seek, speed, subtitles where present and resume position.
- Favorites, Archive and recoverable Trash.
- Slideshow and set-as-wallpaper actions.
- EXIF date, camera, dimensions, orientation and GPS details.
- User-approved correction of date/time, timezone and location metadata, with
  sidecar/copy fallback when safely rewriting the original format is unsupported.
- Memories generated locally from dates, people, places and albums.
- Map and location timeline using an offline location database by default.
- Photo stacks for bursts and visually similar shots.
- Direct Android share/open-with and optional cast-to-TV support through platform
  APIs; casting is local-network functionality and is always user initiated.
- Compatibility probes for JPEG, PNG, WebP, GIF, HEIF/HEIC, AVIF, RAW/DNG and
  motion photos. Unsupported codecs show metadata and an explicit reason rather
  than failing silently; exact decode/edit support follows each device codec.

### Files

- Images, videos, audio, PDFs, text/documents, APKs and archives.
- Folder creation, rename, copy, move and share.
- ZIP creation and extraction.
- Sort by name, date, size and type.
- Storage usage by category and folder.
- Large-file and old-download cleanup suggestions.
- SD card and removable-storage awareness.

Android MediaStore supplies normal photo/video/audio access. The Storage Access
Framework supplies user-selected document/folder access. Full device file-manager
mode requires `MANAGE_EXTERNAL_STORAGE`, a clear user explanation and Google
Play approval. Even that permission cannot expose another app's private sandbox
and Android may restrict parts of `Android/data` and `Android/obb`.

### Albums and organization

- Virtual albums that do not move originals.
- Optional physical folders when the user deliberately chooses Move.
- Album cover selection and album search.
- Add/remove many items at once.
- Person, place and category suggestions.
- Import/export album definitions as an encrypted local backup.

### Editing

- Non-destructive crop, rotate, flip and straighten.
- Brightness, contrast, saturation, warmth and filters.
- Markup, text and simple drawing.
- Collage, animation and short highlight-video creation from selected media.
- Save a new copy by default; explicit overwrite only after confirmation.
- Video trim, rotate, mute and compression.
- Platform codecs preferred over a bundled FFmpeg build to reduce APK size.

## 4. Offline intelligence

All analysis happens on the device holding the original media. Derived indexes
are local and resettable.

### People and same-face grouping

1. Detect faces in a downscaled image.
2. Reject unusably small, dark or extreme-angle crops.
3. Produce a compact face embedding with a commercially usable, quantized
   on-device model.
4. Cluster similar embeddings locally.
5. Let the user name, merge, split, hide or reset groups.
6. Keep user corrections during incremental rescans.

Face detection alone does not identify a person across separate photos. Identity
grouping therefore requires the embedding and clustering stages. Results can be
wrong for twins, children changing with age, masks, side profiles and low-light
photos; manual correction is a required product feature.

### Search and categories

- OCR for Latin and Devanagari text in photos, screenshots and documents.
- Search by filename, folder, date, type, size, duration, album and favorite.
- Search by person name and face group.
- Object/scene labels such as dog, car, beach, food, birthday and document.
- Places from EXIF GPS when the user grants precise media-location access.
- Combined filters such as “Vishal in Mumbai in 2025” or “large videos on PC”.
- Full-text index for filename, OCR and labels.
- Local vector index for face and visual similarity.

Online map tiles contact a map provider. The privacy-first default will use an
offline location database/map pack; online maps can only be an explicit option.

### Cleanup

- Exact duplicates using staged hashes.
- Visually similar photos using perceptual hashes/embeddings.
- Burst grouping and best-shot suggestions.
- Blurry, dark or accidental-image suggestions.
- Old screenshots, duplicate downloads and large-video review.
- Suggestions never delete automatically.

### Indexing behavior

- Quick first pass reads metadata and shows the timeline immediately.
- Background batches later generate thumbnails, OCR, labels and faces.
- Only new or changed items are reprocessed.
- Pause/resume and visible progress controls.
- Charging/idle constraints for heavy AI work.
- One AI worker and smaller batches on low-RAM devices.
- Paging and thumbnail-sized decoding for libraries of 100,000 items.

## 5. Locked Folder

A true vault moves the selected item into encrypted app-private storage; merely
hiding a shared MediaStore file would leave it visible to other gallery apps.

- AES-GCM encrypted contents.
- Non-exportable key protected by Android Keystore or Windows secure storage.
- Strong biometric or device credential unlock.
- Auto-lock on background and configurable timeout.
- No thumbnail leakage into the normal gallery/cache.
- Explicit encrypted export/recovery flow.
- Clear warning: uninstalling without a recovery export can remove app-private
  vault data permanently.

## 6. Windows gallery and server

### Local desktop gallery

- User chooses Pictures, Downloads, Documents, complete personal drives,
  external HDDs, USB media and SD cards.
- A quick scan builds the first timeline.
- A filesystem watcher and periodic reconciliation process changes.
- Move/rename identity uses Windows file ID and content hash so albums and face
  names survive.
- A disconnected drive is marked unavailable, never silently deleted.
- Originals remain in their existing folders.

### Local data

- SQLite WAL catalogue for items, albums, people, devices, permissions,
  transfers, scan checkpoints and audit records.
- FTS index for filenames, OCR and labels.
- Local vector sidecar for face/object similarity.
- Replaceable LRU thumbnail/video-proxy cache.
- Daily database backup; originals remain the source of truth.

### Background server agent

- Planned as a Dart AOT `nexgallery_server.exe` so protocol, models and transfer
  code can be shared with the Flutter application.
- Starts at user sign-in only after the user enables Remote Access. A later
  Windows-service mode must define a dedicated account and folder ACLs before it
  can run before login.
- Keeps serving while the nexGallery desktop window is closed.
- Runs with the signed-in user's token and never asks for administrator rights
  for ordinary browsing or transfer operations.
- Uses an authenticated Windows named pipe for UI/agent control; the remote API
  is never exposed through that pipe.
- Exposes only configured roots.
- Never exposes SMB, RDP, a shell or a raw filesystem path API.
- Ships with the signed Windows installer, uninstalls its startup registration
  cleanly and preserves or removes its catalogue according to the user's choice.

## 7. Anywhere internet access

The first production transport will use a private Tailscale/WireGuard network.
It handles changing IP addresses and CGNAT without exposing a public router port.
Connections are direct peer-to-peer where possible and use an end-to-end
encrypted relay fallback where necessary.

Version 1 requires the official Tailscale client on both phone and PC and both
devices signed into the same user-controlled tailnet. Tailscale enrollment is a
separate prerequisite; the nexGallery QR code below grants app permissions only.
Embedding a userspace tunnel may be evaluated later after licensing, account,
update and recovery behavior is reviewed.

The nexGallery API still authenticates every device inside that encrypted
network using device keys and a mutually authenticated session. Network
membership alone is insufficient authorization. The server binds only to the
tailnet address and loopback; Windows Firewall denies public/LAN interfaces
unless the user separately enables a reviewed LAN-only mode.

### Pairing

1. PC displays a single-use QR code with a two-minute expiry.
2. Phone scans it and creates a device key in Android Keystore.
3. PC displays the phone identity and requires an explicit **Approve** action.
4. PC stores only that device's public identity and selected permissions.
5. The paired phone uses short-lived sessions and replay-resistant requests.
6. PC can revoke a device immediately.

### Device permissions

- View thumbnails and metadata.
- Stream originals.
- Download to phone / Keep offline.
- Upload phone files to PC.
- Create folders; rename, copy and move files/folders.
- Create and extract ZIP archives within an authorized root.
- Open/share a downloaded local copy through Android's secure content provider.
- Delete through Windows Recycle Bin when the volume supports it, otherwise
  move to an app-managed trash inside that authorized root. If neither recovery
  path is possible, remote permanent delete is refused.
- Per-folder and per-album scopes.

Remote access is read-only by default. Write access requires explicit PC opt-in.
Destructive bulk operations require biometric or device-credential/PIN
re-authentication and confirmation.

### Remote API

- Cursor-paged timeline, folders, albums, people and search.
- Opaque item IDs; clients never submit arbitrary Windows paths.
- Screen-sized cached image previews.
- HTTP byte-range streaming for compatible video/audio seek and resume.
- Optional PC-side adaptive 360p/720p/1080p video proxy for slow connections.
- Delta change feed for new, moved, renamed and deleted items.
- ETags/version checks to prevent silent concurrent overwrites.

The server canonicalizes every path and rejects `..`, junction, symlink,
reparse-point and alternate-stream escapes outside an approved root.

## 8. Phone-to-PC and PC-to-phone transfers

### Phone to PC

- Select any accessible file or complete folder.
- Select the authorized PC destination.
- Create the destination folder, rename/move existing items, and create/extract
  ZIP archives when that paired device has the required write scope.
- Optional Camera folder auto-backup.
- Wi-Fi-only, charging-only, mobile-data and schedule controls.
- Pause, resume, cancel and automatic retry.
- `Replace`, `Keep both` and `Skip` conflict choices.

### PC to phone

- Stream without saving.
- Download to encrypted app-private cache.
- Keep selected items offline.
- Export to Android public storage after an explicit warning that a public copy
  can no longer be remotely revoked.

### Transfer integrity

- Chunked and resumable transport.
- Write into a `.part` staging file.
- Verify length and cryptographic hash.
- Atomically rename only after complete verification.
- Never index partial files.
- Quarantine executable/archive uploads until Windows Defender or the configured
  scanner has checked them; nexGallery never executes a remotely uploaded file.

## 9. Phone and PC user experience

- Android uses `Photos`, `Library`, `My PC` and `Files` as primary destinations.
- Windows uses `This PC`, `Library`, `Server`, `Devices`, `Transfers` and
  `Settings`; it does not label the local machine as `My PC`.
- Every remote item carries a `PC` badge and every local item a `Phone` badge.
- Unified search merges results without hiding their source.
- Online, Connecting, Waking, Offline and Drive unavailable states.
- Transfer centre with speed, remaining bytes, pause, retry and error details.
- Paired-devices screen with name, last seen, permissions, bytes transferred and
  one-tap revoke.
- Local PC audit log for pairing, failed login, upload, download, rename, move,
  delete and permission changes. Search terms and ordinary thumbnail views are
  not logged by default.

Version 1 treats the phone as a client and upload/backup source. Browsing the
phone live from the PC is deferred because Android cannot reliably serve files
in the background under Doze; phone-to-PC backup remains push based.

### UX principles

- The default screen opens directly to local photos without an account wall,
  promotion carousel or advertisement.
- Privacy and file location stay visible. `Phone`, `PC`, `Offline copy` and
  connection-status labels use text/icons as well as color.
- Common actions remain one tap away; advanced file/server controls use
  progressive disclosure so the normal gallery stays calm.
- Every destructive action explains what will happen, prefers recoverable Trash
  and offers Undo where recovery is possible.
- Planned or unavailable features carry an explicit status. A checkmark is used
  only for a completed action, never for a roadmap item.
- Material 3, system typography/icons and code-only surfaces provide a consistent
  premium visual system without fonts, Lottie or large artwork in the APK.
- A single calm violet accent, tonal surfaces and limited motion work in light,
  dark and high-contrast environments.

### Android interaction model

- Four bottom destinations: `Photos`, `Library`, `My PC` and `Files`.
- Photos uses a date-grouped lazy grid, fast date scrubber, pinch grid density,
  full-screen swipe viewer and long-press multi-select with contextual actions.
- Library exposes Albums, People, Places, Videos, Screenshots, Documents,
  Memories, Duplicates and Cleanup. AI sections say `Processed on this device`.
- My PC first-run flow has three steps: install/start the PC server, scan the QR
  code and approve the phone on the PC. It always shows online/offline state,
  source, last seen and transfer queue.
- Files supports Phone/PC filters, breadcrumbs, list/grid choice, sort and safe
  multi-select. Remote write actions are hidden until the device has permission.
- Active transfer notifications have Pause/Resume/Cancel; mobile-data use shows
  the expected file size before an original-quality download or stream.

### Windows interaction model

- Destinations: `This PC`, `Library`, `Server`, `Devices`, `Transfers` and
  `Settings` in a persistent sidebar.
- Keyboard navigation, visible focus, shortcuts, right-click menus, drag/drop,
  hover feedback and resizable grid density are first-class interactions.
- A details/preview pane is optional and remembers width. Narrow windows collapse
  secondary panes without hiding the primary action.
- Server shows allowed roots, listening state, paired devices, permissions and
  recent security events without requiring the gallery window to stay open.

### States and recovery

Every feature defines loading, empty, permission-denied, partial-access, error,
offline and success states before implementation. Each blocking state offers one
clear next action, for example `Choose photos`, `Choose folder`, `Retry`,
`Resume transfer` or `Open PC setup`. Indexing shows completed/total work and a
Pause control. Cached PC metadata is visibly stale while the PC is offline.

### Accessibility and responsive quality

- Interactive targets are at least 48 dp on Android and remain keyboard reachable
  on Windows.
- Text supports 200% scaling without clipping; layouts reflow instead of reducing
  font size. Contrast is at least 4.5:1 for normal text.
- TalkBack/Narrator names, roles, values and live progress announcements are
  included. Meaning never depends on color alone.
- Reduced-motion settings disable decorative transitions; media autoplay is off
  by default.
- Adaptive checks cover 320x568, 360x640, 600/840 breakpoints, 1024x768 and
  1440x900, plus dark theme, large text, RTL and keyboard-only use.

### UI performance budget

- Real media grids use builder delegates, database paging, thumbnail-sized decode
  (`cacheWidth`/`cacheHeight`) and bounded prefetch instead of full originals.
- Feature tabs initialize lazily. Inactive video players, image decoders and
  background controllers are disposed so 2-3 GB devices remain usable.
- Scrolling targets a steady 60 fps on the named low-end phones. Navigation and
  selection feedback appear immediately even while indexing continues.
- Desktop content is width constrained for readability; large windows add useful
  columns or panes rather than stretching text and cards edge to edge.

## 10. PC power and failure behavior

- PC must be powered, online and awake for remote access.
- Active streaming/transcoding temporarily prevents sleep.
- Optional “Keep PC available” power setting.
- Wake-on-LAN requires compatible BIOS/NIC settings and an always-on device on
  the home network, such as a router, NAS or Raspberry Pi wake agent.
- A relay cannot reliably wake a fully powered-off PC behind normal NAT.
- If remote access fails, the phone shows cached metadata and pinned offline
  items; it never pretends the PC is online.
- Interrupted transfers resume from a verified byte offset.
- Missing drive/permission marks items unavailable while preserving metadata.
- Storage-full conditions stop derivatives/transfers without touching originals.
- A corrupt local index can be restored or rebuilt from originals.

## 11. Required privacy and security guarantees before release

- No nexGallery cloud media storage.
- No Firebase, Cloudinary, advertising or analytics SDK.
- Internet permission exists because remote PC access is a core feature.
- No silent phone-to-PC backup; automation is opt-in and visible.
- Device-specific cryptographic identity and immediate revocation.
- Android secrets in Keystore; Windows secrets in DPAPI/TPM-backed storage where
  available.
- Catalogues, face embeddings, OCR text, labels, thumbnails and video proxies
  are sensitive derived data. They stay in app-private directories protected by
  OS ACLs; vault/offline-cache contents are encrypted at rest, and optional
  catalogue encryption is enabled for high-security mode.
- Cache limits and retention are user visible. `Clear cache` removes replaceable
  derivatives, while `Reset local intelligence` deletes face/OCR/object indexes
  on Android and Windows without deleting originals.
- Deny-by-default private-network policy restricted to the server port.
- Public SMB, RDP, UPnP and direct HTTP exposure prohibited.
- Rate limiting, timeouts, nonce/replay protection and key rotation.
- Signed application updates and dependency/security review.
- Signing keys, databases, thumbnails, tokens and personal media never enter Git.
- Optional model packs come only from an allowlisted, licensed source, carry a
  signed manifest and hash, support rollback/revocation and never contain user
  media or derived user data.

Tailscale or another coordination provider can observe operational device and
connection metadata. A relay may forward encrypted WireGuard packets. The product
promise is “no cloud file storage and end-to-end encrypted remote media,” not
“no third party participates in connection setup.”

## 12. APK-size strategy

A small base APK and every large AI model bundled for first-launch offline use
conflict with each other. nexGallery uses a measured two-tier plan:

Foundation baseline measured on 2 October 2026 with Flutter 3.47.4, R8/resource
shrinking, Dart obfuscation and tree-shaken icons:

| Development-signed artifact | Exact bytes | MiB |
| --- | ---: | ---: |
| ARM32 `app-armeabi-v7a-release.apk` | 12,174,133 | 11.61 |
| ARM64 `app-arm64-v8a-release.apk` | 15,043,949 | 14.35 |
| Universal ARM `app-release.apk` | 26,837,947 | 25.59 |

These are download-file sizes for the foundation UI, not installed sizes and
not the final functional app. They must not be published because the current
local/CI fallback uses a development signing key. CI enforces a 30 MiB ceiling
for each split APK and a 45 MiB ceiling for the Universal fallback as early
regression guards; the targets remain below those ceilings and are reviewed when
each native dependency or optional model is added.

Review on 18 October 2026 after adding the on-device inference runtime (ONNX
Runtime, 28.6 MB uncompressed on ARM64): native libraries are now stored
compressed and release builds drop x86/x86_64 plugin libraries. The splits
measured 21,841,735 bytes (ARM32, 20.83 MiB) and 23,009,895 bytes (ARM64,
21.94 MiB); the Universal fallback measured 42,705,719 bytes (40.73 MiB), so its
ceiling moved from 40 to 45 MiB. Model files themselves remain optional
downloads.

### Small core APK

- Separate `armeabi-v7a` and `arm64-v8a` APKs.
- Optional larger Universal ARM APK only as a fallback.
- Android App Bundle for Play so Play delivers device-specific resources.
- R8 code minification and Android resource shrinking.
- Dart obfuscation and stripped debug symbols, archived separately per version.
- System font and vector/material icons; no bundled decorative font family.
- Android platform codecs and thumbnail APIs.
- No Firebase, analytics, FFmpeg/VLC or duplicated native runtimes in the core.
- Optimized WebP/vector assets and no unnecessary density/language bundles.

### Optional intelligence packs

- Quantized face-embedding, OCR-script and visual-search models.
- Signed model manifest with SHA-256 verification.
- Downloaded only after clear user consent; user media is never uploaded.
- Core timeline, files, albums and remote access work without a model pack.
- A later larger `Offline Full` artifact may bundle verified models for users who
  prefer first-launch offline intelligence over download size.

CI records every APK's byte size and fails when a split exceeds the current
30 MiB foundation ceiling. A tighter functional-core budget will be fixed after
the first scanner prototype; optional AI packs stay outside the base APK.

## 13. Source structure

The foundation starts as one Flutter repository. It will grow into these clear
modules instead of one large controller/UI file:

```text
lib/
  core/                 theme, errors, routing, privacy settings
  features/
    photos/             timeline and viewer
    library/            albums, people, places and memories
    files/              local and remote file manager
    my_pc/              pairing, remote browsing and transfers
    search/             metadata, OCR and semantic search
    vault/              Locked Folder
  data/
    android_media/      MediaStore and SAF adapter
    windows_files/      scanner and watcher adapter
    local_db/           catalogue, FTS and migrations
  services/
    indexer/            incremental jobs and checkpoints
    offline_ai/         face/OCR/object model boundary
    transfer/           authenticated resumable protocol
windows/server/         restricted background service
docs/                   plans, threat model and release verification
test/                   unit/widget/integration tests
```

## 14. Implementation phases

### Phase 1 — foundation

- Shared theme, navigation, error handling and settings.
- Local database schema and migrations.
- Android MediaStore scan and Windows selected-folder scan.
- Paged timeline, folders, viewer/player and metadata.
- Permission-denied and partial-access states.

### Phase 2 — local organization

- Albums, favorites, archive, trash and memories.
- Copy/move/rename/share and recoverable delete.
- Files categories and Storage Access Framework.
- Photo editor and basic video tools.
- Locked Folder and encrypted recovery export.

### Phase 3 — offline intelligence

- Face detector, embeddings, clustering and People corrections.
- OCR and full-text search.
- Object/scene labels and combined filters.
- Places, duplicates, similar-photo and cleanup review.
- Low-RAM, thermal and charging constraints.

### Phase 4 — Windows server and LAN

- Restricted per-user background server agent.
- Selected-root permission model.
- QR pairing and app-level device identity.
- LAN discovery, paged search, thumbnails and range streaming.
- Local audit log and device revocation.

### Phase 5 — internet and transfers

- Tailscale/WireGuard setup wizard and deny-by-default network policy.
- Direct/relay connection status.
- Resumable phone-to-PC and PC-to-phone transfers.
- Offline phone cache and mobile-data quality controls.
- Adaptive video proxy and hardware acceleration where available.
- Optional camera backup and Wake-on-LAN agent.

### Phase 6 — hardening and release

- Threat model, penetration tests and dependency audit.
- 100,000-item performance and long-transfer testing.
- Android/Windows signed installers, update and rollback paths.
- Accessibility, localization and battery guidance.
- Play permission declarations and store/privacy documentation.

## 15. Build and release process

### Required toolchain

- Flutter 3.47.4 / Dart 3.13.3.
- Java 17.
- Android compile/target SDK 36.
- Android min SDK 24.
- NDK 28.2.13676358.
- Windows 10/11 with Visual Studio C++ desktop tooling.

### Clone and workstation setup

```powershell
git clone https://github.com/Vis-halG/nexGallery.git
cd nexGallery
flutter doctor -v
flutter doctor --android-licenses
flutter pub get
flutter run -d windows
```

Connect an Android device with USB debugging enabled, then use
`flutter run -d <device-id>` for a device build. The Windows release build needs
Visual Studio with **Desktop development with C++**; Android-only contributors
do not need Visual Studio.

### Local validation

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build windows --release
```

The development server core can already be compiled with:

```powershell
dart compile exe windows/server/bin/nex_gallery_server.dart `
  -o windows/server/build/nex_gallery_server.exe
```

This builds the current CLI server; the per-user background agent and named-pipe
UI control specified in Phase 4 remain planned.

### Release signing

- Android developers copy `android/key.properties.example` to the ignored
  `android/key.properties` and point it at a private upload keystore.
- CI restores the keystore and four signing values only from encrypted GitHub
  Actions secrets for a protected release workflow.
- Ordinary branch CI artifacts remain clearly named `development-signed` and
  can never be attached to a public release.
- The Windows installer and `nexgallery_server.exe` use the same trusted code
  signing identity; the certificate/PFX and password stay outside Git.

### Small Android split APKs

```powershell
flutter build apk --release `
  --split-per-abi `
  --target-platform android-arm,android-arm64 `
  --obfuscate `
  --split-debug-info=build/symbols/android `
  --android-project-arg=allowDevelopmentSigning=true
```

The explicit development-signing flag produces these verification artifacts:

- `app-armeabi-v7a-release.apk`
- `app-arm64-v8a-release.apk`

For distribution, configure `android/key.properties`, remove the development
signing flag and rebuild. Only the properly release-signed pair may be published.

### Universal ARM fallback

```powershell
flutter build apk --release `
  --target-platform android-arm,android-arm64 `
  --obfuscate `
  --split-debug-info=build/symbols/android-universal `
  --android-project-arg=allowDevelopmentSigning=true
```

### Play bundle

```powershell
flutter build appbundle --release `
  --obfuscate `
  --split-debug-info=build/symbols/android-aab
```

### Size analysis

Run separately from the obfuscated release build:

```powershell
flutter build apk --release `
  --target-platform android-arm64 `
  --analyze-size `
  --code-size-directory=build/size-analysis `
  --android-project-arg=allowDevelopmentSigning=true
```

### Artifact verification

- Confirm package ID, version name/code, min SDK and app label.
- Verify `zipalign -P 16` compatibility.
- Verify APK signature and release certificate.
- Record SHA-256 and exact file size.
- Retain obfuscation symbols for that version.
- Install the matching ARM32/ARM64 artifact on physical devices.
- Never publish a debug-signed artifact.

## 16. Verification matrix

### Android

- API 24, 28, 29, 33 and 36 emulators.
- Real ARM32 and ARM64 physical devices.
- 2 GB RAM, low storage, slow SD card and thermal pressure.
- Realme/Vivo battery manager, reboot and background termination.
- Permission deny, partial grant, revoke and re-grant.
- App upgrade, database migration and file preservation.

### Libraries and files

- 1,000, 10,000, 50,000 and 100,000 items.
- Corrupt files, zero-byte files, unsupported codecs and huge images.
- 4K video and transfers larger than 20 GB.
- Rename/move, removable-drive disconnect and storage full.
- Duplicate conflicts and app/PC crash during a write.

### Network and security

- LAN, mobile data, network switching and CGNAT relay.
- Direct and relayed encrypted connections.
- Interrupted/restarted/resumed transfer with final hash verification.
- Expired pairing QR, wrong device, revoked device and brute-force attempts.
- Traversal, symlink/junction/reparse-point escape attempts.
- Bulk-delete recovery and concurrent edit conflict.
- Confirm through network inspection that no media reaches a nexGallery storage
  service or unapproved endpoint.

### AI quality

- Face grouping across lighting, skin tones, masks, ages and camera quality.
- Twins and look-alike correction workflow.
- Hindi/English OCR across screenshots, receipts and documents.
- User-visible reset/delete of every derived AI index.

## 17. GitHub and release rules

- Repository: private `Vis-halG/nexGallery`.
- Main branch is protected after the foundation is stable.
- CI runs format, analysis, tests, Android split build and Windows build.
- Signing keys and passwords live only in local protected storage and GitHub
  Actions secrets.
- Never commit keystores, `key.properties`, tokens, databases, cache, personal
  media, model-license secrets or device credentials.
- Every release has architecture-specific APKs, a Universal fallback, Windows
  artifact, checksums, size report and release verification document.
- A feature is “complete” only after its behavior, privacy boundary, failure
  recovery and device tests pass.

## 18. Explicit limitations

- Google Photos cloud backup, public cloud links, collaborative cloud albums,
  web access and proprietary server-scale generative editing are not part of the
  local-first design.
- Remote access cannot work while the PC is off unless a compatible always-on
  Wake-on-LAN helper is available.
- Home upload speed limits remote original-quality playback.
- Android cannot expose other apps' private data.
- Face/OCR/object models are probabilistic and require correction/quality testing.
- A gallery/file-manager permission declaration can still be rejected by Google
  Play; MediaStore/SAF remains the compliant fallback.
- Remote streaming transfers encrypted data over the internet even though it is
  not stored by a nexGallery cloud service.

## 19. Definition of done

nexGallery is ready for a production release only when:

- Local media and file browsing work without an account.
- Remote access is opt-in, encrypted, scoped and revocable.
- No partial transfer appears as a finished file.
- Destructive actions are recoverable and audited.
- Phone and PC clearly show file source and online/offline state.
- AI indexes remain local and can be deleted.
- ARM32, ARM64 and Windows signed artifacts pass the verification matrix.
- APK size and performance stay within measured release budgets.
- The privacy statement matches observed network behavior.
