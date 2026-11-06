# Download-path evidence — 2026-11-06

**Overall verdict: the full iPhone path is NOT PROVEN.** This executor is Linux,
with no Swift, Xcode, iPhone Simulator, or connected iPhone. No native PASS is
claimed from the host checks below.

## Live recording trace

Reference: Carefree — Kevin MacLeod, 206 seconds; YouTube ID sMcWOaJFuw0.

| Stage | Observed result |
| --- | --- |
| Search | HTTP 200, 20 recording renderers; matching official-artist results present. |
| Player metadata | Both 0.4.8 clients and 0.4.9 visionOS/web clients returned HTTP 200 / OK. The visionOS response contained two direct AAC formats. |
| Media transfer | The selected fresh signed AAC URL returned HTTP 200, text/html, 195 bytes: Site Unavailable. A matching user agent plus Range returned HTTP 206 with the same HTML. No audio was downloaded from that source. |
| New response gate | The exact production C gate rejects that captured HTML both as text/html and when mislabeled application/octet-stream. It accepts a real MP4 audio prefix. |
| Native queue/conversion/save/playback | NOT RUN here. Source transfer failed, and no Apple runtime exists in this executor. |

This trace establishes a media-response failure, not an absent license label.
It does not establish whether the response is produced by the destination or an
intermediate network service. The test did not bypass that unavailable destination.

## Independent real-file conversion check

Downloaded https://samples.ffmpeg.org/A-codecs/AAC/ct_faac-adts.aac: HTTP 200,
audio/aac, 299647 bytes. SHA-256:
052f9c7c5359d642fbba887d57fc72fe5745fc75b34cddc7a7adc0a912f9cf9c.

FFmpeg decoded it to 880640 stereo PCM frames at 44100 Hz (19.969161 seconds).
The exact bundled ShelfMP3Encoder adapter and LAME sources encoded those frames
into a 480861-byte MP3. ffprobe identified MP3/stereo/44100 Hz and 20.035875 seconds;
ffmpeg decoded the entire output without error. MP3 SHA-256:
b1c2feb9c4879578fa0af8499630cd5919d9855753fdd2d9adaf628db2cd7e12.

This verifies a real HTTPS download and the bundled C encoder, using FFmpeg as
the host decoder. It does **not** verify AVAudioFile, the app importer, background
URLSession, playlist integration, or iPhone playback.

## Corrections and native test

- Updated the vendored extractor from 0.4.8 to official 0.4.9, pinned to
  e5b7d0396ce12bf3444f0d209e8436c83373b7af. New clients and optional quality
  decoding are included. Both versions still encountered the HTML media response
  in this environment; the upgrade is not claimed to have repaired that response.
- A bounded AAC response probe now runs before enqueueing a resolved video source.
  HTTP success or a signed URL alone cannot mark a webpage as ready audio.
- Prove MP3 Downloads.command builds a fresh, isolated Debug Simulator app locally.
  The app uses production search/matching, queueRecording, background transfer,
  MP3 conversion, library import and local-file playback. It confirms the MP3
  codec, fully decodes the saved file, checks duration/non-silent PCM, and records
  the file checksum. Playback is muted for the test.
- Selection is recorded as automatic or reference-review. The latter exercises
  the explicit recording-review flow and does not prove automatic selection.
- The runner preserves per-run evidence, checks the saved file against its
  receipt, refuses paths outside the test container, and cannot reuse a stale PASS.
  It does not clear the normal app, sign an app, or use GitHub Actions.

On a Mac with Xcode and an iPhone Simulator runtime, double-click the launcher
inside ios. It opens ios/build/download-proof/QA_RECORD.md; the run directory
contains native-result.json and, on success, the actual MP3. Failures remain FAIL.
The native runner exited 2 here because macOS/Xcode is unavailable. The new native
code, Apple compilation and physical-iPhone/background behavior remain unverified.
