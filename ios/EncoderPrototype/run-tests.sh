#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cc -std=c11 -Wall -Wextra -Werror "$ROOT/ShelfEncoder.c" "$ROOT/test_encoder.c" \
  -l:libmp3lame.so.0 -lm -o "$OUT/test"
cd "$OUT"
./test
ffprobe -v error -show_entries stream=codec_name,channels -show_entries format=duration -of json valid.mp3
ffmpeg -v error -i valid.mp3 -f null -
