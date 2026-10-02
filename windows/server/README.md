# nexGallery PC server core

This directory contains the dependency-free Dart HTTP server behind the planned
Windows companion. It exposes only folders that the PC owner explicitly names.
The server starts on `127.0.0.1` by default. `--lan` is an explicit opt-in.

## Current security boundary

- Transport is plain HTTP. TLS and direct public-internet hosting are **not**
  implemented.
- Never port-forward the server port on a router. LAN mode is for a trusted
  private network. An independently configured encrypted overlay such as
  Tailscale or WireGuard can carry the traffic, but this repository does not
  install, configure, or verify either service.
- Pairing codes expire after five minutes and work once. Successful pairing
  returns a random bearer token once; the PC stores only its salted SHA-256
  hash.
- Every file path is resolved against a configured root. Absolute paths,
  `..`, reserved server paths, and links that resolve outside that root are
  rejected.
- The implementation reduces symlink traversal risk, but Dart's path/open APIs
  cannot make the validation and open operation one indivisible OS action. Do
  not grant untrusted local PC accounts write access to an allowed root while
  the server is operating.
- Tokens are full-control credentials for the configured roots. A paired
  device can list and revoke paired tokens.

## Run from source

From the repository root:

```powershell
dart run windows/server/bin/nex_gallery_server.dart `
  --root photos="D:\Photos" `
  --root documents="D:\Documents"
```

Add `--lan` when the phone and PC are on a trusted LAN. The console prints an
eight-digit code and JSON payloads that a UI can encode as QR codes. Port `0`
selects an available port for testing.

Build a standalone executable:

```powershell
dart compile exe windows/server/bin/nex_gallery_server.dart `
  -o windows/server/build/nex_gallery_server.exe
```

The default state directory is `%LOCALAPPDATA%\nexGallery\server`. It contains
`tokens.json` and append-only `audit.jsonl`. It should remain private to the PC
account running the server. A different directory can be selected with
`--data-dir`.

## Pairing

The CLI creates an initial code. A desktop UI can create another by calling
`POST /v1/pair/code` from loopback. Code creation is rejected for non-loopback
clients. The phone exchanges the code once:

```http
POST /v1/pair
Content-Type: application/json

{"code":"12345678","deviceName":"My phone"}
```

The response contains a `token`. Store it in the phone's platform credential
store and send it on every protected request:

```http
Authorization: Bearer <token>
```

## API v1

| Method and path | Purpose |
| --- | --- |
| `GET /v1/health` | Minimal unauthenticated health response |
| `POST /v1/pair/code` | Create a one-time code from the PC itself |
| `POST /v1/pair` | Exchange code and device name for a bearer token |
| `GET /v1/roots` | List configured root IDs, without physical PC paths |
| `GET /v1/list?root=ID&path=PATH` | List up to 5,000 safe child entries |
| `GET /v1/search?root=ID&path=PATH&q=TEXT&limit=100` | Bounded recursive metadata search |
| `GET /v1/download?root=ID&path=PATH` | Download or stream; supports one HTTP byte range |
| `HEAD /v1/download?...` | Read file headers without content |
| `GET /v1/thumbnail?...` | Explicit `501 thumbnail_not_supported` response |
| `PUT /v1/upload?root=ID&path=PATH` | Append a resumable raw-data chunk |
| `POST /v1/folders` | Create one folder below an existing parent |
| `POST /v1/move` | Rename or move inside one configured root |
| `POST /v1/trash` | Move a file/folder to hidden recoverable trash |
| `GET /v1/trash?root=ID` | List up to 1,000 recoverable trash items |
| `POST /v1/trash/restore` | Restore a trash ID, optionally to a new path |
| `GET /v1/tokens` | List paired devices and token IDs |
| `POST /v1/tokens/revoke` | Revoke a token ID, or the caller when omitted |

JSON request bodies are capped at 1 MiB. General traffic defaults to 240
requests per minute per address and authenticated device. Pairing is limited to
10 attempts per minute per address. Search scans at most 50,000 entries and
returns at most 500 results.

### Resumable upload

Each chunk is raw request data with these headers:

```http
X-Upload-Id: client-generated-safe-id
X-Upload-Offset: 0
X-Upload-Total: 1048576
X-Upload-Complete: false
```

The server appends to a sibling `.part` file only when the supplied offset
matches its current size. It returns `nextOffset`, allowing the phone to resume
after a disconnect. The upload ID and declared total must remain stable between
chunks. The final request sets `X-Upload-Complete: true`; it may also send
`X-Content-SHA256` with the lowercase 64-character hash. When provided, the
server verifies the complete file before finalization. The bundled Dart client
sends this final checksum by default. The `.part` file is then renamed beside
its destination. Existing destinations are rejected, keeping finalization
atomic on normal local filesystems. Defaults are 8 MiB per chunk and 20 GiB per
file.

### File-operation bodies

```json
{"root":"photos","path":"Trips/2026"}
```

The folder and trash endpoints use `root` and `path`. Move uses `root`,
`sourcePath`, and `destinationPath`. Restore uses `root`, `trashId`, and an
optional `destinationPath`. There is no permanent-delete endpoint in this core.

## Verification

Run the dependency-free integration suite and compile the executable:

```powershell
dart run windows/server/test/remote_server_smoke_test.dart
dart compile exe windows/server/bin/nex_gallery_server.dart `
  -o windows/server/build/nex_gallery_server.exe
dart run windows/server/test/compiled_exe_smoke_test.dart
```
