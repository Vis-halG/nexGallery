# nexGallery tech stack

Current implementation on 2 October 2026. The product and build plan remains
the source of requirements; this file describes the code that exists.

| Layer | Current implementation |
| --- | --- |
| Shared app | Flutter 3.47.4 / Dart 3.13.3, Material 3, system typography and icons |
| Presentation | Feature widgets under `lib/features`, `GalleryModel` interface, `ChangeNotifier` runtime |
| Local catalogue | Immutable Dart models, paged/filterable repository, schema-versioned JSON snapshot with resilient persistence |
| Android | Kotlin platform channel for MediaStore, granular permissions, selected-photo access, SAF, native thumbnails and secure open/share |
| Windows files | Dart `Directory` scanner over selected roots, progress/cancellation, saved roots and unavailable-folder reconciliation |
| Photo preview | Flutter codecs on Windows, platform thumbnails on Android, bounded 1024-pixel viewer preview, swipe and zoom |
| Video | Native thumbnail plus explicit handoff to the installed device player |
| Organization | Catalogue-backed virtual albums, favorites and archive |
| Development server | Dependency-free Dart HTTP server, loopback default, explicit LAN opt-in, bearer token pairing, path guard and audit records |
| Transfers | Byte-range download, resumable staged upload, SHA-256 verification before finalize |
| Validation | Flutter analysis and unit/widget tests, Dart server integration and compiled-executable smoke checks |
| Android artifacts | API 24 minimum / API 36 target, ARM32 and ARM64 split release builds, resource shrinking and Dart obfuscation |

The base application currently has no third-party runtime packages. It does not
include cloud media storage, advertising, analytics, or bundled AI model packs.

## Planned architecture work

- SQLite WAL catalogue, migrations, FTS and scan checkpoints replace the JSON
  prototype before large-library claims.
- Windows file IDs/content identity, watchers and periodic reconciliation.
- An integrated video player and codec compatibility probes.
- Platform-protected vault keys and encrypted recovery export.
- Optional verified offline model packs for faces, OCR and visual search.
- Per-user Windows background agent with authenticated local UI control.
- Production device keys, PC approval, scoped read-only permissions, private
  encrypted network setup and replay-resistant sessions.

Windows desktop Flutter builds require Visual Studio C++ desktop tooling. The
standalone Dart server executable can be compiled without that workload.
