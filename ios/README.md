# MP3 Shelf — Native iPhone App

A standalone **SwiftUI** iOS application that can be opened directly in Xcode and installed on a physical iPhone. It complements the existing MP3 Shelf Next.js web app, without replacing or altering the web app.

## Requirements

- Mac with Xcode 16.4 or later (recommended for the current signing and QA workflow; iOS 17 deployment target)
- iPhone running iOS 17 or later
- Apple ID added in Xcode → Settings → Accounts; free Personal Team signing is sufficient for device testing, subject to Apple's provisioning limitations

## Install on your iPhone

1. Unzip this project on your Mac, then open **`MP3Shelf.xcodeproj`** in Xcode.
2. In Xcode's project navigator, click the blue **MP3Shelf** project icon, then select the **MP3Shelf** app target and **Signing & Capabilities**.
3. Enable **Automatically manage signing**, select your own **Team** (Personal Team works), and change **Bundle Identifier** if Xcode reports a collision.
4. Connect your iPhone by cable or use an already paired wireless development device. Select it in Xcode's device picker. If prompted, enable **Settings → Privacy & Security → Developer Mode** on the iPhone and trust your Mac.
5. Press **⌘R** (Run). Xcode signs and installs the app. You can then import files and listen without a network connection.

## Signed installation helper (physical iPhone)

For a reproducible, signed development build without manually finding the
app bundle after compiling, first sign in to **Xcode → Settings → Accounts**
and enable automatic signing for your Apple team. Unlock and trust your
iPhone, enable Developer Mode if required, then in a Mac terminal at the repo root:

```bash
xcrun devicectl list devices
MP3SHELF_TEAM_ID=YOUR10CHARTEAMID bash ios/scripts/run-on-iphone.sh YOUR_DEVICE_UDID
```

The script validates the device connection, invokes Xcode's automatic
development signing, verifies that the resulting app includes a provisioning
profile and valid signature, installs it, launches it, and writes a private
`ios/build/iphone-device/QA_RECORD.md` describing which tests remain open.
`ios/build/` is Git-ignored; **never commit local logs, provisioning files
or Apple account credentials**. If the default bundle identifier is already
claimed by another developer team, specify your own unique ID using
`MP3SHELF_BUNDLE_ID=com.yourteam.mp3shelf`.

**Important:** This helper runs on a Mac attached to the real phone, not on
GitHub's unsigned CI. It creates an installed *development* app, not a TestFlight
upload or public release. The device acceptance scenarios are in
[DEVICE_QA.md](DEVICE_QA.md) and must be tested, recorded and reviewed before
PRs #1–#4 merge. Building for the iphoneos processor architecture alone does
not establish successful signing or installation.

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
5. Track metadata is matched against local MP3s. Missing songs require independent, legitimately acquired audio. There is **no unrestricted Spotify-to-MP3 converter**; only qualifying independent licensed sources can be downloaded.

Source documentation: [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [Spotify playlist-items API](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items), [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/apps), [Spotify Development Mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## One-tap downloads for imported Spotify playlists

Connect Spotify, select a permitted playlist or paste its Spotify share link, then press **Find & Save Offline MP3s**. The app automatically opens the song-by-song download dashboard and checks missing songs against independent authorized audio sources, downloading only qualifying MP3 files to its local storage. The process shows track-by-track progress and can be stopped. Downloads are matched to their original playlist order and are playable offline after completion. Keep the app open for source discovery. Already queued downloads may continue through iOS background transfers after locking the phone.

**Current catalog adapters:** Internet Archive, Openverse-backed eligible publishers, and direct Wikimedia Commons. Before importing a result, the app requires:
- Strict normalized *song title and artist* match; no intentional covers/remixes/other artists.
- A single MP3 file for the matching archive item, to reject album/concert downloads.
- A Creative Commons or public-domain license URL declared in the archive item's metadata.
- When Spotify supplied duration, audio-file duration metadata within four seconds.
- HTTPS download, decodable local audio, and a maximum 100 MB transfer.

Catalog licenses are declared by uploaders, **not independently verified by MP3 Shelf**. MP3 Shelf stores attribution links for discovered sources. Catalog metadata can be wrong; compare suspect recordings with their source page. Most commercial Spotify recordings do **not** have a legitimate freely downloadable match, and will remain unmatched. The app never bypasses paywalls or DRM, downloads Spotify streams, scrapes arbitrary converter sites, or silently replaces a requested song with a different recording. Spotify developer terms may impose additional restrictions on apps combining Spotify metadata and other audio services; obtain approval before a public production release.

## Expanded catalogs and background downloading

Q1 — Source search: The app now looks up missing playlist songs through Internet Archive and Openverse. Openverse indexes eligible recordings from Wikimedia Commons, Free Music Archive and ccMixter. Matches require strict artist/title, original publisher MP3 links on allowed HTTPS domains, acceptable filesize, declared Creative Commons/public-domain licensing and duration validation. Jamendo is excluded due to its restrictions for an offline music caching application. Archive and Openverse licensing metadata is uploader-provided, not a guarantee of ownership or permission. Many major-label recordings will have no qualifying source.

Q2 — Persistent downloads: The native app uses a background URLSession to download selected MP3s after they have been discovered. Transfer tickets are persisted in Application Support and retained across relaunches. The UIApplicationDelegate background-session callback restores the session on system launch; delegates immediately stage completed downloads, validate files, and attach them to the offline library, preserving playlist metadata, source links and original order. Users can cancel active background transfers.

Important limits: Source discovery is NOT a background service. Only already-queued file transfers can continue while locked/suspended. iOS chooses the timing of background transfer execution and relaunch; a user force-quit can prevent relaunch. Foreground source searches will stop when the OS suspends the app and must be resumed by the user. Actual lock-screen, relaunch, cellular/Wi-Fi, permissions and storage scenarios need physical-device tests.

Relevant code: AudioSourceFinder.swift, BackgroundAudioDownloader.swift, MusicLibrary.swift and MP3ShelfApp.swift.

## Resumable discovery and download management

**Automatic discovery resume:** Each imported playlist has an independent, atomically
saved checkpoint in Application Support (`source-discovery.json`) containing the
next unsearched track, queue counts and pause state. When MP3 Shelf becomes
active after suspension or an ordinary app restart, it continues unfinished
catalog lookups. User-paused searches do not auto-resume; use **Resume Source
Discovery** from the playlist. If a provider/network request fails, its
cursor is retained and search is retried on the next foreground activation.
Already queued background transfers are not duplicated on recovery.

**Download Manager:** Open **Settings → Download Manager**, or the download
icon inside a playlist, to view each authorized catalog MP3 transfer:
queued/downloading, saved offline, failed and cancelled; byte progress where
available; source/license links; individual Cancel and Retry; and
clear-finished-history without deleting audio. Retried transfers get new
identifiers so a late callback from a cancelled task cannot corrupt the new one.
Open **Settings → Manage Music Storage** for song-level sizes, total library
storage and deletion of local files. Removing a downloaded file preserves its
original imported Spotify playlist entry as an unmatched song.

**Q1 installation check:** GitHub's macOS workflow compiles the project,
installs/launches/terminates it in an iPhone Simulator, captures a screenshot
artifact, and runs parser/discovery tests. This is **not** a signed physical
iPhone build and cannot establish lock-screen or background-transfer behavior
on hardware. Follow [DEVICE_QA.md](DEVICE_QA.md) on a real phone before release.

**iOS restrictions:** Already-queued URLSession file downloads can continue
under iOS background scheduling. *New source searches* still require the
application to be active; automatic resume starts only at a future activation,
not while the process is suspended or force-quit. There is no guaranteed
continuous monitoring, uninterrupted search, or universal commercial MP3
availability.

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
swiftc MP3Shelf/Models/MusicModels.swift MP3Shelf/Services/PlaylistCSV.swift MP3Shelf/Services/AudioSourceFinder.swift Tests/AudioSourceFinderTests.swift -o /tmp/mp3shelf-source-tests && /tmp/mp3shelf-source-tests
```

## Architecture

- `Models/MusicModels.swift`: persistable library, tracks, playlists and import reports.
- `Services/MusicLibrary.swift`: local document import, metadata extraction, persistence and playlist matching.
- `Services/PlaybackController.swift`: audio session, queue, playback, remote commands, Now Playing data.
- `Services/PlaylistCSV.swift`: independently testable CSV/TSV parsing and metadata matching.
- `Services/SpotifyService.swift`: Spotify PKCE/Keychain and playlist metadata requests.
- `Services/AudioSourceFinder.swift`: strict independent Archive.org license-declared MP3 matching and lookup.
- `Services/LyricsParser.swift`: independent LRC / plain-text parsing.
- `Views/SpotifyViews.swift`, `Views/LyricsView.swift`: playlist importer and offline lyrics.
- `Views/`: SwiftUI library, playlists, full player, downloads, settings and Spotify playlist import.

No API secrets, ad SDKs, cloud services or external dependencies are bundled.
