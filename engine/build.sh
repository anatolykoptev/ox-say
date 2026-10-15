#!/usr/bin/env bash
# Build the self-contained engines for this Mac's architecture — arm64 (Apple
# Silicon, Metal on unified memory) or x86_64 (Intel, Metal on a discrete AMD
# GPU, CPU fallback):
#   tts-server  from the pinned qwentts.cpp            (text-to-speech)
#   ox-stt      from engine/stt on the pinned whisper.cpp (speech-to-text: Parakeet, Whisper)
#   ox-align    from engine/align on the pinned whisper.cpp (wav2vec2 CTC emissions)
#   audiocpp_server from the pinned audio.cpp, arm64 only (VoxCPM2 quality text-to-speech)
# The first three carry engine/patches/ggml on their ggml tree, on both architectures: on
# unified memory the patches are inert or bug fixes (engine/README.md).
#
# Usage: engine/build.sh [work-dir]      (default: build/engine)
# Output: <work-dir>/out/{tts-server,ox-stt,ox-align,audiocpp_server (arm64),licenses/}
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pins.env
. "$here/pins.env"

work=${1:-"$here/../build/engine"}
mkdir -p "$work"
work=$(cd "$work" && pwd)
out="$work/out"
jobs=$(sysctl -n hw.physicalcpu)

# The target is the shell's architecture. CMake build dirs are named after it:
# a dir configured on another architecture keeps that CMAKE_SYSTEM_PROCESSOR
# and would build the wrong one.
arch=$(uname -m)
case $arch in
    x86_64 | arm64) ;;
    *) echo "engine/build.sh: unsupported architecture $arch" >&2; exit 1 ;;
esac

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
# OX_SAY_DIST=1 builds binaries to hand to other machines. The default, -march/-mcpu=native,
# targets this CPU; distribution builds use a fixed baseline instead, and macOS 13.3 is the
# oldest target: ggml-blas calls Accelerate's new-LAPACK cblas, which exists only since 13.3.
#   x86_64: every Intel Mac since 2013 (Haswell) has AVX2/FMA/F16C/BMI2. AVX-512 stays off because
#           most Intel MacBooks have none.
#   arm64:  the Apple M1 (dotprod, fp16; no i8mm, BF16 or SME), pinned with -mcpu=apple-m1 on the
#           C and C++ flags. GGML_NATIVE=OFF keeps ggml from adding its own -mcpu/-march. A native
#           build on a newer chip uses those extensions and is a SIGILL on an M1.
# check_dist verifies the baseline on the output, per architecture.
check_dist() {
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        case $arch in
            x86_64) "$here/../scripts/check-no-avx512.sh" "$1" ;;
            arm64) "$here/../scripts/check-arm64-baseline.sh" "$1" ;;
        esac
    fi
}

set_cmake_flags() {
    local inc=$1 cpu opt=""
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        case $arch in
            x86_64) cpu=(-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
                -DGGML_BMI2=ON -DGGML_AVX512=OFF) ;;
            arm64) cpu=(-DGGML_NATIVE=OFF); opt=" -mcpu=apple-m1" ;;
        esac
        cpu+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3)
    else
        cpu=(-DGGML_NATIVE=ON)
    fi
    cmake_flags=(-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF "-DCMAKE_OSX_ARCHITECTURES=$arch"
        "${cpu[@]}" -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple
        -DGGML_OPENMP=OFF "-DCMAKE_C_FLAGS=-I$inc$opt" "-DCMAKE_CXX_FLAGS=-I$inc$opt")
}

# The output must be a thin binary of the target architecture with no @rpath
# dependency.
check_static() {
    local libs archs
    archs=$(lipo -archs "$1")
    if [ "$archs" != "$arch" ]; then
        echo "$1 is built for $archs, expected $arch" >&2
        exit 1
    fi
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
cmake -S "$tts" -B "$tts/build-$arch" "${cmake_flags[@]}" > "$work/tts-configure.log"
cmake --build "$tts/build-$arch" --target tts-server -j "$jobs" > "$work/tts-build.log"
cp "$tts/build-$arch/tts-server" "$out/tts-server"
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
cmake -S "$here/stt" -B "$work/stt-build-$arch" -DWHISPER_SRC="$stt" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
    "${cmake_flags[@]}" > "$work/stt-configure.log"
cmake --build "$work/stt-build-$arch" --target ox-stt -j "$jobs" > "$work/stt-build.log"
cp "$work/stt-build-$arch/ox-stt" "$out/ox-stt"
strip -x "$out/ox-stt"
check_static "$out/ox-stt"
check_dist "$out/ox-stt"
cp "$stt/LICENSE" "$out/licenses/whisper.cpp.LICENSE"
echo "built $out/ox-stt"

# --- ox-align (same whisper.cpp tree as ox-stt; only ggml is linked) ---
# Re-set the flags: this block must not depend on whatever the stt block left.
set_cmake_flags "$work/ggml-include-stt"
cmake -S "$here/align" -B "$work/align-build-$arch" -DWHISPER_SRC="$stt" \
    "${cmake_flags[@]}" > "$work/align-configure.log"
cmake --build "$work/align-build-$arch" --target ox-align -j "$jobs" > "$work/align-build.log"
cp "$work/align-build-$arch/ox-align" "$out/ox-align"
strip -x "$out/ox-align"
check_static "$out/ox-align"
check_dist "$out/ox-align"
echo "built $out/ox-align"

# --- audiocpp_server (audio.cpp, VoxCPM2) — Apple Silicon only ---
# VoxCPM2 (2B) needs unified memory next to the speech engines; the Intel
# package carries no quality engine (README "VoxCPM2"). audio.cpp vendors its
# own ggml, so engine/patches/ggml (AMD discrete fixes) does not apply here.
if [ "$arch" = arm64 ]; then
    ac="$work/audio.cpp"
    stamp=$( { echo "$AUDIOCPP_REPO $AUDIOCPP_COMMIT"; find "$here/patches/audiocpp" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
    if ! fresh "$ac" "$stamp"; then
        rm -rf "$ac"
        git clone --quiet "$AUDIOCPP_REPO" "$ac"
        git -C "$ac" checkout --quiet "$AUDIOCPP_COMMIT"
        git -C "$ac" submodule update --quiet --init --recursive
        # A tag object or a short ref must not stand in for the pinned commit.
        actual=$(git -C "$ac" rev-parse HEAD)
        if [ "$actual" != "$AUDIOCPP_COMMIT" ]; then
            echo "audio.cpp is $actual, expected the commit $AUDIOCPP_COMMIT" >&2
            exit 1
        fi
        for p in "$here"/patches/audiocpp/*.patch; do
            git -C "$ac" apply "$p"
        done
        echo "$stamp" > "$ac/.ox-say-stamp"
    fi
    # Same baseline as set_cmake_flags: a distribution build pins the M1 and the
    # 13.3 deployment target; a local build targets this CPU.
    native=ON
    ac_dist=()
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        native=OFF
        ac_dist=(-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 "-DCMAKE_C_FLAGS=-mcpu=apple-m1" "-DCMAKE_CXX_FLAGS=-mcpu=apple-m1")
    fi
    cmake -S "$ac" -B "$ac/build-$arch" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DENGINE_ENABLE_CUDA=OFF -DENGINE_ENABLE_VULKAN=OFF \
        -DENGINE_ENABLE_METAL=ON -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF \
        "-DENGINE_ENABLE_NATIVE_CPU=$native" -DGGML_METAL_EMBED_LIBRARY=ON \
        -DENGINE_BUILD_TESTS=OFF -DENGINE_BUILD_EXAMPLES=OFF -DAUDIOCPP_DEPLOYMENT_BUILD=ON \
        -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=voxcpm2 -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        ${ac_dist[@]+"${ac_dist[@]}"} \
        > "$work/audiocpp-configure.log"
    cmake --build "$ac/build-$arch" --target audiocpp_server -j "$jobs" > "$work/audiocpp-build.log"
    cp "$ac/build-$arch/bin/audiocpp_server" "$out/audiocpp_server"
    strip -x "$out/audiocpp_server"
    check_static "$out/audiocpp_server"
    check_dist "$out/audiocpp_server"
    cp "$ac/LICENSE" "$out/licenses/audio.cpp.LICENSE"
    # Every vendored dependency, derived from the tree: a hand-written list
    # cannot notice one it lacks. One with no licence file fails the build.
    # find's output is captured whole: `find | head -1` under pipefail lets
    # head's early exit SIGPIPE find.
    for dep in "$ac"/external/*/; do
        name=$(basename "$dep")
        found=$(find "$dep" -maxdepth 1 \( -iname 'licen[sc]e*' -o -iname 'copying*' \))
        f=${found%%$'\n'*}
        # external/llama_tokenizer is llama.cpp's BPE and unicode code; upstream
        # ships no licence file next to it. llama.cpp and ggml are one project
        # under one MIT licence, so ggml's stands in. Any other dependency
        # without a licence file still fails the build.
        if [ -z "$f" ] && [ "$name" = llama_tokenizer ]; then
            f="$ac/external/ggml/LICENSE"
        fi
        if [ -z "$f" ]; then
            echo "engine/build.sh: audio.cpp external/$name has no licence file" >&2
            exit 1
        fi
        cp "$f" "$out/licenses/audiocpp-$name.LICENSE"
    done
    echo "built $out/audiocpp_server"
fi
