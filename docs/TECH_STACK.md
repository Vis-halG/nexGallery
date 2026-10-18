# nexGallery tech stack

Current implementation on 18 October 2026. The product and build plan is the
requirements baseline; this file describes the working tree.

| Layer | Implementation |
| --- | --- |
| App | Flutter / Dart, Material 3, responsive phone/tablet/desktop navigation |
| Presentation | Feature widgets over the GalleryModel, GalleryTools and GalleryOrganizer contracts; ChangeNotifier runtime |
| Catalogue | sqlite3 in worker isolates, WAL, schema 2 migrations, FTS5, daily `VACUUM INTO` backups, legacy JSON import; saves write only changed rows |
| Queries | In-memory snapshot with 120-item pages; 100,000 items within the budget in `test/catalog_performance_test.dart` |
| Android | Kotlin channels: MediaStore, SAF, thumbnails, consent operations, open/share, wallpaper, device conditions, QR scanning, BiometricPrompt/screen-lock confirmation, Media3 video tools |
| Windows | Selected-folder scanner with FFI file IDs, native folder picker, watchers, periodic reconciliation, drive reconnect, physical Trash |
| Photos and video | Bounded previews, editing (filters, straighten, drawing, collage), video_player on Android (ExoPlayer) and Windows (Media Foundation), subtitles on Windows |
| Organization | Albums, favorites, Archive, Trash, Memories, encrypted organization backup, AES-256-GCM Locked Folder |
| Intelligence | flutter_onnxruntime with optional SHA-256-checked model packs: faces (YuNet/SFace), objects (MobileNetV2), text (PaddleOCR); GeoNames places; perceptual hashes |
| PC server | Dart HTTP/TLS server shared by the app and `nexgallery_server.exe` (Dart AOT, Windows GUI subsystem); Ed25519 request signing; scopes; quarantine with Microsoft Defender; ETags; FFmpeg video proxies; Windows power requests; DPAPI secrets |
| Phone remote client | Pinned-TLS client, Keystore-wrapped secrets, resumable transfer queue, loopback stream proxy for the native player |
| Packaging | Split ARM APKs; Inno Setup per-user Windows installer; CI builds both |
| Validation | Unit/widget tests, real filesystem and SQLite tests, server and compiled-agent smoke tests, Android emulator integration tests |

No advertising, analytics, Firebase or third-party media-storage SDK is used.
See the [dependency audit](DEPENDENCY_AUDIT.md) for versions and licences.

## Storage and safety boundaries

The catalogue is app-private `catalog.sqlite`. Corrupt or future-version files
are protected against overwrite and valid backups recover a damaged primary.
Repository mutations roll back in memory when persistence fails. Unchanged
items keep their objects, so a rescan of an unchanged library writes nothing.

Android visibility comes from a current OS query; permission revocation closes
cached viewers and blocks stale actions. Windows incomplete scans preserve
unseen items and organization; moved files are matched by file ID. App data and
transfer staging files are excluded from scans.

The PC server's TLS key and owner secret are DPAPI-encrypted for the Windows
user. Phones store their token and device key in a Keystore-wrapped store.

## Toolchain gaps on this workstation

- Visual Studio's Desktop development with C++ workload is missing, so the
  native Windows app is built only in CI.
- FFmpeg is not installed, so video proxies were tested with a substitute
  transcoder.
