# nexGallery PC server

The Dart HTTP/TLS server behind the Windows app. It exposes only folders the
PC owner names, to phones the owner approves. The same code runs inside the
desktop app, as the `nexgallery_server.exe` background agent, and as a
developer console (`nex_gallery_server.exe`).

## Security boundary

- The desktop app and the agent use TLS with a self-signed certificate; phones
  pin its SHA-256 fingerprint from the pairing QR code. The developer console
  uses plain HTTP and is for testing only.
- Never port-forward the server port. "Home network" mode is for a trusted
  LAN; "Anywhere" mode binds only loopback and this PC's Tailscale addresses.
- Pairing codes work once and expire after five minutes. Every new phone waits
  for the owner's approval; the PC stores only salted token hashes and each
  phone's Ed25519 public key. Phones sign every request (timestamp, nonce,
  method, path, query, covered headers); replays are refused.
- Access is read-only by default. Each phone has scopes (browse, download,
  upload, organize, trash) and optional folder limits.
- Every path is resolved against an approved root. Absolute paths, `..`,
  reserved `.nexgallery-` paths and links leaving the root are refused. Dart
  cannot check and open a path in one OS call, so do not give untrusted local
  accounts write access to a shared folder while the server runs.
- Programs, scripts, archives and macro documents uploaded by phones are held
  in `.nexgallery-quarantine` with Mark-of-the-Web until Microsoft Defender
  reports them clean. Flagged files can only be deleted; without a scanner they
  wait for the owner.
- Download, move and Trash honour the listed file version (`ETag`,
  `If-Match`, `X-Nex-File-Version`, or a `version` body field) and answer
  `412 file_changed` when the file changed.
- Streams, uploads and video conversions keep Windows awake (a power request
  visible in `powercfg /requests`), plus 90 seconds; "Keep this PC available"
  holds it while the server runs.
- The TLS key and owner secret are encrypted for the Windows user with DPAPI.

## Background agent

The desktop app writes `%LOCALAPPDATA%\nexGallery\server\agent.json` and starts

```text
nexgallery_server.exe --config %LOCALAPPDATA%\nexGallery\server\agent.json
```

detached, and at sign-in through
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\nexGalleryServer` when the
owner turns on "Keep running when nexGallery is closed". It runs with the
user's own rights, has no console window (PE subsystem: Windows GUI), and logs
to `agent.log` in the same folder (one rotated copy above 1 MiB). In Anywhere
mode it serves loopback until Tailscale connects, then rebinds. A second agent
for the same user exits at once.

The app manages the agent over a loopback-only owner API that requires the
DPAPI-protected owner secret in `X-Nex-Owner`.

## Build

```powershell
dart run tool/build_server.dart
```

writes `windows/server/build/nex_gallery_server.exe` (console) and
`windows/server/build/nexgallery_server.exe` (agent). The Windows app build
copies the agent next to `nex_gallery.exe`.

## Developer console

```powershell
dart run windows/server/bin/nex_gallery_server.dart `
  --root photos="D:\Photos" `
  --root documents="D:\Documents"
```

Add `--lan` for a trusted LAN; port `0` picks a free port. The console prints
the pairing code and QR payloads. Approve a waiting phone by typing
`approve ID` (read-only) or `approve ID full`; also `deny ID`, `code`,
`devices` and `quit`.

The default state folder is `%LOCALAPPDATA%\nexGallery\server` (`--data-dir`
changes it). It holds `tokens.json`, `audit.jsonl`, the TLS identity, the
thumbnail and video caches, and must stay private to the PC account.

## Pairing

1. The PC shows a code (`POST /v1/pair/code`, owner only).
2. The phone sends `POST /v1/pair` with `code`, `deviceName` and its
   `publicKey`, and receives `202` with `requestId` and `pollSecret`.
3. The owner approves (`POST /v1/pair/approve`) with scopes and folders.
4. The phone polls `POST /v1/pair/status` and receives its bearer token once.

## API v1

Phone endpoints (bearer token plus signature):

| Method and path | Scope | Purpose |
| --- | --- | --- |
| `GET /v1/health` | none | Health, TLS and write mode |
| `GET /v1/info` | browse | PC name, this phone's scopes and folders, Wake-on-LAN addresses, video-proxy support |
| `GET /v1/roots` | browse | Folders this phone may open, without PC paths |
| `GET /v1/list?root&path&offset&limit` | browse | Paged folder listing with file versions |
| `GET /v1/search?root&path&q&limit` | browse | Bounded recursive name search |
| `GET /v1/thumbnail?root&path&size` | browse | Cached JPEG preview of an image |
| `GET`/`HEAD /v1/download?root&path` | download | Download or stream with one byte range; `ETag` and `If-Match` |
| `GET /v1/proxy/status?root&path&quality` | download | Start or report a 360/720/1080p copy of a video (needs FFmpeg) |
| `GET`/`HEAD /v1/proxy?root&path&quality` | download | Stream a finished copy with byte ranges |
| `PUT /v1/upload?root&path` | upload | Append a resumable chunk |
| `POST /v1/folders` | organize | Create a folder |
| `POST /v1/move` | organize | Rename or move inside one folder |
| `POST /v1/trash`, `GET /v1/trash`, `POST /v1/trash/restore` | trash | Recoverable Trash inside the shared folder |
| `POST /v1/tokens/revoke` | any | A phone revokes itself |

Owner endpoints (loopback and owner secret): `GET /v1/pair/requests`,
`POST /v1/pair/approve`, `POST /v1/pair/deny`, `GET /v1/tokens`,
`POST /v1/tokens/permissions`, `POST /v1/owner/revoke`, `GET /v1/audit`,
`GET /v1/quarantine`, `POST /v1/quarantine/release`,
`POST /v1/quarantine/delete`, `POST /v1/owner/shutdown`.

JSON bodies are capped at 1 MiB. Traffic is limited to 240 requests per minute
per address and per device, pairing to 10 attempts per minute per address.
Search scans at most 50,000 entries and returns at most 500 results.

### Resumable upload

Each chunk is raw request data with these headers:

```http
X-Upload-Id: client-generated-safe-id
X-Upload-Offset: 0
X-Upload-Total: 1048576
X-Upload-Complete: false
```

The server appends to a sibling `.part` file only when the offset matches its
size and returns `nextOffset`, so the phone resumes after a disconnect. The
final request sets `X-Upload-Complete: true` and `X-Content-SHA256`; the server
verifies the hash before renaming the file into place (or into quarantine).
Existing names are never replaced. Defaults are 8 MiB per chunk and 20 GiB per
file.

### File-operation bodies

```json
{"root":"photos","path":"Trips/2026","version":"1234:1760745600000000"}
```

Folder and Trash use `root` and `path`; move uses `root`, `sourcePath` and
`destinationPath`; restore uses `root`, `trashId` and an optional
`destinationPath`. `version` is optional. There is no permanent-delete
endpoint.

## Verification

```powershell
dart run windows/server/test/remote_server_smoke_test.dart
dart run tool/build_server.dart
dart run windows/server/test/compiled_exe_smoke_test.dart
```

The compiled test runs both executables: console approval, and the detached
agent's owner API, approval, a signed phone, shutdown and `agent.log`.
