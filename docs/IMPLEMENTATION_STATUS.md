# nexGallery implementation status

Updated 30 October 2026 against [the product and build plan](NEXGALLERY_PRODUCT_AND_BUILD_PLAN.md).
Results and artifacts: [verification 29 October 2026](verification-2026-10-29.md).

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

## Phase 5 — internet and transfers: implemented; real-network certification remains

Tailscale setup steps with direct/relay status; private-network mode binds only
loopback and Tailscale addresses; resumable, conflict-aware phone-PC transfer
queue with pause/resume/cancel and Wi-Fi-only rule; offline copies; camera
backup; Wake-on-LAN; adaptive 360p/720p/1080p video proxies made by FFmpeg
(GPU encoder when available) and chosen automatically on mobile data; PC kept
awake during streams and transfers, plus "Keep this PC available".

Real FFmpeg hardware transcoding, output format and decoding were verified.
A 64 MiB pinned-TLS upload/download soak passed with interruption, fresh-client
resume and matching SHA-256. Longer physical-network and battery runs remain external.

Android now supports opt-in WorkManager camera backup and transfer handoff,
with network/charging constraints, a bounded headless engine, foreground
notification and cancellation. A native lease prevents the UI and worker from
writing the transfer journal concurrently. The two background opt-ins are
independent; user-paused work stays paused. Android controls actual execution
time, and OEM/physical-device battery testing remains external.
Journal mutations reject stale screens without ownership, and handoff drains
file staging/cache edits plus coalesced initialization before releasing the
native lease. Regression tests cover pausing during a delayed lease claim.

Remote offline copies and resumable staging files use chunked AES-256-GCM
with an OS-protected key. Legacy complete copies migrate before plaintext is
removed. Opening/sharing/exporting explicitly decrypts a temporary private copy;
old temporary views are pruned on startup and clearing offline copies removes
them. Publicly exported/shared copies are outside the app's encryption boundary.

## Additional product features completed in 0.2

- Authorized remote timeline, albums and People; HMAC-bound cursor pages and a
  bounded delta journal with deletions and explicit resync on stale tokens.
- Mobile PC library screen alongside folder browsing; the background agent
  reads desktop metadata without mutating its database or exposing face vectors.
- Offline Natural Earth photo map with zoom, grouped markers and photo viewing.
- English/Hindi application copy, Material localization and saved language choice.
  User-authored content is preserved; technical diagnostics may remain English.
- Optional authenticated AES-256-GCM catalogue snapshots; Android Keystore or
  Windows DPAPI protects the key. Migration preserves albums/favorites and cleans
  old catalogue copies. Originals/thumbnails/separate analysis caches retain
  their existing protection; this is not whole-device encryption.
- Update popup with verified download/install, retry and foreground rechecks.
  Permanent Android signing, gated release builds, SBOM/OSV tooling and optional
  trusted Windows signing. [First-install transition](UPDATES.md) is required
  for the earlier development-signed, update-disabled APKs.

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
| Localization | English and Hindi shipped; system Material controls localized; diagnostics may remain English |
| Penetration test, fuzzing | Seeded parser/path/permission fuzz tests implemented; independent penetration test remains external |
| Signed releases | Permanent Android release key configured; Windows supports owner-provided Authenticode credentials, otherwise its installer is unsigned |
| Long transfers, physical devices | Needs ARM phones on API 24-36 and a real Windows build |

## Work that still needs external evidence or credentials

- Physical ARM32/ARM64 phones and OEM restrictions, real long-running network
  transfers, Tailscale direct/relay paths and battery behavior.
- Manual TalkBack/Narrator review and labelled real-library AI quality measurements.
- Independent penetration testing and review of vendored native libraries/codecs;
  OSV package checks are not a complete native-code vulnerability certification.
- Trusted Windows code-signing certificate and Play/other store submission.
- Windows service before sign-in stays intentionally deferred until a separate
  account/ACL/credential design exists. The supported agent runs at user sign-in.
