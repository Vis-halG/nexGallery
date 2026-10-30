# Verification — 29 October 2026

Updated 30 October with background work and encrypted offline-cache checks.

Scope: version 0.2.0 work on remote catalogue, map, localization, encrypted
catalogue, release packaging and in-app updates. This is an early-access record,
not physical-device certification or an independent penetration-test report.

Local checks:

- Full analyzer passed without issues. The final unit/widget suite passed
  all 236 tests, including independent background opt-ins.
- API 35 real native tests passed both the WorkManager headless callback
  (context-backed platform channels and Keystore) and catalogue/Hindi/map test.
- Encrypted offline-cache tests cover interrupted download/torn-frame resume,
  matching final bytes, tampering, wrong key, changed PC version and legacy
  plaintext migration. Transfer handoff tests verify resumed uploads with a
  fresh queue and preservation of user-paused work. Background session tests
  cover exclusive journal ownership and independent backup/transfer opt-ins.

- Automated unit/widget tests include permission revocation, catalogue migration,
  AES-GCM tampering/wrong keys, OS-key loss, cursor/device/query binding, bounded
  delta history, private-root filtering, People-vector sanitization, Hindi text,
  map coordinate limits and update checksum/installer handoff.
- A 100,000-item budget passed: first sync 9.58 s, unchanged rescan 0.93 s,
  favorite 0.059 s, 10,000 album members 0.183 s, page/search 47/67 ms,
  reopen 2.08 s. Timing includes other workstation activity.
- The native API 35 test passed on a new isolated emulator: Android Keystore,
  encrypted catalogue migration/reopen, saved Hindi setting and bundled map.
  The existing emulator ran out of install storage; its data was preserved.
- Real FFmpeg 9.0.2 hardware encoding passed: 480x360 MP4, stereo AAC, expected
  duration and a complete decode. The downloaded portable tool was checked
  against the distributor's SHA-256 and stays outside the source tree.
- A 64 MiB transfer soak passed over pinned TLS in both directions, with
  interrupted upload/download, a fresh client resuming each transfer, and final
  source/upload/download SHA-256 equality (8 seconds on this PC).
- OSV checked 76 resolved hosted Dart package versions with no findings at the
  time of the local audit. The tool emits CycloneDX and timestamped results in
  `build/security/`; release CI also supplies resolved Maven dependencies.
- Security fuzzing exercises 1,500 seeded paths, malformed JSON/UTF-8/body sizes,
  permissions and post-rejection server health. This does not replace an external audit.

The compiled Windows agent must be built using `dart build cli`, which bundles
SQLite code assets. The installer preserves its `server/bin` and `server/lib`
layout. The compiled-agent smoke test now reads the real desktop SQLite catalogue
and authorized albums over pinned TLS, so a missing native library fails the gate.

Release CI runs the new native test on APIs 24, 29, 33 and 36, builds the native
Windows app/installer, and validates artifacts before publishing. Consult the
Actions run linked from the release for results of that exact commit; a workflow
definition alone is not evidence that all its matrix jobs have passed.

Still external: physical ARM/OEM testing, TalkBack/Narrator user review,
cross-network Tailscale/long-duration battery testing, labelled real-library AI
quality evaluation, independent penetration testing, trusted Windows signing
certificate and store accounts/submission. See implementation status for boundaries.
