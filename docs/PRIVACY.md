# nexGallery privacy statement

Draft for the store listings and the in-app "About" page, 18 October 2026. It
describes the network behaviour of the current code; re-check it against a
packet capture before each release (see [release](RELEASE.md)).

## Summary

nexGallery is a gallery, file manager and personal PC server. Your photos,
videos and files stay on your phone and on the PC folders you choose. There is
no nexGallery account, no nexGallery cloud storage, and no advertising,
analytics or crash-reporting SDK.

## What leaves your phone or PC

| When | What is sent | Where |
| --- | --- | --- |
| You pair a phone with your PC | Phone name, its public device key, a one-time code | Your PC only |
| You browse, stream, upload or back up to your PC | Folder listings, previews, files and their checksums | Your PC only, over TLS pinned to your PC's certificate |
| You choose "Anywhere (Tailscale)" | The same traffic, carried by Tailscale's WireGuard network | Your PC; Tailscale coordination servers see device names, addresses and connection times, and its relays may forward encrypted packets |
| You tap "Find PCs on Wi-Fi" | A UDP discovery broadcast | Devices on your local network |
| You use Wake PC | A Wake-on-LAN packet with your PC's network address | Your local network |
| You download an optional model pack (faces, objects, text) | A normal download request | The model hosts listed below; nothing about your media is sent |
| The app starts (GitHub release builds, "Check for updates automatically" on) | A request for `update.json`, and the update file when you tap Update | github.com and its download servers, which see your IP address; nothing about your media is sent |

Model packs come from fixed addresses on github.com, media.githubusercontent.com
(OpenCV Zoo) and huggingface.co, and each file is checked against a built-in
SHA-256 hash. Those hosts see your IP address and the file requested.

Nothing is sent in the background except what you turned on: camera backup
and the PC's background server run only after you enable them, and both are
shown in the app.

## What stays on the device

- The catalogue, albums, favorites, face groups and names, recognised text,
  object labels, places, thumbnails and video copies are stored in the app's
  private folder on that device.
- Locked Folder files are encrypted with your password (AES-256-GCM).
- On the PC, the server's TLS key and owner secret are encrypted for your
  Windows account. Paired phones are stored as public keys and salted token
  hashes, with an activity log of what each phone did.

You can delete face groups and the search index in Library → Analysis, remove
offline copies of PC files in My PC, remove a paired phone on the PC at any
time, and choose to delete all nexGallery data when you uninstall on Windows.
Originals are never deleted by these actions.

## Permissions (Android)

| Permission | Used for |
| --- | --- |
| Photos and videos, music and audio (`READ_MEDIA_*`, selected-photos access; `READ_EXTERNAL_STORAGE` up to Android 12) | Showing your library. With Android 14's "selected photos" choice only those items are shown |
| `WRITE_EXTERNAL_STORAGE` (Android 9 and earlier only) | Deleting or moving files you chose to change |
| Internet, network state | Connecting to your own PC, Wi-Fi-only transfer rules, optional model downloads |
| Camera (requested only when you scan) | Reading the pairing QR code; frames are not stored |
| Biometrics | Asking for your fingerprint, face or screen-lock PIN before emptying Trash |
| Set wallpaper | "Set as wallpaper" |
| Install apps (GitHub release builds) | Installing a nexGallery update you downloaded, after its SHA-256 matches the release |
| Wake lock (from the video player) | Keeping playback running while a video plays |

## Children

nexGallery is not directed at children and collects no personal data from
anyone.

## Contact

Publish the support e-mail address of the release owner here before
submitting to a store.
