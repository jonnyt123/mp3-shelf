# MP3 Shelf — Native iPhone App

A standalone **SwiftUI** iOS application that can be opened directly in Xcode and installed on a physical iPhone. It complements the existing MP3 Shelf Next.js web app, without replacing or altering the web app.

## Requirements

- Mac with Xcode 15.4 or later (iOS 17 deployment target)
- iPhone running iOS 17 or later
- Apple ID added in Xcode → Settings → Accounts; free Personal Team signing is sufficient for device testing, subject to Apple's provisioning limitations

## Install on your iPhone

1. Unzip this project on your Mac, then open **`MP3Shelf.xcodeproj`** in Xcode.
2. In Xcode's project navigator, click the blue **MP3Shelf** project icon, then select the **MP3Shelf** app target and **Signing & Capabilities**.
3. Enable **Automatically manage signing**, select your own **Team** (Personal Team works), and change **Bundle Identifier** if Xcode reports a collision.
4. Connect your iPhone by cable or use an already paired wireless development device. Select it in Xcode's device picker. If prompted, enable **Settings → Privacy & Security → Developer Mode** on the iPhone and trust your Mac.
5. Press **⌘R** (Run). Xcode signs and installs the app. You can then import files and listen without a network connection.

## What works

- Import multiple MP3, M4A, AAC, WAV and AIFF files from the iOS Files document picker. Audio is copied into the app's Documents/Music folder.
- Display ID3/common metadata and embedded artwork when available; edit local song title/artist.
- Persistent library with search, favorites, custom playlists and playlist reorder/removal.
- Local audio playback via `AVAudioPlayer`; background audio mode, Control Center and Lock Screen media metadata and play/pause/skip/seek controls.
- Full-screen player with scrubber, shuffle, repeat modes, and mini player.
- Download **direct HTTPS audio files that you have permission to download**. No streaming service ripping.
- Import a `.csv` or tab-separated `.txt`/`.tsv` **track list** from a Spotify playlist, matching by title and artist to already-imported local songs; preserve unmatched song names for later matching.
- Optional original Spotify playlist link, so playlist attribution links back to Spotify.
- All playable audio stays on the phone. No server, Supabase, accounts, or internet required after import.

## Spotify account connection (requires online access)

Spotify sign-in uses OAuth Authorization Code **with PKCE** and iOS `ASWebAuthenticationSession`. It does not embed a Spotify client secret or upload your files. Refresh tokens are stored in the device Keychain. An optional CSV/TSV fallback works without Spotify.

1. Create an application at [Spotify for Developers](https://developer.spotify.com/dashboard). Enable the Web API and register the **exact** redirect URI `mp3shelf-auth://callback` (Spotify's mobile-app documentation allows a dedicated custom URL scheme). Set iOS bundle identifier to `com.jonnyt.mp3shelf` or your selected Xcode bundle ID.
2. In Spotify's Development Mode, the app owner currently needs Spotify Premium and the app is limited to up to five allowlisted testers. Add each user in the Spotify dashboard before sign-in.
3. Open MP3 Shelf → Import → **Connect Spotify Account**. Enter the **Client ID**, sign in, and select a playlist.
4. Only playlists owned by or collaborative with the signed-in user can expose their items under Spotify's 2026 API rules. Other followed playlists can return HTTP 403; use the CSV fallback for track lists you are permitted to export.
5. Track metadata is matched against local MP3s. Missing songs require independent, legitimately acquired audio. There is **no automatic Spotify-to-MP3 downloader**.

Source documentation: [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [Spotify playlist-items API](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items), [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/apps), [Spotify Development Mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## Audio enhancements

- **Crossfade**: Settings → Playback → Song crossfade (0–10 seconds). Uses overlapping local `AVAudioPlayer` instances with equal-power ramps. Enabled only when another song is available.
- **Lyrics**: Now Playing → Lyrics → Import LRC; supports timestamped `.lrc` with active line highlighting, plus plain `.txt`. Files are kept in Application Support for offline access.
- **Artwork**: Extracts embedded image data directly from imported audio; no network lookup or altered Spotify artwork.
- **Equalizer**: **not implemented** in this version. A real audio-frequency EQ requires a reworked `AVAudioEngine` playback pipeline, not a cosmetic preset selector. Keep playback stable until the engine can be tested on an iPhone.

## Data, compatibility and limitations

- The file import is a **copy**. Deleting the original from Files does not remove the copy in MP3 Shelf.
- Audio files are visible from Finder's iPhone file sharing area where supported. The library database (`Application Support/MP3Shelf/library.json`) is part of the app container and is protected by normal iPhone backups.
- The web MP3 Shelf's `.mp3shelf` archive backup format is **not currently compatible** with the iOS application.
- Playlist CSV import is metadata matching, **not Spotify-to-MP3 conversion**.
- No equalizer, network artwork lookup, iCloud synchronization or CarPlay scene is included in this release.
- Due to environment limitations, this project was generated without a Mac `xcodebuild` / physical iPhone run. An on-device build and background playback test remain required before calling it production-ready.

## Independent parser tests

On macOS or Linux with the Swift toolchain:

```sh
swiftc MP3Shelf/Models/MusicModels.swift MP3Shelf/Services/PlaylistCSV.swift Tests/PlaylistCSVTests.swift -o /tmp/mp3shelf-parser-tests && /tmp/mp3shelf-parser-tests
swiftc MP3Shelf/Services/LyricsParser.swift Tests/LyricsParserTests.swift -o /tmp/mp3shelf-lyrics-tests && /tmp/mp3shelf-lyrics-tests
```

## Architecture

- `Models/MusicModels.swift`: persistable library, tracks, playlists and import reports.
- `Services/MusicLibrary.swift`: local document import, metadata extraction, persistence and playlist matching.
- `Services/PlaybackController.swift`: audio session, queue, playback, remote commands, Now Playing data.
- `Services/PlaylistCSV.swift`: independently testable CSV/TSV parsing and metadata matching.
- `Services/SpotifyService.swift`: Spotify PKCE/Keychain and playlist metadata requests.
- `Services/LyricsParser.swift`: independent LRC / plain-text parsing.
- `Views/SpotifyViews.swift`, `Views/LyricsView.swift`: playlist importer and offline lyrics.
- `Views/`: SwiftUI library, playlists, full player, downloads, settings and Spotify playlist import.

No API secrets, ad SDKs, cloud services or external dependencies are bundled.
