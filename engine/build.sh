#!/usr/bin/env bash
# Build a self-contained tts-server for Intel Macs (Metal on a discrete AMD GPU,
# CPU fallback) from the pinned upstream qwentts.cpp plus engine/patches.
#
# Usage: engine/build.sh [work-dir]      (default: build/engine)
# Output: <work-dir>/out/tts-server
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pins.env
. "$here/pins.env"

work=${1:-"$here/../build/engine"}
mkdir -p "$work"
work=$(cd "$work" && pwd)
src="$work/qwentts"
out="$work/out"

# Rebuild the source tree whenever the pins or the patches change.
stamp=$( { cat "$here/pins.env"; find "$here/patches" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
if [ ! -f "$src/.ox-say-stamp" ] || [ "$(cat "$src/.ox-say-stamp")" != "$stamp" ]; then
    rm -rf "$src"
    git clone --quiet "$QWENTTS_REPO" "$src"
    git -C "$src" checkout --quiet "$QWENTTS_COMMIT"
    git -C "$src" submodule update --quiet --init --recursive
    actual=$(git -C "$src/ggml" rev-parse HEAD)
    if [ "$actual" != "$GGML_COMMIT" ]; then
        echo "ggml submodule is $actual, expected $GGML_COMMIT" >&2
        exit 1
    fi
    for p in "$here"/patches/ggml/*.patch; do
        git -C "$src/ggml" apply "$p"
    done
    for p in "$here"/patches/qwentts/*.patch; do
        git -C "$src" apply "$p"
    done
    echo "$stamp" > "$src/.ox-say-stamp"
fi

# A Homebrew ggml in /usr/local/include shadows the submodule headers: the
# qwen-core target passes ggml/include both as -I and -isystem, and clang then
# searches it after /usr/local/include. A copy under another path passed as a
# plain -I restores the right order.
inc="$work/ggml-include"
rm -rf "$inc"
cp -R "$src/ggml/include" "$inc"

# Static libraries: the installed binary must not depend on this build tree.
# The Metal shader library is embedded for the same reason.
cmake -S "$src" -B "$src/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BLAS=ON \
    -DGGML_BLAS_VENDOR=Apple \
    -DGGML_OPENMP=OFF \
    "-DCMAKE_C_FLAGS=-I$inc" \
    "-DCMAKE_CXX_FLAGS=-I$inc" \
    > "$work/cmake-configure.log"
cmake --build "$src/build" --target tts-server -j "$(sysctl -n hw.physicalcpu)" > "$work/cmake-build.log"

mkdir -p "$out"
cp "$src/build/tts-server" "$out/tts-server"
strip -x "$out/tts-server"
mkdir -p "$out/licenses"
cp "$src/LICENSE" "$out/licenses/qwentts.cpp.LICENSE"
cp "$src/ggml/LICENSE" "$out/licenses/ggml.LICENSE"
cp "$src/vendor/cpp-httplib/LICENSE" "$out/licenses/cpp-httplib.LICENSE"
sed -n '1,\|\*/|p' "$src/vendor/yyjson/yyjson.h" > "$out/licenses/yyjson.LICENSE"

if otool -L "$out/tts-server" | grep -q '@rpath'; then
    echo "tts-server still links @rpath libraries:" >&2
    otool -L "$out/tts-server" >&2
    exit 1
fi
echo "built $out/tts-server"
