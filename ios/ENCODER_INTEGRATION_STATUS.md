# Pending native conversion integration

The app now references the bundled local ShelfMP3Encoder package. LAME C sources are pinned to SwiftLAME 0.1.0 commit 45d1b021c2bd2bbd38b9669934c0584cda0d1b6b; provenance and license are included. The unsafe upstream Swift wrapper is not used.

AVAudioFile decodes interleaved Int16 PCM in bounded chunks. The checked C adapter encodes mono/stereo at 32, 44.1 or 48 kHz, with a one-hour limit and a reusable PCM buffer. Wrong-duration, empty and overlong inputs are rejected before encoding. Source identity is checked before encoding; MP3 codec and requested duration are checked before import. Unique temporary files are removed on return/error. Transfer cancellation and already-stored reconciliation signal conversion cancellation.

Passed here: the exact bundled LAME sources and package adapter compiled on Linux; the existing encoder regression harness passed and the resulting stereo MP3 fully decoded with ffmpeg. Shell syntax and first-party source whitespace checks passed. The full baseline diff reports retained whitespace in vendored LAME source, license and header files; those upstream files were not reformatted. The strict warnings-as-errors experiment failed on upstream LAME warnings; normal compilation passed with upstream deprecation and VBR array-size warnings. These warnings and Apple platform builds remain review items.

Downloads display a transient Finalizing state during validation/conversion/import; cancellation still signals the conversion worker. This state is reconstructed from staged-file recovery after relaunch rather than persisted as a separate ticket status.

NOT RUN: Swift compilation, local package resolution, iOS simulator/device build, FLAC decode through AVAudioFile, UI cancellation, background execution, or complete playlist download. This branch is an integration candidate, not a verified release.
