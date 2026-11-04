# Native release status — consolidated draft PR #29

The candidate now handles audio interruptions and route loss, and includes a double-click Mac verification launcher. The branch is `fix/ios-download-finalization-and-conversion`. The consolidated candidate branch `feat/ios-consolidated-candidate` now incorporates PRs #24–#27, with conflicts resolved in playback order, scene-gated discovery and regression tests.

| Gate | Evidence / remaining work |
| --- | --- |
| Playback recovery | Resume-intent regression suite added and wired into local runner; Swift execution and real notification behavior NOT VERIFIED. |
| Converter | Exact bundled C encoder harness and full MP3 decode passed on Linux in the prior development step. Swift bridge, codec support and native package linking NOT VERIFIED. |
| Upstream source | The deprecated include and VBR helper array-bound declarations are corrected with provenance notes. Bundled compilation passed with these diagnostic categories treated as errors, then encoder assertions and full MP3 decode passed. This is not a pass under all -Wall/-Wextra warnings or an Apple compiler build. Vendored whitespace is retained. |
| Local verification | Bash syntax and missing-Swift failure-report path checked here. Eight Swift suites, three native builds and eight Simulator captures require a Mac. |
| iPhone | Calls/Siri, wired and Bluetooth route loss, crossfade interruption, background conversion/cancellation, locked playback and Wi-Fi/cellular acceptance remain required in DEVICE_QA.md. |
| Release | Draft only; no signing, merge, deployment or device acceptance demonstrated. |

On the Mac, double-click `Verify MP3 Shelf.command` inside `ios`. It writes `ios/build/local-release/QA_RECORD.md` even if required tools are missing. Review actual step logs and screenshots; successful Simulator execution does not satisfy the physical iPhone gate. No GitHub Actions are invoked.

New recovery checks: seeking during crossfade stops the outgoing deck; failed completion does not advance silently. Cancellation of a still-queued staged import retains the file for subsequent recovery rather than triggering a fresh transfer. User-cancelled/satisfied ticket staging is removed. These Swift paths are source-reviewed, NOT runtime verified here.

Latest review: playlist deletion now cancels its queued transfers before removing its discovery checkpoint. Supported non-MP3 response MIME types can reach the existing checked converter; unsupported types still fail admission. Regression assertions cover MIME normalization and rejection, but are NOT RUN here. Playlist search, alphabetical sorting and rename are implemented without changing playlist IDs.

Fresh local attempt: `bash ios/scripts/verify-local-release.sh --tests-only` exited 2 (Swift compiler missing), writing a FAIL report with no completed native checks. Shell syntax and first-party whitespace checks passed. Remaining release blockers are the eight native suites, Apple platform package compilation/linking, Simulator/device builds and screenshots, and the signed physical-iPhone scenarios. The earlier ZIP remains at its recorded source revision and does not include this follow-up.
