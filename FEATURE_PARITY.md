# MP3 Shelf — Cross-platform feature parity tracker

Repo: `jonnyt123/mp3-shelf`

The web PWA deploys from `main`, and the native SwiftUI app lives in stacked draft
iOS PRs #1–#4. All implementation statuses are branch-specific until merged.

| Capability | Native iPhone (draft PRs) | Browser PWA (`main` + draft PR #5) | Remaining release gate |
| --- | --- | --- | --- |
| Local audio import and offline playback | Implemented; Simulator tested | Live and implemented | Physical iPhone Safari + native testing |
| Playlists, search, shuffle, repeat, artwork, scrubbing | Implemented | Live and implemented | Cross-device navigation checks |
| Spotify metadata playlist import | PKCE/CSV importer implemented | PR #5 adds PKCE/CSV import; metadata-only | Configure Spotify client ID and allowed redirect; confirm account eligibility |
| Spotify owned/collaborative playlist access | Native integration in draft | PR #5 uses 2026 `/items` endpoint | Spotify permission/restriction live tests |
| Matching imported track lists against local recordings | Implemented conservatively | PR #5 adds conservative matching + missing-song list | Test real exported playlists and alternate recordings |
| Licensed MP3 discovery from independent catalogs | Implemented in native stacked drafts | **Not yet implemented on web** | Legal/source verification, API/CORS limits |
| Background/resumable downloads | Native URLSession background transfer implemented | **Web needs dedicated design**; service worker cannot emulate iOS URLSession guarantees | Browser/PWA capability tests; avoid promising equivalent background survival |
| Manual authorized HTTPS audio downloads | Implemented natively | **Not yet on web** | Validate response MIME, file limits, redirects, CORS |
| Lyrics and timed lyric parsing | Native view and parser | **Not yet on web** | UI and lyrics import/display implementation |
| Crossfade | Native player supports crossfade | **Not yet on web** | Test Web Audio routing, iOS Safari restrictions |
| AirPlay | iOS audio routing | Safari AirPlay picker where available | Hardware device validation |
| Backups/export/restore | **Not yet native** (separate format/migration required) | Web PWA backup/restore implemented, PR #5 adds playlist metadata | Cross-platform lossless backup format and migration |
| Premium lavender/mint/coral design | Draft PR #4 | PR #5 adds corresponding Spotify screens, rest of web retains earlier design | Complete shared design tokens and accessible screens |
| Install to home screen | Native iPhone app (not in TestFlight yet) | Live PWA with home screen | App Store/TestFlight submission, final native QA |
| Automated CI | Native Xcode Simulator runs in stacked PRs | PR #5 adds web tests, typecheck and build | Run latest commits and check result |

## Safety and product constraints

- A Spotify playlist contains **metadata and links**, not downloadable Spotify audio.
  Never attempt stream ripping, DRM bypass, or silently substitute unauthorized recordings.
- As of 2026, Spotify Development Mode has additional account and app limits, and
  playlist item APIs are restricted to the authenticated user's own/collaborative
  playlists. CSV/TSV import remains available when API access is not permitted.
- The browser must not pretend to have iOS-native OS-level background transfer
  resilience. Be honest about suspension and CORS limitations.
- Both versions must preserve local media, playlist assignments, privacy, and
  offline playback during future migrations. Existing backups must remain readable.
- **No merges or production deployments** without an explicit release decision.

## Next development order

1. Ship and verify web playlist metadata import through CI and iPhone Safari.
2. Implement browser legal-source discovery and manual downloads, with explicit permissions.
3. Add timed lyrics and native/PWA backup interoperability.
4. Implement crossfade as supported by the browser without breaking existing audio.
5. Close visual parity and run physical-device QA for both apps.
