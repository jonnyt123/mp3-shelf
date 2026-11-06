# MP3 Shelf — Native iPhone App

## Apple Music playlist import

Open **Add Music → Your Apple Music playlists**, allow Media & Apple Music
access, select a playlist and tap **Find & Save Offline MP3s**. The playlist must
appear in the iPhone Music app's library; add a shared playlist there and let it
sync first if needed. No MusicKit developer token or new signing entitlement is
required by this metadata-only integration.

MP3 Shelf reads titles, artists, albums, durations and song order with MediaPlayer.
Cloud and protected items are included for their metadata; asset and preview URLs
are never extracted from Music. The existing recording matcher finds audio sources
and feeds the background downloader/MP3 converter. Existing source availability,
review, Wi-Fi/cellular and conversion limits still apply.

Reimporting updates the same local playlist while retaining repeated occurrences
and completed work. Library IDs have an installation namespace to avoid collisions
when a native backup is restored on another device. Native backups retain Apple
Music identities and matching metadata; local playlist copies remain independent.
Missing metadata and unsupported non-music entries stop an import with an error
rather than silently trimming the source list. **Native compilation, MediaPlayer
access and a complete iPhone download still require physical-device verification.**

## On-device recording matcher and download engine

The native app now owns recording search, normalization, scoring, candidate
selection and retry policy. Spotify supplies the playlist metadata. MP3 Shelf
searches YouTube on the iPhone, compares title, credited artist, recording
version and duration, then resolves a selected recording to audio. This primary
path needs no Brave search key and no Mac running while you use the app.

Exact artist/title matches with a compatible duration can download automatically.
Near matches and equally strong candidates stay available under **Review recording
matches**. Covers, different edits/remasters, previews and ongoing livestreams
are rejected. Spotify artist arrays preserve primary-artist identity without
splitting band names at commas. The resolved video's own metadata is checked
again before a transfer starts.

The small, app-owned `ShelfMatching` C package implements the scoring rules.
Vendored MIT-licensed YouTubeKit 0.4.8, pinned in
`Packages/YouTubeKit/PROVENANCE.md`, supplies low-level local extraction only.
Its optional remote extraction service is never selected. AAC audio enters the
existing background URLSession queue and checked AVAudioFile/LAME MP3 converter;
changing the extension alone does not create an MP3. Candidate IDs persist so
manual retry can refresh an expired signed URL. Automatic source recovery is
limited to three attempts per song in a discovery run.

Wi-Fi remains the default. Search and extraction inherit the playlist's explicit
cellular setting, and manual retry resolution counts against the four-transfer
limit. Closing the review sheet cancels its lookup; removing a song or playlist
cannot resurrect its transfer. Keep the app open for predictable source lookup;
queued file transfers use the existing iOS background behavior.

Run `bash ios/scripts/test-recording-matcher-core.sh` for the portable matching
core. The Mac verifier also includes `RecordingMatcherTests.swift` and recovery
checkpoint regressions. **Native compilation, extraction and a completed iPhone
playlist download remain unverified in this environment.** Public search HTML
was checked successfully, which does not establish successful audio extraction.

## Large music library and Spotify import performance

The app maintains a revision-aware in-memory index of local recordings:
UUID lookup and playlist song resolution no longer scan the entire song
collection for every row. Title-bucketed Spotify matching avoids repeating
full-library scans while preserving strict artist, title, edit-duration and
ambiguity protections. Existing playlist order and stable track IDs are
unchanged.

The Listen screen now reuses **Title**, **Artist** and **Recently added** sorted
snapshots until the library actually changes. This avoids re-sorting thousands
of recordings on each playback progress update or view refresh. Embedded
artwork decoding uses an evictable **32 MiB NSCache** rather than reopening
the same cover file for every visible row. The cache is invalidated when an
existing artwork file is overwritten or removed.

`ios/Tests/PlaylistCSVTests.swift` includes a 3,000-track matching regression
against the original exhaustive matching algorithm, checking exact results,
versioned durations and ambiguous duplicates. Full Xcode, on-device memory
pressure and scrolling QA are still required before release.

## Reliable shuffle and queue navigation

The native player now uses a **shuffle bag** instead of choosing a fresh random
song on every skip. Each track in the current playlist plays at most once per
shuffle cycle, unless you explicitly choose a track yourself. **Repeat Off**
stops at the end of the shuffle cycle; **Repeat All** shuffles a new cycle;
**Repeat One** replays the current track when it ends.

**Back** returns through the actual listening history in shuffle mode, and
**Next** after Back restores the song you just left. The Now Playing **Up Next**
preview reads the real pending order rather than displaying the original
playlist sequence. Playback does not alter the user's saved playlist order;
files deleted from the library are skipped gracefully. Shuffle and repeat
continue to work with lock-screen controls and crossfade transitions.

The shuffle order is intentionally session-only (not persisted after force-quit
or app relaunch). Run the Foundation-only queue regression suite without any
GitHub Actions minutes:

```bash
bash ios/scripts/test-playback-order.sh
```

This test checks the queue logic only. Xcode simulator builds, actual audio
transitions, AirPlay and physical-iPhone behavior still require native QA.



A standalone **SwiftUI** iOS application that can be opened directly in Xcode and installed on a physical iPhone. It complements the existing MP3 Shelf Next.js web app, without replacing or altering the web app.

## Wi-Fi-only background source-discovery batches

Once a Spotify playlist is imported, the app persists the song-lookup queue.
Normal URLSession background tasks can download already-discovered MP3s
while the phone is locked. On a background URLSession-only relaunch (without
a SwiftUI scene), the application delegate now keeps a headless MusicLibrary
alive through completion of file validation and import, so verified audio
does not stay stranded as a staged file until the user manually reopens
the app. **Finding** the next audio source previously
required the app to be foregrounded. The app now registers a permitted
`BGProcessingTask` during launch and requests an opportunistic network-enabled
background window when a playlist still has unprocessed songs and the app
moves to the background. The task checks actual Wi-Fi connectivity, processes
at most five pending tracks, persists every resulting lookup, and submits
another background request if more work remains. Each background window
rotates to the next eligible playlist and scheduling respects persisted catalog
retry deadlines instead of spending system windows on premature retries.
The background batch owns
the discovery queue until it finishes, so a Wi-Fi status notification cannot
start an overlapping foreground search or bypass its five-song limit.
A headless URLSession wake can import completed MP3s without enabling an
unbounded search; only an active app scene starts foreground discovery. User-paused playlists and
persisted provider retry backoff are respected.

Apple decides **whether and when** a BGProcessingTask executes, and can
end it early; this is best-effort resume, not guaranteed immediate/continuous
downloads after locking the screen. Catalog requests run Wi-Fi-only in these
background windows even if cellular was manually enabled earlier. Already
queued iOS background transfers continue under their own request policies.
Background file transfers reject declared or observed payloads larger than
100 MB as soon as URLSession reports the size, and progress UI updates are
coalesced to avoid unnecessary SwiftUI re-rendering during high-speed Wi-Fi
transfers.
Background task execution requires iOS to permit background app activity;
force-quitting or system restrictions can prevent it. Importing Spotify
metadata still requires online authentication, and no DRM/Spotify streams
are downloaded.

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

## Local native release verification (no GitHub Actions minutes)

The consolidated native candidate is on `feat/ios-consolidated-candidate`
(draft PR #29), including the earlier download, playback and library changes.
Check out this candidate branch in your local clone. You can
also use GitHub's **Code → Download ZIP** after choosing that branch. Opening
`ios/MP3Shelf.xcodeproj` on default `main` will not include these new features.

On a Mac with full Xcode selected, run:

```bash
bash ios/scripts/verify-local-release.sh
```

This executes all nine native Swift regression suites, the C matching core, unsigned Simulator
Debug and Release builds, and an unsigned physical-iPhone architecture Release
build **locally**. It never queues a GitHub Actions workflow. Add `--smoke` to
install and launch the Debug app on a locally installed iPhone Simulator and
capture eight UI screenshots; screenshots still require manual visual review.
Use `--tests-only` to run just portable Swift suites or `--builds-only` to
compile the three native configurations. Logs, binaries and a truthful
`QA_RECORD.md` appear only under `ios/build/local-release/` (Git-ignored).

This is neither an Apple-signed development app nor an on-device background
transfer test. To install on a real iPhone, use the separate signing helper
below and complete `DEVICE_QA.md`. GitHub branch protection and release checks
are not bypassed.

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
5. Track metadata is matched against local MP3s. Missing songs enter the on-device recording matcher, followed by public audio catalog fallback. Direct audio-file links remain available. License labels are not required for matching files.

Source documentation: [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow), [Spotify playlist-items API](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items), [Spotify redirect URIs](https://developer.spotify.com/documentation/web-api/concepts/apps), [Spotify Development Mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).

## One-tap downloads for imported Spotify playlists

Connect Spotify, choose a playlist or paste its Spotify share link, then press **Find & Save Offline MP3s**. MP3 Shelf imports the song list and runs its recording matcher first. If it cannot resolve a clear match, public audio catalogs provide additional sources. Saved recordings are attached in playlist order. Keep the app open for discovery; queued files can continue through iOS background transfers after locking the phone. When candidates need a decision, open the song's **Review recording matches** action.

**Matching requirements:** Normalized song title and artist must match, and the result must identify one downloadable recording. HTTPS, a supported audio format, the 100 MiB transfer limit and actual decoded duration checks remain. Album items can qualify when exactly one original MP3 filename identifies the song. License metadata is optional attribution: a missing or non-Creative-Commons label does not exclude an otherwise matching file. Source links remain available even when there is no license link.

**Current catalogs:** Internet Archive, Openverse-backed supported publishers, Wikimedia Commons, Audius download endpoints and ccMixter RSS. Search is bounded for battery life and provider rate limits. Archive detail reads are capped at eight per page and two pages; no new request starts after its 45-second lookup window. Archive file sizes come from `files[].size`, not `files[].length` (which can contain decimal duration). Openverse checks up to two pages per focused or broader query. Audius downloads still require an actual available download endpoint; login-gated or unavailable files cannot be retrieved by changing a license label.

**Provider failures:** A failed catalog does not discard another provider's match or block the rest of a playlist. If healthy catalogs find no match, discovery advances and saves named provider warnings with the checkpoint. The playlist and Downloads screens show **Search incomplete** and a retry action. If every catalog fails, the existing bounded retry policy applies, with named provider/HTTP details. This avoids repeating every lookup five times merely because one optional catalog is down.

**Automatic reliability ranking:** Verified imports increase a provider's priority, while terminal failures decrease it using the most recent 200 outcomes. Alternate sources are retained in the background ticket. Local storage failures do not start alternative network downloads.

## Automatic web fallback and song diagnostics

After catalog lookup, a song with no usable catalog file now enters automatic web search when a Brave API key is saved and **Automatically search when catalogs find no match** is enabled. Open the playlist's wider-web search screen, save the key once, return and use **Retry unmatched songs**. No individual result selection is required for files admitted by the automatic matcher. Without a key, catalog discovery still works and the song's diagnostic explains that web fallback was skipped.

Automatic fallback makes one Brave query per unmatched song and at most 20 per playlist discovery run. Reservations are persisted before the API request, so resuming the same job does not repeat a charged query. Completed web results, including empty results, survive a capacity pause or restart. A rejected key or rate/credit limit stops further automatic API calls for that run. A request interrupted before its result is saved is not repeated within that run; **Retry unmatched songs**, after that run finishes, starts a new bounded run. Manual web-search batches retain their separately displayed request budgets.

A direct result must independently identify both artist and song in its filename. Source pages may instead identify the recording through Schema.org MusicRecording/AudioObject metadata, including artist references and duration where provided. At most two relevant pages are read and six file responses probed per song. Only supported audio responses enter the existing background importer, which still checks embedded identity and decoded duration. Page reads are bounded to 1 MB, redirects are refused, and automatic search, page reads and file probes all inherit the playlist's Wi-Fi/cellular policy. There is no license-label requirement.

On a new search, stored failures for the same recording exclude previously failed source URLs before choosing catalog or web candidates. Local storage failures do not trigger another-source search. Thus **Retry unmatched songs** can seek a new web source instead of repeatedly queuing the same refused catalog URL. A source that fails after a transfer is queued remains visible in Downloads; retry initiates the next source search.

Each playlist song now has expandable **Source search details** and **Share search diagnostics**. The trace names provider outcomes, prior file refusals, missing-key/disabled/budget states and web page/file response checks. It contains no API key. These details persist with the discovery checkpoint.

A live public-source trace from the development host used **Jazz Backing Track — Stefan Kartenberg**: ccMixter RSS returned the matching metadata and direct MP3 URL (HTTP 200), while both HEAD and a bounded GET for that file returned HTTP 403. This demonstrates a source-access refusal rather than an absent license label. It is a representative probe, not a reproduction of an unspecified song from the user's playlist or an iPhone runtime test.

## When a playlist has missing songs

Spotify supplies the song list, artist, album and duration, not MP3 files. Removing the license-label requirement broadens eligible catalog matches; it does not create downloadable files for recordings absent from those catalogs.

1. Open **Playlists → your playlist → Song-by-song MP3 results**.
2. A no-match result means the catalogs that answered did not identify a matching file. **Search incomplete** names providers that could not answer. **Source lookup failed** means every provider failed after bounded retries.
3. Use **Retry unmatched songs** to search again. Keep the app open during source discovery. Transfers already queued appear in **Add Music → Your downloads**.
4. Use **Attach an audio-file link** to supply a direct HTTPS MP3 or another supported audio format. File decoding and duration checks run before attaching it to the song.
5. **Search the wider web for missing songs** opens broader manual discovery. In-app web search uses the optional Brave API key; browser search does not require that key. Search results are pages and possible links, and are not automatically treated as matching audio files.
6. Local files imported from **Add Music** also match playlists by title/artist metadata.

## Automatic Wi-Fi playlist downloads

Importing a Spotify playlist starts the existing persisted independent-audio
source discovery queue immediately, with no per-track approval. The app waits
for a **satisfied Wi-Fi network** before searching and starting downloads.
Its background URLSession tasks default to Wi-Fi-only using per-request
cellular restrictions, so outstanding Wi-Fi transfers wait if the phone moves
onto cellular. Downloaded, decodable matches enter the offline library
without additional taps. The app resumes unfinished discovery when reopened
or when a Wi-Fi path becomes available; iOS controls when suspended
background transfers actually execute.

On cellular, the playlist dashboard shows **Download this playlist using
cellular data**. Tapping it explicitly authorizes cellular discovery and
outstanding matching downloads *for this playlist only* in the current app
session. Previously queued Wi-Fi-only transfer tasks are replaced with
cellular-authorized tasks so they do not remain stuck waiting for Wi-Fi.
This option can use mobile data, and interrupted transfers might restart.
No blanket cellular permission is stored across relaunches. Album art,
streaming Spotify tracks and unverified web hits are not downloaded by
this automatic audio feature. Tracks with no matching independently
downloadable recording remain unavailable.

## Version-safe Spotify playlist matching and download queues

A Spotify playlist can contain a radio edit, preview and full-length recording
with identical song titles and artist credits. The offline library, playlist
reconciliation, song-by-song status labels and automatic background queue now
use version-safe matching: known durations must be within four seconds, and
unambiguous title/artist metadata is still required. File existence is checked
before declaring a recording already downloaded.

Background transfer deduplication also compares compatible durations rather
than collapsing different versions into the same pending ticket. When a
playlist wish has no duration information, it cannot cancel a known-duration
transfer based on its name alone; two identical unknown-duration CSV wishes
can still share a queue entry. A full-length recording can be selected even
when a distinct shorter version with the same title is already in the library,
while multiple equally matching files remain ambiguous.

## Updating the same Spotify playlist without re-downloading everything

Re-importing a previously linked Spotify playlist now synchronizes new,
removed and reordered songs into its **existing** library playlist rather
than returning the stale snapshot. The latest Spotify track metadata is
applied, but every unchanged occurrence retains its original `PlaylistWish`
UUID, including duplicates and reordered tracks. That preserves background
download IDs, checkpoints and per-song discovery results.

The automatic discovery queue appends **only newly added missing songs**,
without re-searching previously unavailable songs or resetting the cursor.
Old entries removed from Spotify are marked as removed when reached by the
discovery job, and any corresponding uncompleted transfer for that playlist
is cancelled. Previously imported audio stays in the owner's local music
library. Source-order tracks removed from Spotify no longer linger in the
playlist simply because reconciliation preserved manual additions; genuinely
manual additions remain.

Refreshing does not bypass a user-paused discovery job or turn cellular
downloading on. Spotify metadata refresh requires an explicit import action
and Spotify API access; this change does **not** claim iOS can silently poll
Spotify while the app is suspended.

## Avoiding duplicate playlist downloads and already-saved recordings

If two imported Spotify playlists refer to the same exact recording, both
may already have queued background transfers. When one finishes, MP3 Shelf
checks all other pending tickets against the authoritative offline library,
verifies artist/title and compatible duration, and marks satisfied tickets
as saved. Redundant iOS background tasks are cancelled, and no fallback
provider or transfer retry is launched for a song already on the phone.
The same reconciliation occurs when reattaching after app relaunch and
before processing staged downloads; cancelled tickets are not imported
from stale completion snapshots. Existing completed recordings are never
deleted.

Only a unique, genuinely present on-device file counts as reusable. A
short preview or an alternate version with a duration difference over
four seconds does **not** satisfy the full Spotify wish; ambiguous library
matches also remain unresolved. The individual playlist's original
source-order position is preserved by existing library reconciliation.
These checks prevent wasted bandwidth without making unverified music
matches or downloading anything from Spotify.

## Recovering orphaned background transfers after relaunch

MP3 Shelf's persisted download manifest can outlive its matching iOS
background URLSession task after an app crash or an OS task-discard. This
formerly left an old song permanently showing "Queued" even though no
transfer could complete. Foreground attachment now first recovers any
staged audio, then inspects iOS' background task inventory **twice**,
ten seconds apart. Only queued tickets at least 15 minutes old, with
no corresponding task in either inventory and no staged file or active
import, are recreated. Unidentifiable URLSession tasks block recovery
rather than risk a duplicate download.

The restored transfer preserves its verified source, alternative-source
fallbacks, playlist, attribution and retry budget. Tickets for already
imported songs can be finalized without downloading the bytes again.
The replacement URLRequest retains the Wi-Fi-only default and only uses
cellular if that playlist was explicitly approved in the *current*
session. No background timer, forced execution or additional user tap
is introduced; iOS still decides when background transfers run.

## Preverified backup download sources for locked-screen recovery

Every newly imported playlist song is looked up across all four supported
independent catalog APIs concurrently (Audius, Openverse, Wikimedia Commons,
Internet Archive). The first exact, permitted downloadable recording starts
as the primary background transfer; up to three other unique verified URLs,
along with each source's attribution and optional license, are saved in that ticket's
Codable manifest. Searching sources concurrently avoids having to wait for four
catalogs in serial, but does add catalog requests when the first one already
would have found the song.

If a file is missing, invalid, incorrectly tagged, has a mismatched duration
or exhausts its ordinary transient retry budget, the background downloader
automatically switches to the next queued, independently verified source.
Each new URL gets its own ticket and the same Wi-Fi-only request restriction
unless the user explicitly enabled cellular for this playlist. Alternative
source lists persist across ordinary app relaunches and can be consumed by
the iOS background URLSession daemon callback while the phone is locked.
The original Spotify playlist entry stays in the correct order and is never
silently substituted with an unverified live/remix recording. Once all verified
sources fail, the song stays marked failed with its final error for review.

This is a bounded provider failover, not a guarantee that every commercial
Spotify recording has an independently downloadable MP3. Spotify tracks and
DRM-protected media are not downloaded or converted.

## Request-level Wi-Fi-only source discovery

The automatic playlist queue was already gated by iOS Network framework
connection monitoring, but its four public catalog API calls previously used
URLSession's default per-request transport. Every Archive, Openverse,
Wikimedia Commons and Audius request now defaults to
`allowsCellularAccess=false`, `allowsExpensiveNetworkAccess=false`
and `allowsConstrainedNetworkAccess=false` **on the URLRequest itself**.
This also prevents an in-progress lookup from migrating onto cellular
after the Wi-Fi network changes, rather than relying only on a path check
performed before each song.

Choosing **Download this playlist using cellular data** explicitly enables
cellular, expensive and constrained network access for that playlist's
catalog requests and iOS background audio transfers. The setting for
future source discovery is session-only; a previously approved transfer
task may still finish on cellular across process relaunches because its
network permission is part of the background task created with that
explicit consent.

## Serialized background MP3 staging and iOS completion

Multiple background URLSession callbacks may arrive while the library is still
validating and importing an earlier MP3. Staged recovery now uses a main-actor
single-flight coordinator: overlapping callbacks await the current pass and
request one additional pass to import files staged during the first. The
app does **not** call iOS' `handleEventsForBackgroundURLSession` completion
handler until all requested staging passes finish. A cancelled or completed
ticket still cannot be re-imported. This prevents concurrent file mutations,
dropped staging callbacks and premature headless process suspension. Regression
coverage includes simultaneous import and completion calls; real device
background delivery remains a separate release gate.

A stored download manifest with repeated ticket IDs is now restored without an
app-launch crash. When repeated records have different start timestamps, the
most recent entry is retained; older legacy entries without timestamps are
handled deterministically. This is a corruption/upgrade safety measure, not
permission to silently repeat a queued audio transfer.

## Automatic background MP3 transfer recovery

An interrupted Wi-Fi connection no longer exhausts the three-attempt server
retry budget. When a transfer is cancelled by lost connectivity, no network
or an OS data-access restriction, its background URLSession ticket is
recreated with a persistent, gradually increasing reconnection delay of
1, 3, 10, 30 and then at most 60 minutes. Connection-loss retries continue
while the track remains queued; they do not change download sources merely
because Wi-Fi is temporarily unavailable. A new ticket preserves the
originally matched recording, playlist, attribution and verified alternates.
iOS controls actual transfer/relaunch timing, and the user can still cancel.

Server timeouts, HTTP 408/429 and common HTTP 5xx responses retain a
**separate three-attempt** retry budget, with delays of 45, 150 and
450 seconds. Bad sources, invalid media and permission failures continue to
use the terminal-failure/verified-alternate process.

Every default audio URLRequest now explicitly forbids cellular, expensive and
Low Data Mode networks; existing session-only, per-playlist cellular approval
permits those networks. The retry schedule never silently grants cellular
permission after Wi-Fi disappears.

New ticket identifiers isolate late callbacks from earlier attempts. Retry
state is optional in the persisted manifest for backward compatibility.
Server-side permissions and missing files (e.g. HTTP 403/404), invalid media,
wrong recording metadata or incompatible duration never trigger automatic
repeated downloads; those failures remain available in Download Manager
for manual inspection.

## Automatic catalog recovery and Audius response compatibility

Audius' JSON response may use `downloadable` or `is_downloadable`.
MP3 Shelf accepts either form only when the flag is true and other
ungated/exact-match checks succeed. Artist-enabled Audius downloads are
checked before more expensive archive metadata traversal, minimizing
unnecessary search requests for tracks found early.

Temporary source API failures no longer require tapping **Resume Search**.
The failed song stays at the persisted discovery cursor and receives at most
five automatic attempts, with retry delays of 15, 30, 60 and 120 seconds.
If the fifth lookup still fails, that song is marked **failed** (not
"unavailable") and the search continues automatically to the next song.
The user can rerun **Retry unmatched songs** later when the provider recovers.
This prevents one prolonged API outage from blocking the entire imported
playlist. Backoff checkpoints are persisted across relaunches, and a network
handoff or user pause does not consume an automatic attempt. In-app timers
cannot override iOS suspension, Wi-Fi-only transfers or cellular opt-in.

## Artist-enabled Audius downloads

The automatic Wi-Fi-first matching queue now also checks Audius, without an
extra API key. MP3 Shelf searches its official public track endpoint for
artist-enabled downloads, rejects stream-only, gated, unlisted and otherwise
restricted results, and requires exact artist/title metadata and compatible
recording duration. More than one eligible exact match is treated as
ambiguous, never chosen at random. Accepted tracks use the official Audius
**download** endpoint, not the streaming endpoint. Attribution links to the
publisher's original Audius page and its Open Music License; final downloaded
audio is decoded and duration-checked before adding it to the local playlist.
The Audius uploader and API indicate permissions; the application does not
independently verify the uploader's ownership. API access can be rate-limited.

Jamendo remains excluded because its API terms restrict offline music
caching applications. Search results, artist pages and streaming-only
recordings are never silently substituted for actual downloads.

## Broader web search for playlist downloads

Inside any Spotify-imported playlist with missing songs, tap **Search the wider web
for missing songs**. The **Web Download Search** sheet provides two complementary
paths:

1. **No API key required:** tap **10 search sites** beside a song to open a
   song-specific search on Brave, Google, Bing, DuckDuckGo, Bandcamp,
   SoundCloud, Internet Archive, Free Music Archive, ccMixter, or Audius.
   Search results are source/artist pages, not guaranteed download links.
2. **Optional in-app results:** add your personal
   [Brave Search API key](https://brave.com/search/api/). The key stays in the
   device Keychain, not Spotify or the repository. Choose the lookup depth:
   - **Quick**: one general download search per song.
   - **Thorough**: adds focused artist/store and direct-MP3-file queries.
   - **Extensive**: five separate queries per song, including official
     digital-download and independent archive/source-site searches.

If you enable **Inspect matching webpages during search**, the same explicit
batch search also examines up to **12 relevant publisher pages per batch**
(one per song) for direct audio candidates. This is an opt-in extra network
read, and each inspection checks at most two extensionless links with HTTP
HEAD. Page selection favors results referencing the requested artist and/or
title and skips unrelated pages and already-direct audio URLs. You can
still manually inspect the top five relevant pages for an individual song.
No web-search or page-inspection result triggers an audio download without
another explicit user action.

The screen deduplicates URL results and can show up to 75 links per song.
Each batch performs at most **100 provider API requests**, with **Next batch**
and **Previous** controls so a long playlist is not truncated. The screen
shows the current batch's maximum billable API requests before searching.
Each user's Brave API plan determines credits or charges, and a rate-limit
or rejected-key response stops the batch rather than generating more requests.

Search links let you inspect publishers and download terms. If a result
links directly to a supported audio file, **Check and save this audio file**
passes the URL to the existing user-confirmed downloader, which validates
HTTPS, audio decoding, file size, and expected track duration. An ordinary
web page is never silently treated as an MP3, and the app doesn't acquire
Spotify streams or bypass DRM. You can also use **Attach an audio-file link** or import audio through Files.

This expands finding links beyond the connected catalogs. A search result
alone does not establish that a link contains audio or matches the intended recording.

### Read a publisher page to locate direct audio files

Search results are now ranked using visible title and artist evidence. Direct
audio-file URLs rise to the top, but neither the ranking nor a matching title
guarantees the right recording or download rights. For a single song, tap
**Find audio files on top 5 pages** to inspect up to five search result
landing pages for advertised audio, with per-page progress and a review
button for each candidate. This batch inspection requires the user to
initiate it; results are never automatically downloaded.

The inspector gives precedence to links expressly marked as audio by the
publisher (Open Graph audio, HTML5 audio, Schema.org `AudioObject`, or a
download attribute) over arbitrary MP3 hyperlinks. Extensionless URLs
advertised by audio metadata are also eligible for a limited HTTP HEAD
content-type check. A matching URL or filename is not confirmation of the
recording's identity or its download permissions.

For an indexed webpage in **Web Download Search**, tap **Find audio files
linked on this page**. MP3 Shelf reads only bounded HTML, standard audio
tags, Open Graph audio metadata, direct file links and Schema.org
`AudioObject.contentUrl` metadata. Results are listed as **possible audio
files** for individual review; opening a page never starts a download.

Without a Brave API key, use **10 search sites** to find the publisher's
website, copy the public HTTPS page URL, and tap **Inspect a source page URL
for audio files** beside the corresponding song. The app reads the page and
shows direct MP3/M4A/AAC/WAV/AIFF file URLs, if advertised.

The inspector also recognizes download buttons such as
`/download?track=123` without a filename extension, but only when the page
explicitly marks the link as a download or audio resource. These links must
pass a separate HTTP HEAD check for supported audio MIME type, HTTP success,
and a maximum declared size of 100 MB before being shown. Sites that do
not support HEAD may require a normal browser visit instead.

For safety, the inspector streams no more than 1 MB of public HTTPS
HTML per page (even if the server ignores HTTP Range requests), does not
run JavaScript or inspect streaming manifests, follow redirects,
authenticate, bypass paywalls, or visit private IP addresses. A linked file still needs the existing explicit user action
and decoder/size/duration validation to enter the offline library. Most
streaming or commercial purchase pages will not expose a downloadable file.


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
icon inside a playlist, to view each catalog audio transfer:
queued/downloading, saved offline, failed and cancelled; byte progress where
available; source links and any supplied license links; individual Cancel and Retry; and
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
- `Services/AudioSourceFinder.swift`: public audio-catalog matching, provider diagnostics and direct-file lookup.
- `Services/LyricsParser.swift`: independent LRC / plain-text parsing.
- `Views/SpotifyViews.swift`, `Views/LyricsView.swift`: playlist importer and offline lyrics.
- `Views/`: SwiftUI library, playlists, full player, downloads, settings and Spotify playlist import.

No API secrets, ad SDKs, cloud services or external dependencies are bundled.

## Download and playback review branch

Use branch `fix/ios-download-finalization-and-conversion` (draft PR #28) for these changes. In Finder, double-click **Verify MP3 Shelf.command** inside `ios`. It runs nine Swift regression suites plus the C matching core, three unsigned native builds and the existing eight-screen Simulator smoke capture. It uses no GitHub Actions. macOS may require Open from the context menu for a downloaded script.

Reports and logs appear in `ios/build/local-release`. Missing Swift/Xcode now also creates a failed report. A successful Simulator launch still requires screenshot review and the physical iPhone scenarios in DEVICE_QA.md. The new interruption suite exercises resume intent; real calls, Siri and Bluetooth events require device testing.

For installation, double-click **Install on iPhone.command** inside `ios`. It lists devices and asks for your iPhone identifier and Apple Team ID, then invokes the existing signing/install helper. Xcode account sign-in, device trust and Developer Mode must already be configured. It does not bypass provisioning or perform device acceptance tests.

## Consolidated integration candidate

Branch `feat/ios-consolidated-candidate` combines the PR #28 download/conversion/playback work with PRs #24–#27 (shuffle history, queue editing, four-transfer backpressure and library indexes). Its Finder verification launcher includes nine Swift suites and the C matching core. Conflict resolution preserves scene-gated discovery and bounded background ownership alongside the capacity check. Native compilation and device QA remain required before release.

## Verification workflow follow-up

The latest report remains at `ios/build/local-release/QA_RECORD.md`; logs and Simulator screenshots now live in separate `runs/` folders identified by that report. This prevents stale output from an earlier invocation being mistaken for new evidence. Conflicting test-only/build-only flags are rejected, and failed compilation/build steps are named in the report. Extracted ZIPs use the commit recorded in `SOURCE.json`, labeled as archive metadata with unknown modification state; an unrelated parent Git checkout is never treated as the source repository.

`python3 ios/scripts/test-release-workflow.py` exercises the real runner with a fake toolchain in temporary directories. It verifies reporting/control flow only and does not compile Swift, build iOS, sign or install apps. The nine native Swift suites and actual Xcode/device gates remain separate.

Long-press a playlist and choose **Make local copy** to preserve its song order and missing entries as a separate local playlist. Audio files are shared. The copy has fresh playlist/wish IDs and does not inherit Spotify-refresh or portable-restore identity; it does not automatically begin downloads.

## Diagnosing a CodeSign failure

In the same project folder you opened in Xcode, double-click **ios/Diagnose Signing.command**. This builds/signs Debug for an iOS device using the Apple team and bundle identifier selected in that project; it never installs or launches the app. Xcode may perform its normal automatic provisioning. Select your own Team in Xcode first. The optional MP3SHELF_TEAM_ID environment override still works.

The diagnostic opens **ios/build/iphone-device/QA_RECORD.md**, which records the current step, result, exit code and relevant log context. Share the error section above the generic CodeSign summary. Each attempt preserves its own report and build/signature logs in **ios/build/iphone-device/runs/**. The install launcher also opens the report on failure. Failed builds/signature checks/installations/launches replace the latest report, so an older PASS cannot be mistaken for the new result.

The generic exit summary does not establish whether the cause is a development-team/profile mismatch, unavailable certificate/private key, keychain access or rejected Finder/resource-fork metadata. No signing credentials are exported or manually changed by these helpers. See the exact error in the report before choosing a repair. Apple documents the distinct cases in [signing errors](https://help.apple.com/xcode/mac/current/en.lproj/dev01865b392.html) and [resource-fork/Finder metadata rejection](https://developer.apple.com/library/archive/qa/qa1940/_index.html).
