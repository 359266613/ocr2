#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t AxsScreenOcrVisionTests)"
trap 'rm -f "$test_binary"' EXIT
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra \
    -mmacosx-version-min=13.0 -IShared \
    Shared/AxsScreenOcrVision.m Tests/AxsScreenOcrVisionTests.m \
    -framework Foundation -framework Vision -framework CoreGraphics \
    -framework CoreImage -framework CoreText -framework ImageIO \
    -o "$test_binary"
"$test_binary" "$@"
