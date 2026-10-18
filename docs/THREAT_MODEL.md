# nexGallery threat model

Updated 18 October 2026 for the working tree. It covers the Android app, the
Windows app and the PC server (in-process or the `nexgallery_server.exe`
background agent). It records what the code does today; open items are listed
at the end and in [implementation status](IMPLEMENTATION_STATUS.md).

## Assets

| Asset | Where it lives |
| --- | --- |
| Original photos, videos and files | Phone storage (MediaStore/SAF); folders the PC owner shares |
| Locked Folder contents | App-private vault files, AES-256-GCM, key from PBKDF2 (600,000 rounds) |
| Derived data: catalogue, faces, OCR text, labels, places, thumbnails, video proxies | App-private folders (`%LOCALAPPDATA%\nexGallery`, Android app data) |
| PC identity: TLS private key, owner secret | `%LOCALAPPDATA%\nexGallery\server`, encrypted for the Windows user with DPAPI |
| Device credentials: bearer tokens, Ed25519 device keys | Phone: Android Keystore-wrapped secret store. PC: salted SHA-256 token hashes and device public keys in `tokens.json` |
| Audit trail | `audit.jsonl` beside the server state |

## Actors

- **Owner**: signed in to the Windows account that runs the server.
- **Paired phone**: approved by the owner, limited to its scopes and folders.
- **Network attacker**: on the same Wi-Fi, a hostile hotspot or the internet.
- **Unpaired device on the tailnet or LAN**: can reach the port.
- **Stolen or lost phone**.
- **Other local account or malware running as another user** on the PC.
- **Malicious file**: an upload or a shared-folder file built to exploit a parser.

## Trust boundaries

1. Phone ↔ PC over TLS (LAN or Tailscale/WireGuard).
2. Desktop app ↔ background agent over loopback TLS with the owner secret.
3. Server ↔ shared folders (the path guard).
4. App ↔ optional model-pack downloads.
5. Phone app ↔ Android system (MediaStore, SAF, Keystore, BiometricPrompt).

## Threats and mitigations

| Threat | Mitigation in code | Tests |
| --- | --- | --- |
| Eavesdropping or tampering on the network | TLS 1.2+ with a self-signed PC certificate; phones pin its SHA-256 fingerprint from the QR code; private-network mode binds only loopback and Tailscale addresses | `remote_tls_test`, `remote_desktop_test` |
| Unpaired device pairs itself | Eight-digit single-use code (five-minute lifetime), 10 attempts per minute per address, explicit owner approval on the PC before any token exists | `remote_pairing_security_test`, compiled agent smoke test |
| Stolen bearer token or replay | Each phone signs method, path, query, time, nonce and covered headers with its Ed25519 key; ±5-minute window and nonce replay cache; tokens stored only as salted hashes | `remote_pairing_security_test` |
| Phone exceeds its rights | Per-device scopes (browse, download, upload, organize, trash) and per-folder limits checked centrally; PC-wide read-only default | `remote_pairing_security_test` |
| Path traversal, links, reparse points, alternate streams | Every path is canonicalised against an approved root; `..`, absolute paths, reserved `.nexgallery-` paths and links leaving the root are refused; phones never send raw Windows paths | `remote_server_smoke_test` |
| Silent overwrite or deleting a newer file | Uploads never replace an existing name; downloads, move and trash check the listed file version (ETag/`If-Match`, 412 `file_changed`) | `upload_safety_test` |
| Partial transfer appears as a finished file | Uploads write a `.part` file, verify size and SHA-256, then rename; partial files are hidden from listings and the local scanner | `transfer_queue_test`, `remote_server_smoke_test` |
| Malicious upload runs on the PC | Executables, scripts, archives and macro documents go to a hidden quarantine, get Mark-of-the-Web, and are released only after Microsoft Defender reports them clean; flagged files can only be deleted; without a scanner they wait for the owner | `upload_safety_test` |
| Another local process manages the agent | Owner API answers only on loopback and requires the owner secret (DPAPI-protected); requests pin the agent certificate | `background_agent_test`, compiled agent smoke test |
| Another Windows account copies server secrets | DPAPI binds the TLS key and owner secret to the Windows user | `protected_secrets_test` |
| Request flooding | 240 requests per minute per address and per device; JSON bodies capped at 1 MiB; bounded search and list sizes | `remote_server_smoke_test` |
| Lost phone | Owner revokes the device on the PC at once; the phone can revoke itself | `remote_pairing_security_test` |
| Someone with the unlocked phone empties Trash | Irreversible bulk actions ask for the fingerprint, face or screen-lock PIN after the confirmation | `user_check_test` |
| Locked Folder brute force | PBKDF2-SHA256 with 600,000 rounds and AES-256-GCM authentication | `editing_vault_test` |
| Tampered model download | Allowlisted URLs with pinned SHA-256 per file; a file that fails the check is deleted and never loaded | `integration_test/intelligence_packs_test` (Android emulator) |
| Derived data leaks | Caches stay in app-private folders; "Clear face groups" and the search-index reset delete face, OCR and label indexes without touching originals | `intelligence_test` |

## Residual risks

- **Time-of-check/time-of-use on the PC.** Dart cannot open a file and check
  its path in one OS call. Do not give untrusted local accounts write access to
  a shared folder while the server runs.
- **Trust on first use.** A phone that pairs by typing an address and skips the
  QR code must compare the fingerprint shown on the PC.
- **LAN mode** listens on every interface. It is meant for a trusted home
  network; use Tailscale away from home and never forward the port.
- **Tailscale** sees device and connection metadata, and its relays forward
  encrypted WireGuard packets (see [privacy](PRIVACY.md)).
- **No scanner.** If Microsoft Defender is disabled and no other scanner is
  configured, risky uploads wait for the owner, who can release them unscanned.
- **Windows firewall rules** are not changed by nexGallery (that would need
  administrator rights). Private-network mode limits exposure by binding only
  to loopback and Tailscale addresses.
- **Catalogue encryption at rest** for high-security mode is not implemented;
  derived data relies on OS account isolation and device encryption.
- **Parsers.** Thumbnails and metadata decode untrusted images in Dart with
  size limits; native codecs on each platform remain part of the attack surface.

## Not yet done

- External penetration test and fuzzing of the HTTP parser and path guard.
- Physical-device testing of Keystore, BiometricPrompt and OEM variations.
- Code-signing of the Windows installer and Android release keys (owner-held).
