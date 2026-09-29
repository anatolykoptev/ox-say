#!/usr/bin/env bash
# Build the self-contained engines for Intel Macs (Metal on a discrete AMD GPU, CPU fallback):
#   tts-server  from the pinned qwentts.cpp            (text-to-speech)
#   ox-stt      from engine/stt on the pinned whisper.cpp (speech-to-text: Parakeet, Whisper)
# Both carry engine/patches/ggml on their ggml tree.
#
# Usage: engine/build.sh [work-dir]      (default: build/engine)
# Output: <work-dir>/out/{tts-server,ox-stt,licenses/}
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pins.env
. "$here/pins.env"

work=${1:-"$here/../build/engine"}
mkdir -p "$work"
work=$(cd "$work" && pwd)
out="$work/out"
jobs=$(sysctl -n hw.physicalcpu)

ggml_patches() {
    find "$here/patches/ggml" -name '*.patch' -type f | LC_ALL=C sort
}

# Rebuild a source tree whenever its pins or the patches it takes change.
fresh() {
    local dir=$1 stamp=$2
    [ -f "$dir/.ox-say-stamp" ] && [ "$(cat "$dir/.ox-say-stamp")" = "$stamp" ]
}

# A Homebrew ggml in /usr/local/include shadows the tree's own ggml headers: targets that pass
# ggml/include both as -I and -isystem get it searched after /usr/local/include. A copy under
# another path passed as a plain -I restores the right order.
include_copy() {
    local ggml=$1 dst=$2
    rm -rf "$dst"
    cp -R "$ggml/include" "$dst"
}

# Static libraries and an embedded Metal library: the installed binaries must not depend on
# this build tree.
cmake_flags() {
    local inc=$1
    echo -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=ON -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_OPENMP=OFF \
        "-DCMAKE_C_FLAGS=-I$inc" "-DCMAKE_CXX_FLAGS=-I$inc"
}

check_static() {
    if otool -L "$1" | grep -q '@rpath'; then
        echo "$1 still links @rpath libraries:" >&2
        otool -L "$1" >&2
        exit 1
    fi
}

mkdir -p "$out/licenses"

# --- tts-server (qwentts.cpp) ---
tts="$work/qwentts"
stamp=$( { echo "$QWENTTS_REPO $QWENTTS_COMMIT $GGML_COMMIT"; ggml_patches | xargs cat; find "$here/patches/qwentts" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
if ! fresh "$tts" "$stamp"; then
    rm -rf "$tts"
    git clone --quiet "$QWENTTS_REPO" "$tts"
    git -C "$tts" checkout --quiet "$QWENTTS_COMMIT"
    git -C "$tts" submodule update --quiet --init --recursive
    actual=$(git -C "$tts/ggml" rev-parse HEAD)
    if [ "$actual" != "$GGML_COMMIT" ]; then
        echo "ggml submodule is $actual, expected $GGML_COMMIT" >&2
        exit 1
    fi
    ggml_patches | while read -r p; do git -C "$tts/ggml" apply "$p"; done
    for p in "$here"/patches/qwentts/*.patch; do
        git -C "$tts" apply "$p"
    done
    echo "$stamp" > "$tts/.ox-say-stamp"
fi
include_copy "$tts/ggml" "$work/ggml-include-tts"
# shellcheck disable=SC2046
cmake -S "$tts" -B "$tts/build" $(cmake_flags "$work/ggml-include-tts") > "$work/tts-configure.log"
cmake --build "$tts/build" --target tts-server -j "$jobs" > "$work/tts-build.log"
cp "$tts/build/tts-server" "$out/tts-server"
strip -x "$out/tts-server"
check_static "$out/tts-server"
cp "$tts/LICENSE" "$out/licenses/qwentts.cpp.LICENSE"
cp "$tts/ggml/LICENSE" "$out/licenses/ggml.LICENSE"
cp "$tts/vendor/cpp-httplib/LICENSE" "$out/licenses/cpp-httplib.LICENSE"
sed -n '1,\|\*/|p' "$tts/vendor/yyjson/yyjson.h" > "$out/licenses/yyjson.LICENSE"
echo "built $out/tts-server"

# --- ox-stt (whisper.cpp, vendored ggml) ---
stt="$work/whisper.cpp"
stamp=$( { echo "$WHISPER_REPO $WHISPER_COMMIT"; ggml_patches | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
if ! fresh "$stt" "$stamp"; then
    rm -rf "$stt"
    git clone --quiet "$WHISPER_REPO" "$stt"
    git -C "$stt" checkout --quiet "$WHISPER_COMMIT"
    ggml_patches | while read -r p; do git -C "$stt" apply --directory=ggml "$p"; done
    echo "$stamp" > "$stt/.ox-say-stamp"
fi
include_copy "$stt/ggml" "$work/ggml-include-stt"
# shellcheck disable=SC2046
cmake -S "$here/stt" -B "$work/stt-build" -DWHISPER_SRC="$stt" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    $(cmake_flags "$work/ggml-include-stt") > "$work/stt-configure.log"
cmake --build "$work/stt-build" --target ox-stt -j "$jobs" > "$work/stt-build.log"
cp "$work/stt-build/ox-stt" "$out/ox-stt"
strip -x "$out/ox-stt"
check_static "$out/ox-stt"
cp "$stt/LICENSE" "$out/licenses/whisper.cpp.LICENSE"
echo "built $out/ox-stt"
