# Google Play declarations

Prepared answers for the Play Console, based on the merged release manifest
and the network behaviour in [privacy](PRIVACY.md). The release owner reviews
and submits them; Play can still reject the broad media permission, in which
case MediaStore with the system photo picker remains the fallback (plan §18).

## Merged manifest permissions

Checked in `build/app/outputs/logs/manifest-merger-*-report.txt`.

| Permission | Source | Runtime prompt | Declaration needed |
| --- | --- | --- | --- |
| `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO` | app | yes | **Photo and video permissions** form |
| `READ_MEDIA_AUDIO` | app | yes | no |
| `READ_MEDIA_VISUAL_USER_SELECTED` | app | with the above | no |
| `READ_EXTERNAL_STORAGE` (max SDK 32) | app | yes | no |
| `WRITE_EXTERNAL_STORAGE` (max SDK 28) | app | yes | no |
| `CAMERA` | zxing-android-embedded 4.3.0 | when scanning | no |
| `INTERNET`, `ACCESS_NETWORK_STATE` | app | no | no |
| `SET_WALLPAPER` | app | no | no |
| `USE_BIOMETRIC` | app | no | no |
| `REQUEST_INSTALL_PACKAGES` | app (GitHub release builds) | settings switch | **Not allowed on Play**: remove it and build without `NEXGALLERY_UPDATES` for a Play release |
| `WAKE_LOCK` | androidx.media3 exoplayer | no | no |

Not requested: `MANAGE_EXTERNAL_STORAGE`, `ACCESS_MEDIA_LOCATION`, location,
contacts, notifications, foreground-service types, `QUERY_ALL_PACKAGES`.

## Photo and video permissions form

- **Core purpose:** nexGallery is a gallery app. It shows, organises, edits,
  searches and backs up the whole on-device photo and video library, and
  streams it to the user's own PC.
- **Why the photo picker is not enough:** the app needs persistent access to
  the full library to build the timeline, albums, Trash, duplicate and
  similar-photo cleanup, and opt-in camera backup. The picker returns single
  selections only.
- **Partial access:** Android 14+ "Select photos" is honoured; only selected
  items are shown, and the app offers to change the selection.

## Data safety form

Reviewed against Play's definitions; confirm before submitting.

- **Data collected by the developer:** none. There is no developer server.
- **Data shared with third parties:** none. Optional Tailscale use is set up
  by the user in Tailscale's own app; nexGallery does not send it any data.
- **Data transfers the user starts:** photos, videos and files go to the
  user's own PC over TLS. Describe this in the "Data handling" notes.
- **Encryption in transit:** yes (TLS 1.2+ with certificate pinning).
- **Deletion:** users delete data in the app and by uninstalling; there is no
  account to delete.
- **Model downloads:** standard file downloads from GitHub, OpenCV Zoo and
  Hugging Face; no user data is included.

## Content and listing

- Target audience: 13+ (general audience, not designed for children).
- Ads: none. In-app purchases: none.
- Privacy policy URL: host [PRIVACY.md](PRIVACY.md) on a public page first.
- Screenshots must not show real personal photos.
