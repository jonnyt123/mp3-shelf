# MP3 Shelf — iPhone Installation and Background Download QA

This checklist is the **physical-iPhone acceptance gate**. GitHub's macOS
simulator build is a separate, useful check and does not replace these tests.

## Preparation

1. On a Mac with Xcode 16.4 or newer, check out the **candidate native iOS branch** (`fix/ios-download-finalization-and-conversion` for PR #28). The default `main` branch still contains the older web PWA; PR #4 is an earlier intermediate iOS branch. Run `bash ios/scripts/verify-local-release.sh` from the repository root to record local Swift regression and native build results without GitHub Actions minutes. Running the script does not replace on-device tests.
2. Open `ios/MP3Shelf.xcodeproj`, choose the MP3Shelf app target,
   enable Automatically Manage Signing, and select your Apple development team.
3. Connect an iPhone with iOS 17+, unlock/trust the Mac, enable Developer Mode
   if prompted, and select the actual iPhone as the Xcode run destination.
4. Press **Run (⌘R)**, or execute the signed-install helper documented
   in [README.md](README.md):
   `MP3SHELF_TEAM_ID=YOUR10CHARTEAMID bash ios/scripts/run-on-iphone.sh DEVICE_UDID`.
   The helper verifies a development provisioning profile and signature,
   installs and launches the app, and writes
   `ios/build/iphone-device/QA_RECORD.md` locally (Git-ignored). It does not
   perform the end-to-end Spotify/audio acceptance tests below. Record the
   physical device, iOS version, tested commit and installation result.
5. Import a legally obtained MP3 and verify offline playback using Airplane Mode.
   Check lock-screen play/pause, seek, skip, Bluetooth/headphones, foreground and
   background audio, shuffle and repeat.
6. For network transfer tests, use an independent audio source whose creator
   explicitly authorized downloading. Do not use Spotify audio or unknown files.

## Playback queue editor and automatic download cap acceptance

1. Import a Spotify playlist with at least 15 qualifying, explicitly
   authorized independent recordings. On Wi-Fi, start auto discovery and
   verify at most **four** background transfer tickets remain queued at once.
   As each ticket finishes, the next discovery lookup should resume without
   losing the saved per-song cursor or creating duplicate downloads.
2. Use **Cancel All** while four tickets are active. The playlist's source
   discovery must stay paused, with no automatic replacement tasks until
   explicitly resumed. Restart the app and confirm the pause is preserved.
3. Interrupt Wi-Fi, restore connectivity, and verify existing bounded
   retries, alternative verified sources and iOS background completion still
   work. Explicit cellular permission must remain session-only.
4. From Now Playing, open **Manage playing queue**. Move an upcoming track
   earlier/later, choose Play next, play a selected item, then remove an
   upcoming item. Confirm the next playback order matches the visible sheet.
5. Reopen the saved playlist after editing the queue; its persisted order,
   favorites, local file count and downloaded files must be unchanged.
6. Test the queue sheet at large Dynamic Type sizes and with VoiceOver,
   including accessible action menus and medium/large sheet presentation.

## Large-library performance and data-integrity acceptance

1. Import 3,000+ locally owned audio files and a large Spotify metadata list.
   Measure Listen first load, search latency, sort switching, and playlist
   scrolling on the actual iPhone before and after this change.
2. Start local playback and leave Listen open for a full song; progress
   updates must not repeatedly sort the complete library or cause visible
   frame drops when navigating the library.
3. Import a playlist containing multiple versions of the same song name.
   Only the exact matching artist/duration recording should be linked;
   ambiguous candidates must remain unmatched.
4. Toggle favorites and edit title/artist. Search, title sort, artist sort,
   saved playlist rows, Now Playing and Up Next must reflect the changes
   immediately, not stale cached metadata.
5. Import a portable archive with artwork, then replace its artwork. Verify
   the image refreshes; remove a song and verify stale covers are not shown.
6. Load a 5,000-track library, scroll rapidly and check memory pressure.
   Verify that the artwork cache remains bounded and iOS does not terminate
   the app. Check library save/restore after a force-quit and relaunch.

## Shuffle and Up Next regression (PR: playback queue reliability)

1. Import six distinct local audio tracks; turn on Shuffle and Repeat Off.
   Play the first song, then press Next until the library finishes. Each track
   must play only once; the player must stop after the sixth song.
2. Enable Shuffle and Repeat All, then skip through another full cycle.
   A fresh cycle should be prepared without an immediate duplicate when more
   than one track is available.
3. In shuffle mode, play A → B → C. Press Previous within the first three
   seconds of C: the player should return to B, then to A. Press Next and
   confirm B is next (Back/Next history must be reversible).
4. Inspect the three Up Next entries before each skip. The next playable song
   must match the first preview entry when there is a pending shuffled song.
5. Toggle Shuffle while playback is active; verify the queue remains playable,
   the Now Playing preview changes, and the stored playlist order is unmodified.
6. Test Repeat One on a single song, crossfade near end of a two-song queue,
   lock-screen Previous/Next, Bluetooth playback and remote seek controls.
7. Delete a future queued song and skip forward. The player must ignore missing
   files instead of crashing or repeatedly choosing an invalid queue entry.

Foundation-only queue regression: `bash ios/scripts/test-playback-order.sh`.
Passing this script does not replace listening and navigation tests on iPhone.

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

## Spotify → individual MP3 end-to-end acceptance (current candidate)

Record the exact tested PR #4 commit and real iPhone model before starting.
Use only independent recordings that actually authorize downloading; never use
Spotify audio streams, search-engine scraping, or a different artist's recording.

1. Connect an eligible Spotify test account and paste its permitted 22-character
   playlist share link. Confirm the app automatically imports the song metadata,
   starts MP3 source discovery and **opens the song-by-song dashboard** without a
   second action.
2. Re-import the same link while discovery or downloads are running; confirm
   that it reuses the **same playlist ID** and does not reset a valid transfer.
3. Use a playlist with a deliberately available, explicitly licensed exact-match
   recording in Internet Archive, Openverse or Wikimedia Commons. Verify the
   matching source page, creator, CC/CC0 license, MP3 format and track duration.
4. Confirm a uniquely named .mp3 file appears under Files → On My iPhone →
   MP3 Shelf → Music. Inspect its extension and playable duration, switch on
   Airplane Mode, play offline, and confirm the dashboard says saved.
5. Include an unavailable commercial song and a plausible cover/live recording.
   Confirm neither gets quietly substituted. Check **No qualifying MP3 source**
   for the unavailable track and its playlist position preserved.
6. Lock the phone during an eligible download, reopen, and check Download Manager
   byte-level progress and completed import. Retry a failed transfer and ensure
   that the newer ticket supersedes the failed ticket.
7. Test cellular/Wi-Fi interruption, catalog timeout, 404 or HTML masquerading
   as MP3, near-full storage, and app relaunch. Network problems must remain
   retryable, not be misreported as a definitive "not found".
8. Verify original native .mp3 files remain unmodified. Re-import a playlist
   after some MP3s are present and make sure recordings and playlist rows are
   not duplicated.
9. Capture non-sensitive evidence (selected source URL/license, song match
   status, device/iOS version, Files directory listing, and redacted logs)
   in issue #6. Mark each step PASS/FAIL/NOT RUN without guessing.

Automated unsigned `iphoneos` compilation is useful architecture coverage
but **cannot** validate Apple signing, install, live Spotify OAuth/provider
network access, actual system background scheduling or offline playback on
physical hardware. These remain external release blockers until run on device.

## Test record (fill out during real device run)

- Date / iPhone model / iOS version:
- Xcode version / signing team:
- Simulator smoke check:
- Physical install: NOT YET VERIFIED (signed Xcode/devicectl run on a real iPhone required; unsigned CI does not count)
- Offline playback / lock screen: NOT YET VERIFIED
- Interrupt/resume search: NOT YET VERIFIED
- Locked transfer: NOT YET VERIFIED
- Network switch / relaunch: NOT YET VERIFIED
- Download manager / storage cleanup: NOT YET VERIFIED
- Source license / Spotify integration review: NOT YET VERIFIED

Do not mark the native app production-ready until these physical-device tests
and provider/platform compliance checks have been performed.

## Interruption and route-loss acceptance (PR #28)

- While playing, receive a call or invoke Siri: audio pauses and the UI reports paused. Resume only when the system permits it.
- Repeat with playback already paused: audio must stay paused.
- During an interruption, use Pause or Stop: ending the interruption must not restart audio.
- Unplug wired headphones or disconnect Bluetooth: pause without continuing over the speaker. Reconnecting must not start playback automatically.
- Repeat during a crossfade: both decks stop, and a permitted resume uses only the incoming track at normal volume.
- Repeat with the app backgrounded; check Lock Screen elapsed time and playback state.

Native compilation, notification delivery order and physical audio behavior remain NOT VERIFIED until recorded on a Mac/iPhone.

Playback failure checks: move a test song file out of the app Music directory, attempt to play it while another song is playing, and confirm the existing song/queue remain active and an error is visible. Restore the file and use Retry. Repeat from Now Playing and during crossfade; a failed crossfade must not retry every timer tick. Never delete your only copy of a recording for this test.

Consolidation follow-up: fill the download slots during an in-flight catalog lookup and confirm the discovery cursor does not advance. Check that a retry changes from Retrying to Downloading when bytes arrive; unknown-size transfers must show received bytes. Interrupt finalization, relaunch, and use Finish saving if staging remains. Verify resume failure displays a retryable error.

Playlist/player controls: from Downloads, pause a playlist search while transfers remain queued; confirm only search pauses. Resume, then confirm Cancel transfers pauses search and cancels only that playlist, preserving saved songs. Search again must target missing songs. While scrubbing Now Playing, change tracks with Lock Screen controls and confirm the scrubber draft resets. Test 15-second seek buttons near both song boundaries and during crossfade, plus VoiceOver and accessibility text sizes.

Availability/browsing: move a test audio file out of Music, then choose Downloads > Recheck saved audio. Its Spotify wish must become missing and eligible for source search, while library metadata and manual playlist additions remain intact. Restore/reimport it and recheck. Verify album sorting, filtered Play results and Shuffle results, Favorites with no results, and large text layouts.

Playlist organization/reliability: search and alphabetically sort playlists, rename one while filtered and confirm its identity, order and source link persist after relaunch. Delete a playlist with active transfers: its transfers and discovery must stop, other playlists must continue, and saved music must remain. Download permitted MP3, M4A/AAC, WAV/AIFF and FLAC responses and verify real decoding/conversion; HTML/JSON must remain rejected. MIME admission alone is not proof of playable codec or recording identity.

Retry/playback review: with four transfers active, individual and batch retry must not add a fifth. Free one slot and retry a failed item: its replaced row must disappear. Batch retry must leave cancelled items untouched and respect paused source search. Deleted-playlist history must not restart transfers. Quickly switch tracks near completion and verify a late completion/decode-error callback from the old player cannot alter the new track. Decode failure must show the visible retry error.

Status/polish checks: remove a test audio file while retaining library metadata and a historical imported ticket; the playlist count/status must not claim that recording is saved. Confirm queued, retrying, staged and finalizing labels agree between playlist detail and Downloads. Test library playback actions at accessibility text sizes, selected sort label, empty-search Show all music, and VoiceOver elapsed/remaining labels.

Queue retry/progress checks: select a song in a small filtered playlist whose file is temporarily unavailable, restore it and tap Retry. Up Next must remain scoped to the attempted playlist rather than expanding to the full library. Repeat with shuffle enabled and with a deleted retry target. Confirm playlist saved/total progress checks real file availability, and historical failed/cancelled transfer totals are not mistaken for unique missing-song counts.

Cancellation/copy follow-up: cancel an idle staged download, clear its history, then allow a delayed URLSession finish callback; no orphan file or imported song should remain for that ticket. Repeat during conversion and verify cancellation cleanup. Make a local copy of a Spotify playlist, including missing entries; change or delete the copy without modifying the original, and confirm Spotify refresh still targets the original. Native callback delivery and conversion cancellation remain device-only acceptance checks.

Diagnostic/refresh checks: exercise 403, 404/410, rate limiting, HTML instead of audio, timeout and local disk-full/write failure. Error messages should identify the failure and recovery action; local storage failures must not begin alternate-source transfers. Import a playlist whose matching library metadata has a missing physical file and confirm that wish remains missing. Refresh pending title/duration metadata without adding IDs, relaunch, and confirm corrected metadata and the existing cursor/history persist.
