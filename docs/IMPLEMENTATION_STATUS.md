# nexGallery implementation status

Updated 2 October 2026 against `NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md`.

## Current milestone

Phase 1 is in progress. The app uses real local catalogue data instead of the
earlier foundation screens. Existing platform/server work has been preserved and
connected to feature screens. This continuation adds bounded timeline paging,
a swipeable viewer, safer scan reconciliation and focused regression coverage.

| Requirement | Status and boundary |
| --- | --- |
| Shared theme/navigation | Implemented adaptive shell; hidden-tab animations are paused while tab/server state is retained |
| Local catalogue | Persisted versioned JSON prototype; SQLite, FTS and production migrations remain planned |
| Android scan | Native MediaStore adapter connected to runtime; denied and limited-access states exist; physical-device and permission-change testing remains |
| Windows scan | Selected roots, metadata scan, progress and refresh; unreadable folders keep entries and show unavailable status |
| Paged timeline/files | Starts with 120 items; Load more appends one page; filter changes reset paging; JSON catalogue is still held in memory |
| Viewer | Swipe within loaded results, pinch zoom, desktop arrow/Escape shortcuts, live favorite action and metadata sheet |
| Preview quality | Bounded screen-sized preview, maximum 1024 pixels on Android; full original-resolution decode and complete codec/EXIF support remain |
| Video player | Opens the installed device player; integrated seek/speed/subtitle/resume controls remain |
| Albums/favorites/archive | Local virtual organization; originals stay in place |
| Trash | Prototype catalogue hiding on Windows and native Android consent where supported; full recoverable physical Trash is unfinished |
| Files | Native Android SAF browser and catalogue type filters; complete physical copy/move/ZIP workflows remain |
| Development remote server | Core pairing, path restrictions, range streaming, resumable upload and audit exist; the production security design is unfinished |
| AI/editor/vault | Planned; no claims of implemented analysis, editing or encrypted Locked Folder |

## Reconciliation guarantees in this build

- A Windows scan with access errors, cancellation, file/directory limits or a
  depth limit cannot remove unseen entries or their album membership.
- A path reported unreadable marks its retained entries unavailable; a later
  successful scan restores availability and retains favorites/albums.
- Only a complete source snapshot may remove stale non-Trash catalogue entries.
- `.part` uploads and `.nexgallery-` protocol state never enter the local scanner,
  including when hidden files are enabled.
- Thumbnail refresh notices changed paths, timestamps, availability and preview
  sizes. Windows decoding preserves aspect ratio and releases its resources.

## Next work from the plan

1. SQLite/migrations, incremental indexing and real large-library measurements.
2. Android lifecycle refresh, permission revoke/re-grant/partial-selection tests
   and physical-device validation across the declared API/ABI matrix.
3. Windows native build/launch validation, selected-folder picker, stable file
   identity and watcher/reconciliation behavior.
4. Integrated video player, complete metadata and production settings.
5. Phase 2 physical file operations, recoverable Trash, editor and vault.

The production server requirements stay explicit: encrypted network transport,
device identities, PC approval, read-only defaults, scoped permissions, secure
secret persistence and the background-agent lifecycle. The development server's
smoke checks do not establish those production guarantees.
