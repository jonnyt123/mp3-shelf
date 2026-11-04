LAME sources from hidden-spectrum/SwiftLAME tag 0.1.0 commit 45d1b021c2bd2bbd38b9669934c0584cda0d1b6b. Original notices and LAME/COPYING retained. Adapter is MP3 Shelf code, mirrored from EncoderPrototype. Native package build not yet verified.

Local portability patches: quantize.c VBR helper parameter bounds now match the 15-element caller arrays and get_framebits; valid bitrate indices are 0–14. vector/lame_intrin.h uses standard C #include in place of deprecated #import. No encoder arithmetic changed.
