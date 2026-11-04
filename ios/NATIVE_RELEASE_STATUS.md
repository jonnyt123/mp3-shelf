# Native release status — draft PR #28

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
