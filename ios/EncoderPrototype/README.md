# PCM-to-MP3 encoder prototype

The application now references the local package in `../Packages/ShelfMP3Encoder`. This directory retains the portable adapter regression harness and system-library comparison build. No iOS build or device test has run.

ShelfEncoder accepts bounded interleaved signed 16-bit PCM chunks and creates a fresh MP3 file using LAME. It checks initialization, configuration, encoding, flush and output-write errors; supports partial writes; checks cancellation around each read; and closes/removes failed output. Source decoding is deliberately the caller's responsibility. Output is limited to one hour and supported input is mono/stereo at 32/44.1/48 kHz. The caller owns thread-safe cancellation and must validate output before importing it.

Run on Linux with cc, system libmp3lame.so.0, ffprobe and ffmpeg:

```sh
bash ios/EncoderPrototype/run-tests.sh
```

Verified: actual stereo PCM encoding, MP3 identification and full decode; short/failed/zero writes; cancellation after reading starts; input-read failure cleanup; existing destination protection; invalid channel count.

The pending integration includes the Swift PCM bridge and cancellation wiring. Still required: Apple platform package compilation/linking, native regression suites, release builds and device background-execution tests. The failure-injection writer tests exercise the write helper; they do not simulate a full disk during actual file encoding.

The public LAME header was copied from SwiftLAME 0.1.0 commit 45d1b021c2bd2bbd38b9669934c0584cda0d1b6b. Its private config.h include was removed for standalone public API compilation. Header copyright notices and LAME-COPYING are preserved. This prototype links the host's installed LAME; no library binary is bundled.
