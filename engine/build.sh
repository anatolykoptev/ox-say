#!/usr/bin/env bash
# Build the self-contained engines for Intel Macs (Metal on a discrete AMD GPU, CPU fallback):
#   tts-server  from the pinned qwentts.cpp            (text-to-speech)
#   ox-stt      from engine/stt on the pinned whisper.cpp (speech-to-text: Parakeet, Whisper)
#   ox-align    from engine/align on the pinned whisper.cpp (wav2vec2 CTC emissions)
# All carry engine/patches/ggml on their ggml tree.
#
# Usage: engine/build.sh [work-dir]      (default: build/engine)
# Output: <work-dir>/out/{tts-server,ox-stt,ox-align,licenses/}
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
# this build tree. Sets the array cmake_flags (an array, so paths with spaces stay one argument).
#
# OX_SAY_DIST=1 builds binaries to hand to other machines. The default, -march=native, targets this
# CPU; distribution builds use a fixed baseline instead. Every Intel Mac since 2013 (Haswell) has
# AVX2/FMA/F16C/BMI2. AVX-512 stays off because most Intel MacBooks have none. macOS 13 is the
# oldest target.
# A distribution build must run on every supported Mac, so it may not carry
# AVX-512. A native build (the default, from source) compiles for this CPU and
# rightly uses AVX-512 where the CPU has it.
check_dist() {
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        "$here/../scripts/check-no-avx512.sh" "$1"
    fi
}

set_cmake_flags() {
    local inc=$1 cpu
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        cpu=(-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
            -DGGML_BMI2=ON -DGGML_AVX512=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0)
    else
        cpu=(-DGGML_NATIVE=ON)
    fi
    cmake_flags=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "${cpu[@]}" -DGGML_METAL=ON
        -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple -DGGML_OPENMP=OFF
        "-DCMAKE_C_FLAGS=-I$inc" "-DCMAKE_CXX_FLAGS=-I$inc")
}

check_static() {
    local libs
    # Capture, then match: `otool | grep -q` under pipefail lets grep's early
    # exit SIGPIPE otool and turn a hit into a pass.
    libs=$(otool -L "$1")
    case $libs in
        *@rpath*)
            echo "$1 still links @rpath libraries:" >&2
            printf '%s\n' "$libs" >&2
            exit 1
            ;;
    esac
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
set_cmake_flags "$work/ggml-include-tts"
cmake -S "$tts" -B "$tts/build" "${cmake_flags[@]}" > "$work/tts-configure.log"
cmake --build "$tts/build" --target tts-server -j "$jobs" > "$work/tts-build.log"
cp "$tts/build/tts-server" "$out/tts-server"
strip -x "$out/tts-server"
check_static "$out/tts-server"
check_dist "$out/tts-server"
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
# ox-stt and ox-align -ng set GGML_METAL_DEVICES=0 so that ggml registers no
# Metal device (#37). It is a debug hook, not an API: a whisper.cpp bump that
# drops it would bring back the ~47 s Metal library compile on every CPU-only
# first run, silently. Fail the build instead.
grep -q 'getenv("GGML_METAL_DEVICES")' "$stt/ggml/src/ggml-metal/ggml-metal.cpp" || {
    echo "engine/build.sh: the pinned ggml no longer reads GGML_METAL_DEVICES; ox-stt/ox-align -ng would compile Metal again (#37)" >&2
    exit 1
}
include_copy "$stt/ggml" "$work/ggml-include-stt"
set_cmake_flags "$work/ggml-include-stt"
cmake -S "$here/stt" -B "$work/stt-build" -DWHISPER_SRC="$stt" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    "${cmake_flags[@]}" > "$work/stt-configure.log"
cmake --build "$work/stt-build" --target ox-stt -j "$jobs" > "$work/stt-build.log"
cp "$work/stt-build/ox-stt" "$out/ox-stt"
strip -x "$out/ox-stt"
check_static "$out/ox-stt"
check_dist "$out/ox-stt"
cp "$stt/LICENSE" "$out/licenses/whisper.cpp.LICENSE"
echo "built $out/ox-stt"

# --- ox-align (same whisper.cpp tree as ox-stt; only ggml is linked) ---
# Re-set the flags: this block must not depend on whatever the stt block left.
set_cmake_flags "$work/ggml-include-stt"
cmake -S "$here/align" -B "$work/align-build" -DWHISPER_SRC="$stt" \
    "${cmake_flags[@]}" > "$work/align-configure.log"
cmake --build "$work/align-build" --target ox-align -j "$jobs" > "$work/align-build.log"
cp "$work/align-build/ox-align" "$out/ox-align"
strip -x "$out/ox-align"
check_static "$out/ox-align"
check_dist "$out/ox-align"
echo "built $out/ox-align"
