# nexGallery implementation status

Updated 18 October 2026 against [the product and build plan](NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).
Results and artifacts: [verification 18 October 2026](verification-2026-10-18.md).

"Done" means implemented and covered by automated tests on this workstation.
Physical Android devices, the native Windows app build (Visual Studio C++ is
not installed here) and store/signing steps are tracked separately below.

## Phase 1 — foundation: done

Adaptive shell and settings; SQLite WAL catalogue with migrations, FTS5 and
backups; Android MediaStore/SAF and Windows folder scans with watchers and
reconnect handling; paged timeline; photo viewer; video player with resume and
subtitles; permission-denied and partial-access states.

## Phase 2 — local organization: done

| Area | Behaviour |
| --- | --- |
| Albums, favorites, archive, Trash | Virtual albums with covers, multi-select actions, Archive, recoverable Trash, Empty Trash behind fingerprint/PIN |
| Memories | On this day, month recaps, trips, people and favorites, with slideshow |
| Files | Categories, SAF browser, copy/move/rename/share, ZIP create/extract, storage insights and cleanup suggestions |
| Editing | Crop, rotate, straighten, filters, adjustments, drawing, collage; video trim/rotate/mute |
| Locked Folder | AES-256-GCM vault, PBKDF2 600,000 rounds, encrypted export/import |
| Backup | Encrypted export of albums and favorites; restore onto existing items |
| Identity | Renamed or moved Windows files keep favorites, albums, Trash state and face records (file ID; name+size+time across drives) |

## Phase 3 — offline intelligence: done (quality unmeasured)

Face detection/embeddings with People rename/merge/split; OCR and object/scene
labels in smart search; offline places (GeoNames); duplicates and similar
photos; pauses for heat, low memory, battery saver and low battery. Models are
optional downloads checked by SHA-256. Recognition accuracy on real libraries
is not yet measured.

## Phase 4 — Windows server and LAN: done

| Area | Behaviour |
| --- | --- |
| Background agent | `nexgallery_server.exe --config` runs without a console at Windows sign-in with the user's rights; the app manages it over a loopback owner API (TLS + DPAPI-protected owner secret); `agent.log`; waits for Tailscale and rebinds when it connects |
| Permissions | Read-only by default; per-phone scopes and folder limits |
| Pairing | QR code with pinned certificate fingerprint, owner approval, Ed25519 signed requests with replay protection, immediate revocation |
| LAN | Discovery broadcast, thumbnails, paged lists, search, byte-range streaming |
| Safety | ETag/`If-Match` and version checks on download, move and Trash; risky uploads quarantined until Microsoft Defender clears them, with Mark-of-the-Web |
| Audit | Append-only audit log shown on the PC |

Deviation: the plan names an authenticated named pipe for UI-agent control.
The agent uses a loopback-only HTTPS owner API with a per-user DPAPI secret
instead, which shares the server's authorization code and is covered by the
compiled agent smoke test. Pairing codes last five minutes rather than the
plan's two: each code works once, attempts are rate limited and the owner
still approves every phone.

## Phase 5 — internet and transfers: done (FFmpeg path unverified here)

Tailscale setup steps with direct/relay status; private-network mode binds only
loopback and Tailscale addresses; resumable, conflict-aware phone-PC transfer
queue with pause/resume/cancel and Wi-Fi-only rule; offline copies; camera
backup; Wake-on-LAN; adaptive 360p/720p/1080p video proxies made by FFmpeg
(GPU encoder when available) and chosen automatically on mobile data; PC kept
awake during streams and transfers, plus "Keep this PC available".

FFmpeg is not installed on this workstation, so a real transcode has not been
run; the proxy pipeline is tested with a substitute transcoder.

## Phase 6 — hardening and release: partly done

| Item | Status |
| --- | --- |
| Threat model | [THREAT_MODEL.md](THREAT_MODEL.md) |
| Dependency audit | [DEPENDENCY_AUDIT.md](DEPENDENCY_AUDIT.md); dependencies upgraded within constraints |
| 100,000-item performance | Budget test in `test/catalog_performance_test.dart`; saves write only changed rows (one favorite: 11.7 s → 0.06 s) |
| Windows secrets | TLS key and owner secret encrypted with DPAPI |
| Installer, update, rollback | Inno Setup per-user installer, built in CI; [RELEASE.md](RELEASE.md) |
| Privacy and Play | [PRIVACY.md](PRIVACY.md), [PLAY_DECLARATIONS.md](PLAY_DECLARATIONS.md) |
| Battery guidance | In [RELEASE.md](RELEASE.md) |
| Accessibility | Tooltips on every icon button, large-text and small-screen layout tests; a TalkBack/Narrator pass on devices is still needed |
| Localization | Not started; the UI is English only |
| Penetration test, fuzzing | Not started |
| Signed releases | Needs the owner's Android keystore and a Windows code-signing certificate |
| Long transfers, physical devices | Needs ARM phones on API 24-36 and a real Windows build |

## Remaining product scope

- Remote API: cursor-paged PC timeline/albums/people and a delta change feed
  (phones browse folders and search today).
- Map view for places; optional catalogue encryption for a high-security mode.
- Windows service mode before sign-in (the plan defers it until ACLs are defined).
- Localization, device accessibility review, penetration testing.
- Store submission and signed artifacts.
