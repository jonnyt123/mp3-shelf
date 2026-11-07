# Native release status — consolidated draft PR #29

## Ready songs during link recovery

The discovery queue can process ready songs while another song waits for its
replacement link. It saves the new cursor before lookup and uses the earliest
eligible recovery time when all remaining songs are waiting. A provider retry
continues to wait on its current song.

Regression cases cover newly added songs, staggered recovery times, saved
results and provider backoff. Swift syntax checks passed for three files.
The regression runner requires a Swift compiler and stopped at preflight here.

## Signed link expiry during transfer recovery

Automatic retries, missing task recovery and cellular upgrades check whether
the link expires by the next scheduled start. A backup must be valid at that
start and inherits the scheduled delay. Eligible automatic searches save the
affected song's earliest lookup time and return it behind the pending songs.

Regression cases cover the expiry boundary, backup selection and saved lookup
timing after relaunch. C tests and syntax checks for seven Swift files passed.
The Swift regression runner stopped at the missing compiler check. Device
transfer recovery still requires Xcode verification.

## Backup AAC link during full transfer

Automatic matching, recording review and manual retry now save one verified
backup format with the transfer ticket when available. The queue can switch to
it after an eligible transfer failure and skips expired backup links. Backup
probes use a five-second request timeout within the existing three-format limit.
The C checks and syntax parsing of seven changed Swift files passed. Native
regressions and live transfer verification require Swift and Xcode.

## AAC format fallback and queue capacity — native execution pending

Recording resolution now tries at most three eligible signed AAC formats in
bitrate order instead of discarding the recording when the top format fails.
It filters invalid/stale/oversized links, stops on success/cancellation and keeps
temporary failures eligible for the existing bounded retry. The background queue
also rechecks its four-slot limit at MainActor insertion, closing the capacity
race across awaited recording resolution. Import/response validation is preserved.

The C matching/audio-admission suite and four changed-file Swift syntax checks
pass. New native discovery regressions and queue-race acceptance are NOT RUN;
the native verifier exits 2 without Swift. No new live-download success, Apple
compilation or iPhone runtime result is claimed. Keep the candidate draft.

## Q3 restart playback — native execution still pending

Import success now requires writing the full track metadata and matched playlist
links. Failed library writes preserve existing records, remove the new audio and
artwork, expose storage errors and cannot trigger alternate-source downloads.
The native proof now requires an app termination/relaunch, restored identity and
checksum, rejected save-failure injection and production local-file playback.
A separate Prove Offline Restart.command uses the small local MP3 fixture with
foreground HTTP refused and discovery/transfers disabled; a fixture PASS cannot
claim live download success. Physical-device Airplane Mode is a separate gate.

Twelve fake-toolchain/receipt workflow tests pass; the real fixture fully decodes
on the host. Eight changed Swift files pass syntax parsing. Native persistence
regressions, Apple compilation and restart playback remain NOT RUN here; the
native verifier and new launcher exit 2 without Swift/macOS/Xcode. Keep draft.

## Temporary lookup recovery — native regression execution pending

Automatic discovery no longer discards a temporary recording-search/resolution
failure when fallback catalogs return no matches. It retains the failure for the
existing persisted backoff and five-attempt limit, while a usable fallback can
still queue immediately. Permanent refusals/genuine misses remain terminal, and
the existing network policy, cancellation and web-search ledger are preserved.
The discovery suite includes recovery/exhaustion/restart cases. Changed-file
syntax and whitespace checks passed; the native test runner exited 2 because
Swift is absent. Native regression execution and the full download proof remain
unverified. The earlier live HTML response is not claimed to be fixed.

## Download proof follow-up — overall native verdict still unverified

A live Carefree/Kevin MacLeod trace resolved AAC URLs but received a 195-byte
HTTP-200 text/html Site Unavailable response; Range returned the same HTML.
No successful YouTube audio download is claimed. Updated the extractor to pinned
0.4.9 and added a real response-prefix/MIME probe before queueing, backed by the
portable production C admission gate. The captured HTML is rejected, including
when mislabeled as binary audio.

A separate real HTTPS AAC sample downloaded, decoded with FFmpeg and encoded by
the exact bundled adapter/LAME into a valid MP3, which fully decoded successfully.
This does not exercise native AVAudioFile or the iPhone importer. Details, hashes
and scope are in DOWNLOAD_PATH_EVIDENCE.md.

Added an isolated Debug Simulator proof through the real app's search, matching,
queue, transfer, conversion/import, full MP3 decode and local-file player. The
Finder launcher saves per-run results and the MP3; reference-review selection is
explicitly distinct from automatic selection. Six receipt/preflight regression
tests pass; these are not native download tests. The native runner exited 2 here
because macOS/Xcode is unavailable. Build and runtime acceptance remain open.

## Apple Music import candidate

Added an iPhone Music-library playlist picker using MediaPlayer, with explicit
library permission and the required Info.plist purpose string. Selected metadata
enters the existing recording-matching/download pipeline; no Music asset URL,
preview extraction, MusicKit token or signing entitlement was added. Source IDs
are installation-scoped, duplicate song occurrences retain independent wish IDs,
reimport updates the existing playlist, and native backups retain source metadata.

Fresh checks: all 33 first-party Swift files passed syntax parsing; static Xcode
wiring passed for 23 app files and the Music-library privacy purpose. All 13 shell
verifier workflow tests passed with fake Apple tools. New Apple Music metadata,
source identity, duplicate/refresh, copy and native-backup regression cases are
included in the existing native suites but **NOT RUN** here. The native verifier
exited 2 because Swift is unavailable. Apple SDK type checking, permission UI,
cloud-library visibility and real iPhone import/download remain **NOT VERIFIED**.

## Current custom-engine candidate

The app now owns search parsing, recording normalization/scoring, ambiguity
decisions, persisted candidate selection and bounded source recovery. Local-only
YouTubeKit extraction supplies AAC to the existing background downloader and
checked MP3 converter. The primary matcher needs no search key or running Mac.
Manual review, expired-link refresh, cancellation and playlist deletion are
wired through the existing scene/network/capacity policies.

Evidence: the actual C matching core passes executable identity, duration,
version, fuzzy-review and invalid-input checks. Thirteen verifier workflow tests
and eight installer workflow tests pass using fake Apple tools; these exercise
shell control flow, not Swift compilation or signing. A read-only YouTube search
returned HTTP 200 with 20 video renderers, artist badges and duration fields in
the expected shape. No audio was extracted in that probe.

Fresh source checks: all 31 first-party Swift files passed syntax parsing.
Static Xcode wiring checks passed for 21 app files, three local products and
three extractor JavaScript resources. The raw parser also rejects pristine
upstream YouTube.swift, so that file's parser result is inconclusive rather
than a compiler verdict. C tests also passed with AddressSanitizer and UBSan;
LeakSanitizer was disabled because of this host's execution restrictions.
The native verifier exited 2 with `Swift compiler not found`.

The Mac runner now has nine Swift suites plus the C matching-core check.
Swift type checking, package linking, Xcode builds, native extraction, real MP3
conversion through this new path and physical-iPhone acceptance are **NOT VERIFIED**.
The source remains a draft candidate; no release or signing fix is claimed.

## Earlier consolidated work and evidence

The candidate now handles audio interruptions and route loss, and includes a double-click Mac verification launcher. The branch is `fix/ios-download-finalization-and-conversion`. The consolidated candidate branch `feat/ios-consolidated-candidate` now incorporates PRs #24–#27, with conflicts resolved in playback order, scene-gated discovery and regression tests.

| Gate | Evidence / remaining work |
| --- | --- |
| Playback recovery | Resume-intent regression suite added and wired into local runner; Swift execution and real notification behavior NOT VERIFIED. |
| Converter | Exact bundled C encoder harness and full MP3 decode passed on Linux in the prior development step. Swift bridge, codec support and native package linking NOT VERIFIED. |
| Upstream source | The deprecated include and VBR helper array-bound declarations are corrected with provenance notes. Bundled compilation passed with these diagnostic categories treated as errors, then encoder assertions and full MP3 decode passed. This is not a pass under all -Wall/-Wextra warnings or an Apple compiler build. Vendored whitespace is retained. |
| Local verification | Nine Swift suites, three native builds and eight Simulator captures require a Mac. Portable C checks can run separately. |
| iPhone | Calls/Siri, wired and Bluetooth route loss, crossfade interruption, background conversion/cancellation, locked playback and Wi-Fi/cellular acceptance remain required in DEVICE_QA.md. |
| Release | Draft only; no signing, merge, deployment or device acceptance demonstrated. |

On the Mac, double-click `Verify MP3 Shelf.command` inside `ios`. It writes `ios/build/local-release/QA_RECORD.md` even if required tools are missing. Review actual step logs and screenshots; successful Simulator execution does not satisfy the physical iPhone gate. No GitHub Actions are invoked.

New recovery checks: seeking during crossfade stops the outgoing deck; failed completion does not advance silently. Cancellation of a still-queued staged import retains the file for subsequent recovery rather than triggering a fresh transfer. User-cancelled/satisfied ticket staging is removed. These Swift paths are source-reviewed, NOT runtime verified here.

Latest review: playlist deletion now cancels its queued transfers before removing its discovery checkpoint. Supported non-MP3 response MIME types can reach the existing checked converter; unsupported types still fail admission. Regression assertions cover MIME normalization and rejection, but are NOT RUN here. Playlist search, alphabetical sorting and rename are implemented without changing playlist IDs.

Fresh local attempt: `bash ios/scripts/verify-local-release.sh --tests-only` exited 2 (Swift compiler missing), writing a FAIL report with no completed native checks. Shell syntax and first-party whitespace checks passed. Remaining release blockers are the eight native suites, Apple platform package compilation/linking, Simulator/device builds and screenshots, and the signed physical-iPhone scenarios. The earlier ZIP remains at its recorded source revision and does not include this follow-up.

Latest workflow review: 12 Python regression tests passed against the real shell runner using fake Swift/Xcode tools in isolated temporary directories. The new failed-step, contradictory-mode and archive-provenance checks were demonstrated to fail against the preceding runner. This is workflow evidence only; no native suite, Xcode build or simulator pass is claimed. Individual run logs, explicit failure steps and archive source provenance are now reported. Cancellation source review added cleanup for late callbacks after history removal; playlist local-copy regressions were added to the native parser suite and remain unexecuted here.

Build-configuration audit: 19 app Swift files are present and have unique Sources membership. Static checks passed for target/scheme/Info.plist paths, iOS 17 declarations, local encoder product/framework wiring, background modes/task identifier, Spotify callback and asset references (including a 1024px PNG icon). No build-setting defect was established by these checks, so build settings were preserved. SwiftPM resolution, native compilation/linking, asset catalog compilation and signing remain unverified.

Recovery/diagnostic review: new playlist matching excludes files absent from disk; metadata-only pending-checkpoint refreshes are now persisted even with no appended song. Transfer errors explain source refusal/expiry, unsupported responses, connection/timeout/TLS and local storage failures. Disk-full/write-permission failures do not launch alternative-source downloads, since another transfer cannot fix local storage. Native diagnostic/checkpoint regression assertions were added but not executed in this environment.

## Public-file discovery correction (2026-11-05)

Missing Creative Commons labels no longer exclude exact public-file matches in Archive, Openverse, Commons or ccMixter. License links are optional in source candidates and persisted background tickets; missing license links are hidden in the UI, and source attribution survives native/browser backup round trips. Archive admission now reads file.size, not the decimal duration in file.length. A single provider outage no longer causes every playlist song to exhaust five retries: healthy results continue, named partial-search warnings persist, and total outages retain bounded retries with provider/HTTP details.

Fresh evidence: all 21 web tests and TypeScript checking passed. The new license-free backup test first failed against the old importer, then passed after the correction. Tree-sitter syntax parsing passed for all changed Swift files; this is not Swift type checking. Native verifier --tests-only exited 2 because Swift is missing; native regression suites, Apple compilation and on-device downloads remain NOT VERIFIED. Live read-only catalog probes from this host returned HTTP 200 for Audius, Commons and ccMixter; Openverse returned HTTP 403 with a Cloudflare challenge. A real Archive file listing confirmed size=8419768 and length=351.4, reproducing the prior integer-duration rejection. These service probes are not iPhone end-to-end evidence.

## Automatic web fallback candidate (2026-11-05)

Implemented per-song persisted diagnostics and bounded automatic Brave fallback after no usable catalog file is found. Saved API key required; toggle and standalone Save key control are available in the existing web search screen. Requests inherit playlist Wi-Fi/cellular settings. Credit reservations, successful/empty web results and stop reasons persist; 20 queries per playlist run, one per wish. Matching uses direct artist/title filenames or recording-level JSON-LD evidence, with bounded page reads and audio response probes before checked import. Repeated source refusals are omitted on a new search; local storage failures do not cause paid web fallback.

Representative public trace: Jazz Backing Track by Stefan Kartenberg, ccMixter RSS lookup HTTP 200, direct audio HEAD and bounded GET both HTTP 403 from this host. No specific failing playlist title/artist was supplied. A live Brave fallback and native/iPhone end-to-end run have NOT been demonstrated: no user search key or Apple toolchain is available here. Native verifier exited 2 for missing Swift. New matcher, network-policy, request-budget, source/storage classification and persistence regressions are added but NOT RUN natively. Tree-sitter syntax checks cover the changed Swift sources only. Web regression tests and TypeScript checking are separate checks and do not validate native fallback.

Fresh checks for this fallback change: `npm test` passed all 21 tests across six web suites; `npm run typecheck` exited 0. Whitespace checks passed. All eight changed Swift files parsed without syntax errors. Native regression execution, Swift type checking, Xcode builds and live Brave/iPhone behavior remain unverified.

## Signing diagnostic workflow correction

The generic CodeSign exit summary supplied by the user is insufficient to identify the device's actual signing cause. No signing certificate/profile repair is claimed. A confirmed installer reporting defect was corrected: failed commands previously exited before writing a new report, leaving an older PASS in place. The installer now records the failed stage and error context on exit, preserves per-run logs/DerivedData, and gates install/launch on successful build and signature verification. A double-click Diagnose Signing launcher performs build/signature checks without install or launch, using the project's selected team/bundle ID.

Eight fake-toolchain installer regression tests pass, covering stale PASS replacement (including invalid-team preflight), real signing-message capture, signature/install/launch failures, build-only behavior, configured-team use and per-run report retention. The original six cases failed against the preceding installer. All 12 existing verifier workflow tests also pass; Bash syntax and whitespace checks pass. These are shell workflow tests, not actual Apple signing or native app verification. Mac execution and the user's specific CodeSign root cause remain unverified until the new report is collected.
