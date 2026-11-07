#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ $# -gt 0 ]]; then
    OUT="$1"
else
    OUT="$(mktemp -d "${TMPDIR:-/tmp}/mp3shelf-matcher.XXXXXX")"
    trap 'rm -rf "$OUT"' EXIT
fi
mkdir -p "$OUT"
CORE="$ROOT/ios/Packages/ShelfMatching"
cc -std=c11 -Wall -Wextra -Werror -I "$CORE/Sources/ShelfMatching/include" \
    -c "$CORE/Sources/ShelfMatching/ShelfMatching.c" -o "$OUT/ShelfMatching.o"
cc -std=c11 -Wall -Wextra -Werror -I "$CORE/Sources/ShelfMatching/include" \
    "$CORE/Tests/matching_test.c" "$OUT/ShelfMatching.o" -o "$OUT/recording-core-test"
"$OUT/recording-core-test"
