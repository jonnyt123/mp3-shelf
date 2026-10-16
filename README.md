# MP3 Shelf

An iPhone-first, installable web app that imports many MP3s in one Files picker and keeps them in a searchable offline library. It includes persistent playlists, shuffle, repeat-one/repeat-all, previous/next controls, and automatic next-track playback.

MP3 Shelf reads ID3 title, artist, album, and embedded cover artwork locally during import. It also includes first-launch onboarding, track renaming, and playlist reordering.

Tap the mini-player to open a full-screen now-playing view with large artwork, elapsed and remaining time, precise scrubbing, and complete playback controls.

Safari users can open the native AirPlay destination picker from the full player. Desktop browsers also get an in-app volume slider; iPhone displays side-button volume guidance because iOS controls media volume at the system level.

Media Session integration supplies title, artist, album artwork, playback state, position, seeking, and previous/next actions to supported Lock Screen and system media controls. In the full player, swipe down across the artwork to close or swipe horizontally to change tracks.

Open **Storage & backup** from the top-right menu to see music usage, total origin storage, and the allowance reported by the browser. Exports use MP3 Shelf's `.mp3shelf` archive format, which preserves MP3 bytes, artwork, metadata, and playlists without base64 expansion. Restore validates the complete archive manifest before atomically adding or updating tracks; it does not delete music already on the device.

## Run locally

```bash
npm install
npm run dev
```

On iPhone, deploy over HTTPS, open it in Safari, then use **Share → Add to Home Screen**.

The service worker pre-caches the rendered app shell, including Next.js JavaScript and CSS, then caches same-origin assets as they are requested. Imported MP3 blobs remain in IndexedDB, so the installed app and its library can launch and play without a network connection after one successful online visit.

## What iOS allows

Safari cannot scan Files automatically. The user must grant access through Apple's picker. MP3 Shelf uses multiple selection so a group can be imported at once, then stores copies in IndexedDB. Clearing Safari website data or iOS storage eviction can remove local tracks.

## Optional Supabase sync

The MVP is local-first and needs no account. `supabase/migrations/0001_cloud_library.sql` defines a private per-user catalog and Storage bucket for later cloud sync. Large audio uploads should use Supabase's TUS resumable endpoint.

## Verification

```bash
npm test
npm run typecheck
npm run build
```

## Spotify playlist import in the web app

Tap **Import a Spotify playlist** below **Choose MP3s**.

**Without Spotify configuration:** Choose a CSV or TSV export containing `Track Name`, `Artist Name`, `Album Name`, and optionally `Track URI`. MP3 Shelf creates a local playlist, matches already-imported recordings conservatively, and shows songs still needing legal audio files. Importing more owned MP3 files later updates the matches.

**Direct Spotify account connection:** Register a Spotify developer app with exact redirect URI `https://mp3-shelf.vercel.app/` and set the public `NEXT_PUBLIC_SPOTIFY_CLIENT_ID` in the deployment environment, then deploy that configuration. Browser sign-in uses OAuth Authorization Code + PKCE without a client secret; access tokens are held in memory. The 2026 Spotify development-mode API supports track listing for playlists the account owns or collaborates on, and developer accounts have additional limits. Use CSV/TSV for other playlists. Verify Spotify accepts the redirect URI before enabling connection.

**Spotify streams cannot be converted, downloaded or ripped.** A playlist import stores track metadata only and matches independent audio files already present on your device. Spotify URLs link back to the original source. Backup archives preserve playlist metadata but never store Spotify access tokens.

## Feature parity

Native SwiftUI code and the installable web PWA live in this repository. See [FEATURE_PARITY.md](FEATURE_PARITY.md) for implemented features, verification and remaining differences.

## Additional web features under parity development

- **Authorized direct MP3 URL:** Paste a direct HTTPS MP3 URL under the main import controls and tap **Save MP3**. Browser CORS permissions must allow the transfer. Streaming links (including Spotify) are blocked. Downloads are limited to 100 MB and saved to local IndexedDB; this is not native background downloading.
- **Lyrics:** While a song plays, open the full-screen player and choose **Lyrics**. Import a `.lrc` timed lyric file or plain `.txt` file under 500 KB. Lyrics are stored with the song, synchronized against the player's elapsed time if timestamps exist, and included in `.mp3shelf` backups.
- **Feature gaps:** The browser still lacks native-style licensed-source catalog searches, native background URLSession downloads, native audio crossfade, and cross-platform backup compatibility. The full status is maintained in [FEATURE_PARITY.md](FEATURE_PARITY.md).

## Discover openly licensed music (web preview)

The **Discover open music** section searches Openverse's public audio catalog for
work described with CC0, PDM, CC BY or CC BY-SA licensing. Results have links
to the **original source** and **license terms**, which listeners should verify
before reusing or saving recordings. Results that contain a likely direct MP3
link offer **Save MP3**; other entries link to their source page.

Direct MP3 imports are foreground browser transfers, show byte progress,
can be cancelled, and have a 100 MB size cap. Browser CORS restrictions
still apply; this does not copy protected streaming audio or guarantee that
every catalog result is downloadable. A download that does succeed is stored
locally for offline use.

For imported catalog recordings, the web library preserves **creator,
provider, source page, and declared license** in IndexedDB and backup
exports. Tap the information icon on a saved track to review its credits.
Re-importing the same file no longer overwrites its existing favorite,
custom title, saved lyrics or source credits.

Openverse is an independently maintained index; MP3 Shelf does not
independently authenticate every original uploader's rights or verify every
license claim. Cite and respect the original source's license obligations.
