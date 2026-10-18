# MP3 Shelf — iPhone Installation and Background Download QA

This checklist is the **physical-iPhone acceptance gate**. GitHub's macOS
simulator build is a separate, useful check and does not replace these tests.

## Preparation

1. On a Mac with Xcode 16.4 or newer, check out `feat/ios-premium-visual-refresh` (the PR #4 head, not the older discovery-only branch).
2. Open `ios/MP3Shelf.xcodeproj`, choose the MP3Shelf app target,
   enable Automatically Manage Signing, and select your Apple development team.
3. Connect an iPhone with iOS 17+, unlock/trust the Mac, enable Developer Mode
   if prompted, and select the actual iPhone as the Xcode run destination.
4. Press **Run (⌘R)**. Record the device, iOS version, and Xcode build output.
5. Import a legally obtained MP3 and verify offline playback using Airplane Mode.
   Check lock-screen play/pause, seek, skip, Bluetooth/headphones, foreground and
   background audio, shuffle and repeat.
6. For network transfer tests, use an independent audio source whose creator
   explicitly authorized downloading. Do not use Spotify audio or unknown files.

## Source-search recovery (Q2)

1. Import a CSV with several authorized catalog-matching songs. Start discovery.
2. While a search is in progress, background the app and allow the OS to suspend
   it; then reopen. Verify the queue continues from its saved per-playlist cursor
   and does not enqueue duplicate transfers.
3. Terminate the app via Xcode while a search is in progress; reopen and verify
   the playlist resumes outstanding searches without re-running completed songs.
4. Tap **Pause source discovery**; leave and reopen. It must stay paused.
   Tap **Resume** and verify work continues.
5. Disable network during discovery; inspect the error and turn network back on.
   On reactivation, interrupted work should resume. Test more than one playlist.

## Lock-screen/background transfer (Q1)

1. In **Download Manager**, verify an authorized MP3 enters Queued/Downloading
   and displays a measured byte count where the origin supplies one.
2. Lock the device without force quitting the app. Verify the transfer completes
   and the exact intended recording becomes playable offline.
3. Retry with a slow (authorized) download; change Wi-Fi to cellular, then back,
   checking that the system continues or defers it and eventually completes.
4. Test ordinary OS eviction/relaunch: allow iOS to terminate the app while
   suspended (do not swipe it away); verify downloaded files are staged and
   imported after the delegate or next foreground launch.
5. Test per-song **Cancel**, then **Retry**, including relaunch between actions.
6. Test HTTP 404, redirect to HTML, truncated MP3, wrong duration, and low
   storage. Files must not appear as successfully imported.
7. **Force quit caveat:** Apple generally suppresses background app relaunch
   after a user swipes away the app. Do not interpret this as a download bug.

## Download manager/storage (Q3)

1. Verify per-song statuses, progress, source attribution, cancel, retry and
   clear-history controls. A cancelled transfer must not silently restart.
2. Verify storage totals change after downloading and deleting a file.
3. Delete a locally downloaded track referenced by an imported playlist: it
   should reappear as unmatched, while the original playlist order survives.
4. Close/reopen the app and verify completed history, pending items and sizes.
5. Verify unrelated audio, artwork and playlists are unchanged.

## Portable backup / restore acceptance (Q1)

1. On the iPhone, import at least three different authorized audio recordings;
   add favorites, lyrics, artwork, and two playlists with distinct track orders.
2. **Prepare portable backup** from Settings. While the archive streams, verify
   the interface remains responsive, then save the share-sheet result to Files.
3. Re-import that backup without deleting the current library. Ensure recordings
   remain single-copy, playlists are not duplicated, and user-customized playlist
   order is retained.
4. Import a separately created web `.mp3shelf` archive with non-UUID track and
   playlist IDs. Verify exact audio playback, artwork, title, artist, favorites,
   and playlist order; export again and verify IDs are stable in the web app.
5. Repeat the web import after editing a local song title. Existing audio should
   be reused rather than creating another song. If an earlier import partially
   failed, retry and confirm missing playlist links are reconstructed.
6. Try an invalid archive, truncated payload, an archive with a dangling playlist
   song ID, and a same-size recording containing different audio bytes. Confirm
   no incorrect track links or silent replacements.
7. Test a large archive, Files access from an external provider, low-storage
   conditions, interruption and relaunch. Verify errors are surfaced and any
   newly imported intact songs remain playable.

## Premium design / accessibility acceptance (Q2)

1. Review all four tabs and Now Playing on a smaller iPhone and a current
   larger-screen iPhone, in both light and dark system appearance.
2. Test largest accessibility Dynamic Type sizes: artwork must not crush the
   library hero and the playlist grid must become a single readable column.
3. Verify VoiceOver names/values for playback, shuffle, repeat, filters, backup,
   playlist counts and destructive controls. Confirm sufficient contrast.
4. Long-press a playlist and choose Delete. Confirm a destructive dialog is shown
   and Cancel leaves both playlist and files untouched; deleting a playlist does
   not remove its saved audio.
5. Search songs, artists and albums with whitespace, enable Favorites, sort each
   ordering, and verify the play queue is consistent with the visible list.
6. Check reduced transparency, Reduce Motion, AirPlay route controls and
   Lock Screen controls while background audio is active.

## Release integrity gate (Q3)

- GitHub CI must pass **Debug and Release unsigned simulator builds**, parser,
  licensed-source matching, background discovery, archive regression tests,
  launch/install smoke checks and all eight screenshots at the same head SHA.
- Simulator success validates neither on-device code signing nor real background
  scheduling, system-media controls or actual Spotify/provider access.
- Physical iPhone acceptance and provider/platform compliance remain required
  before any production-ready, TestFlight or App Store assertion.
- Only merge stacked PRs in dependency order after checks have passed and
  unresolved release-critical regressions are addressed.

## Test record (fill out during real device run)

- Date / iPhone model / iOS version:
- Xcode version / signing team:
- Simulator smoke check:
- Physical install: NOT YET VERIFIED
- Offline playback / lock screen: NOT YET VERIFIED
- Interrupt/resume search: NOT YET VERIFIED
- Locked transfer: NOT YET VERIFIED
- Network switch / relaunch: NOT YET VERIFIED
- Download manager / storage cleanup: NOT YET VERIFIED
- Source license / Spotify integration review: NOT YET VERIFIED

Do not mark the native app production-ready until these physical-device tests
and provider/platform compliance checks have been performed.
