#!/usr/bin/env bash
# Build the self-contained engines for this Mac's architecture — arm64 (Apple
# Silicon, Metal on unified memory) or x86_64 (Intel, Metal on a discrete AMD
# GPU, CPU fallback):
#   tts-server  from the pinned qwentts.cpp            (text-to-speech)
#   ox-stt      from engine/stt on the pinned whisper.cpp (speech-to-text: Parakeet, Whisper)
#   ox-align    from engine/align on the pinned whisper.cpp (wav2vec2 CTC emissions)
#   audiocpp_server from the pinned audio.cpp, arm64, dist build or OX_SAY_WITH_VOXCPM2=1 (VoxCPM2 quality text-to-speech)
#   ox-llm      from the pinned llama.cpp's llama-server, own ggml (meeting notes: Qwen3.5 GGUF)
#   ox-diar     from engine/diar, a Swift package on FluidAudio's Core ML models (speaker diarization)
# The first three carry engine/patches/ggml on their ggml tree, on both architectures: on
# unified memory the patches are inert or bug fixes (engine/README.md).
#
# Usage: engine/build.sh [work-dir]      (default: build/engine)
# Output: <work-dir>/out/{tts-server,ox-stt,ox-align,ox-llm,ox-diar,audiocpp_server (arm64),
#                        each <bin>.metallib (+<bin>-tensor.metallib on a
#                        macOS 26 SDK) when the Metal toolchain is present,
#                        licenses/, pins.env (the repo and commit pins this build used)}
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=pins.env
. "$here/pins.env"
# shellcheck source=want-audiocpp.sh
. "$here/want-audiocpp.sh"
# shellcheck source=want-diar.sh
. "$here/want-diar.sh"
# shellcheck source=lib-check.sh
. "$here/lib-check.sh"

work=${1:-"$here/../build/engine"}
mkdir -p "$work"
work=$(cd "$work" && pwd)
out="$work/out"
jobs=${OX_SAY_JOBS:-$(sysctl -n hw.physicalcpu)}

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

# Engine binaries always embed the Metal sources (GGML_METAL_EMBED_LIBRARY=ON):
# a missing, stale or corrupt metallib can then never stop an engine — the
# patched ggml falls back to the embedded compile (patches/ggml/0003,
# patches/audiocpp/0003, patches/llamacpp/0001). A working Metal toolchain additionally builds each
# engine a precompiled <bin>.metallib — the same kernels from the same patched
# tree, with no first-run compile (plans/ox-say/2026-10-22-precompiled-metal-shaders.md).
# `xcrun -f metal` finds a stub even when Xcode 26's MetalToolchain component
# is missing, so the probe compiles AND links a trivial kernel the same way
# the metallib build does. OX_SAY_METAL_EMBED=1 skips the metallib build
# (A/B tests).
probe_metal() {
    local d=$1
    printf 'kernel void ox_say_metal_probe() {}\n' > "$d/probe.metal"
    xcrun -sdk macosx metal -c "$d/probe.metal" -o "$d/probe.air" > "$d/metal.log" 2>&1 &&
        xcrun -sdk macosx metallib "$d/probe.air" -o "$d/probe.metallib" >> "$d/metal.log" 2>&1
}

# copy_metal_libs <metallib-build-bin-dir> <engine>: ship the compiled library
# under the engine's own name. Engines in out/ come from different ggml trees,
# whose kernel sources differ, so one default.metallib cannot serve them all; a
# patched ggml (patches/ggml/0003, patches/audiocpp/0003, patches/llamacpp/0001)
# probes <argv0>.metallib next to the binary and falls back to the embedded
# source when it is missing or does not load.
copy_metal_libs() {
    local dir=$1 name=$2
    cp "$dir/default.metallib" "$out/$name.metallib"
    if [ -f "$dir/ggml-tensor.metallib" ]; then
        cp "$dir/ggml-tensor.metallib" "$out/$name-tensor.metallib"
    fi
}

probe_dir="$work/.metal-probe"
mkdir -p "$probe_dir"
metal_lib=
if [ "${OX_SAY_METAL_EMBED:-0}" = 1 ]; then
    echo "engine/build.sh: OX_SAY_METAL_EMBED=1 — no metallib build; binaries embed Metal source and compile shaders at first run"
elif probe_metal "$probe_dir"; then
    metal_lib=1
    echo "Metal toolchain found: per-engine precompiled metallibs alongside the embedded-source binaries"
else
    echo "engine/build.sh: no Metal toolchain (see $probe_dir/metal.log) — binaries embed Metal source and compile shaders at first run; install it with 'xcodebuild -downloadComponent MetalToolchain'"
fi
# Whatever is in out/ must be from this build: drop metallibs a toolchain
# build left behind so a library cannot pair a stale library with a new binary.
rm -f "$out"/*.metallib

# build_metal_lib <cmake-src> <build-dir> [extra -D args]: a second, cheap
# configure with EMBED_LIBRARY=OFF, building only the ggml-metal-lib target —
# the same kernel sources the binaries embed, so the shipped library cannot
# drift from them. qwentts's ggml submodule and audio.cpp's vendored ggml are
# complete trees configured directly; whisper.cpp's and llama.cpp's vendored
# ggml trees are partial (no tests/examples/ggml.pc.in — they cannot be a -S
# root), so they are reached through a parent CMakeLists that
# add_subdirectory()s them: engine/align's and llama.cpp's own root.
# GGML_METAL_MACOSX_VERSION_MIN pins the AIR target at macOS 14.0: the library
# carries the bf16 kernels (patches/ggml/0005, patches/audiocpp/0004,
# patches/llamacpp/0001), which need Metal language 3.1 — a lower target
# compiles them out and a missing kernel is a crash, not a slower fallback.
# macOS 13.3 remains the app's floor: on 13.x the patched ggml skips the
# library and uses the embedded sources (patches/ggml/0003,
# patches/audiocpp/0003, patches/llamacpp/0001). The tensor library keeps its
# intentional macOS 26 target (patches/ggml/0004, patches/llamacpp/0001).
# The build dir is rebuilt from scratch every time: the metallib is a
# custom_command whose DEPENDS does not include the compile flags, so a cached
# dir keeps its stale .air files after GGML_METAL_MACOSX_VERSION_MIN or
# XC_FLAGS change and relinks them into the next library.
build_metal_lib() {
    local src=$1 dir=$2
    shift 2
    rm -rf "$dir"
    cmake -S "$src" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        "-DCMAKE_OSX_ARCHITECTURES=$arch" -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=OFF \
        -DGGML_METAL_MACOSX_VERSION_MIN=14.0 "$@" > "$dir-configure.log"
    cmake --build "$dir" --target ggml-metal-lib -j "$jobs" > "$dir-build.log"
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

mkdir -p "$out/licenses"
# An interrupted build must not leave the previous build's pins next to new binaries; the stamp is written last.
rm -f "$out/pins.env"

# --- tts-server (qwentts.cpp) ---
tts="$work/qwentts"
stamp=$( { echo "$QWENTTS_REPO $QWENTTS_COMMIT $GGML_REPO $GGML_COMMIT"; ggml_patches | xargs cat; find "$here/patches/qwentts" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
if ! fresh "$tts" "$stamp"; then
    rm -rf "$tts"
    git clone --quiet "$QWENTTS_REPO" "$tts"
    git -C "$tts" checkout --quiet "$QWENTTS_COMMIT"
    # Upstream ServeurpersoCom/ggml force-pushes master on every fork sync, so the pinned commit is
    # kept alive only by the ox-say-pin-<first 7 of GGML_COMMIT> tag of our fork. A missing or
    # misplaced tag fails the build here: the orphan SHA still fetches upstream today, so it would
    # pass everything and break at GitHub's next gc. For an annotated tag the peeled refs/tags/*^{}
    # line is what resolves to the commit.
    # An empty GGML_COMMIT (a corrupted pins.env) must fail here, not only in
    # the SHA assert after `submodule update`: the tag compare would pass on
    # two empty strings and report a missing tag with a misleading name.
    if [ -z "${GGML_COMMIT:-}" ]; then
        echo "engine/build.sh: GGML_COMMIT is empty — fix engine/pins.env" >&2
        exit 1
    fi
    ggml_tag="ox-say-pin-${GGML_COMMIT:0:7}"
    ggml_refs=$(git ls-remote "$GGML_REPO" "refs/tags/$ggml_tag" "refs/tags/$ggml_tag^{}")
    ggml_pin=$(printf '%s\n' "$ggml_refs" | awk -v r="refs/tags/$ggml_tag^{}" '$2 == r {print $1}')
    [ -n "$ggml_pin" ] || ggml_pin=$(printf '%s\n' "$ggml_refs" | awk -v r="refs/tags/$ggml_tag" '$2 == r {print $1}')
    if [ "$ggml_pin" != "$GGML_COMMIT" ]; then
        echo "engine/build.sh: $GGML_REPO has no tag $ggml_tag at $GGML_COMMIT — push it to the fork first: git tag $ggml_tag $GGML_COMMIT; git push $GGML_REPO $ggml_tag" >&2
        exit 1
    fi
    # submodule.ggml.url in .git/config overrides .gitmodules: the update below clones ggml from the
    # fork, where the tag keeps the pinned commit fetchable.
    git -C "$tts" config submodule.ggml.url "$GGML_REPO"
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
if [ -n "$metal_lib" ]; then
    build_metal_lib "$tts/ggml" "$work/tts-metallib-$arch"
    copy_metal_libs "$work/tts-metallib-$arch/bin" tts-server
fi
strip -x "$out/tts-server"
check_static "$out/tts-server"
check_dist "$out/tts-server"
check_patched "$out/tts-server"
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
# One metallib build serves ox-stt and ox-align: identical ggml tree and
# flags. It is reached through engine/align's CMakeLists (see build_metal_lib).
if [ -n "$metal_lib" ]; then
    build_metal_lib "$here/align" "$work/wsp-metallib-$arch" -DWHISPER_SRC="$stt"
    copy_metal_libs "$work/wsp-metallib-$arch/bin" ox-stt
fi
strip -x "$out/ox-stt"
check_static "$out/ox-stt"
check_dist "$out/ox-stt"
check_patched "$out/ox-stt"
cp "$stt/LICENSE" "$out/licenses/whisper.cpp.LICENSE"
echo "built $out/ox-stt"

# --- ox-align (same whisper.cpp tree as ox-stt; only ggml is linked) ---
# Re-set the flags: this block must not depend on whatever the stt block left.
set_cmake_flags "$work/ggml-include-stt"
cmake -S "$here/align" -B "$work/align-build-$arch" -DWHISPER_SRC="$stt" \
    "${cmake_flags[@]}" > "$work/align-configure.log"
cmake --build "$work/align-build-$arch" --target ox-align -j "$jobs" > "$work/align-build.log"
cp "$work/align-build-$arch/ox-align" "$out/ox-align"
if [ -n "$metal_lib" ]; then copy_metal_libs "$work/wsp-metallib-$arch/bin" ox-align; fi
strip -x "$out/ox-align"
check_static "$out/ox-align"
check_dist "$out/ox-align"
check_patched "$out/ox-align"
echo "built $out/ox-align"

# --- ox-llm (llama.cpp's llama-server; the meeting-notes model server) ---
# llama.cpp carries its own ggml, so this engine takes none of engine/patches/ggml
# and builds from its own tree — its metallib handling comes from
# patches/llamacpp instead. The binary is renamed ox-llm on copy: the Metal
# library lookup keys on argv[0] (patches/llamacpp/0001), and every engine in
# out/ needs a name of its own.
ll="$work/llama.cpp"
stamp=$( { echo "$LLAMACPP_REPO $LLAMACPP_COMMIT"; find "$here/patches/llamacpp" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
if ! fresh "$ll" "$stamp"; then
    rm -rf "$ll"
    git clone --quiet "$LLAMACPP_REPO" "$ll"
    git -C "$ll" checkout --quiet "$LLAMACPP_COMMIT"
    actual=$(git -C "$ll" rev-parse HEAD)
    if [ "$actual" != "$LLAMACPP_COMMIT" ]; then
        echo "llama.cpp is $actual, expected the commit $LLAMACPP_COMMIT" >&2
        exit 1
    fi
    for p in "$here"/patches/llamacpp/*.patch; do
        git -C "$ll" apply "$p"
    done
    echo "$stamp" > "$ll/.ox-say-stamp"
fi
include_copy "$ll/ggml" "$work/ggml-include-llm"
set_cmake_flags "$work/ggml-include-llm"
# Server only: no tests, examples, the unified app or HTTPS; LLAMA_USE_PREBUILT_UI=OFF
# keeps the configure from downloading a web UI the daemon never serves.
cmake -S "$ll" -B "$ll/build-$arch" "${cmake_flags[@]}" \
    -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
    > "$work/llm-configure.log"
cmake --build "$ll/build-$arch" --target llama-server -j "$jobs" > "$work/llm-build.log"
cp "$ll/build-$arch/bin/llama-server" "$out/ox-llm"
strip -x "$out/ox-llm"
if [ -n "$metal_lib" ]; then
    build_metal_lib "$ll" "$work/llm-metallib-$arch" \
        -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_APP=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
    copy_metal_libs "$work/llm-metallib-$arch/bin" ox-llm
fi
check_static "$out/ox-llm"
check_dist "$out/ox-llm"
check_patched "$out/ox-llm"
# The daemon starts ox-llm with these flags (internal/daemon/meetings.go notesServerArgs).
check_help_flags "$out/ox-llm" --host --port --api-key-file --cors-origins --cache-ram --flash-attn --jinja --no-ui --ctx-size --n-gpu-layers --parallel
cp "$ll/LICENSE" "$out/licenses/llama.cpp.LICENSE"
# llama.cpp's own list of third-party licences, plus every licence under vendor/
# (cpp-httplib and friends), derived from the tree: a hand list cannot notice one
# it lacks. A tree with none fails the build.
found=$(find "$ll/licenses" "$ll/vendor" -type f \( -iname 'licen[sc]e*' -o -iname 'copying*' \) 2>/dev/null | LC_ALL=C sort)
if [ -z "$found" ]; then
    echo "engine/build.sh: llama.cpp ships no third-party licence files under licenses/ or vendor/" >&2
    exit 1
fi
while IFS= read -r f; do
    rel=${f#"$ll"/}
    cp "$f" "$out/licenses/llama.cpp-${rel//\//_}"
done <<< "$found"
echo "built $out/ox-llm"

# --- ox-diar (speaker diarization: FluidAudio's Core ML port of pyannote community-1) ---
# A Swift package, not a ggml engine: set_cmake_flags and the metallib steps do not apply. It links only system
# frameworks (Core ML, Accelerate, AVFoundation) and the Swift runtime the OS ships, so check_static passes; Swift
# and clang emit no instruction past the baseline, and check_dist proves it on the output. Needs Xcode 26 (Swift
# 6.2) and macOS 15 to run: a source install on an older Mac or with older tools skips it (diar_gate,
# engine/want-diar.sh), a distribution build never does. engine/diar/build.sh reads OX_SAY_DIAR_DEVELOPER_DIR for a
# runner whose default Xcode is older.
# Apple Silicon only: the Intel smoke of plan Task 20a failed (Core ML cannot run the models on .cpuOnly), so the
# x86_64 package carries no ox-diar and the daemon reports cpu_unsupported there. Where the gate opens by itself, a
# build that fails is dropped with a warning instead of failing the install (diar_build, engine/want-diar.sh).
if [ "$arch" != arm64 ]; then
    if [ -e "$out/ox-diar" ]; then
        rm -f "$out/ox-diar"
        echo "engine/build.sh: removed a stale ox-diar from $out: the $arch package carries none (Apple Silicon only)" >&2
    fi
elif diar_gate "$out"; then
    diar_build "$here" "$work" "$out"
fi

# Licences of audio.cpp's vendored dependencies, derived from the tree: a
# hand-written list cannot notice one it lacks. Every licence file under
# external/<dep>/ is copied, named by its path (sentencepiece bundles absl,
# darts_clone, esaxx and protobuf-lite with licences of their own). A dependency
# with none fails the build. A submodule is skipped: it is not built in.
# find's output is captured whole: `find | head -1` under pipefail lets head's
# early exit SIGPIPE find.
copy_audiocpp_licenses() {
    local ac=$1 dst=$2 dep name found f rel submodules
    submodules=$(git -C "$ac" ls-files -s external | awk '$1 == 160000 { print $4 }')
    for dep in "$ac"/external/*/; do
        name=$(basename "$dep")
        case $'\n'"$submodules"$'\n' in
            *$'\n'"external/$name"$'\n'*) continue ;;
        esac
        found=$(find "$dep" -type f \( -iname 'licen[sc]e*' -o -iname 'copying*' \) | LC_ALL=C sort)
        # external/llama_tokenizer is llama.cpp's BPE and unicode code; upstream
        # ships no licence file next to it. llama.cpp and ggml are one project
        # under one MIT licence, so ggml's stands in. Any other dependency
        # without a licence file still fails the build.
        if [ -z "$found" ] && [ "$name" = llama_tokenizer ]; then
            cp "$ac/external/ggml/LICENSE" "$dst/audiocpp-llama_tokenizer_LICENSE"
            continue
        fi
        if [ -z "$found" ]; then
            echo "engine/build.sh: audio.cpp external/$name has no licence file" >&2
            exit 1
        fi
        while IFS= read -r f; do
            rel=${f#"$ac"/external/}
            cp "$f" "$dst/audiocpp-${rel//\//_}"
        done <<< "$found"
    done
}

# --- audiocpp_server (audio.cpp, VoxCPM2) — Apple Silicon, on request only ---
# VoxCPM2 (2B) needs unified memory next to the speech engines; the Intel
# package carries no quality engine (README "VoxCPM2"). audio.cpp vendors its
# own ggml, so engine/patches/ggml (AMD discrete fixes) does not apply here.
# Wanted: a dist build or OX_SAY_WITH_VOXCPM2=1. Otherwise audiocpp_gate drops a
# binary an earlier build left in out/, so the installer cannot pick it up
# (engine/want-audiocpp.sh).
if audiocpp_gate "$arch" "$out"; then
    ac="$work/audio.cpp"
    stamp=$( { echo "$AUDIOCPP_REPO $AUDIOCPP_COMMIT"; find "$here/patches/audiocpp" -name '*.patch' -type f | LC_ALL=C sort | xargs cat; } | shasum -a 256 | cut -d' ' -f1)
    if ! fresh "$ac" "$stamp"; then
        rm -rf "$ac"
        git clone --quiet "$AUDIOCPP_REPO" "$ac"
        git -C "$ac" checkout --quiet "$AUDIOCPP_COMMIT"
        # No `submodule update`: audio.cpp's only submodule, external/audio.cpp-server-frontends,
        # is optional frontends (mp3/miniaudio/HTTPS; AUDIOCPP_BUILD_SERVER_FRONTENDS, OFF here)
        # and .gitmodules points it at git@github.com:, which fails for anyone without an SSH key.
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
    if [ -n "$metal_lib" ]; then
        build_metal_lib "$ac/external/ggml" "$work/ac-metallib-$arch"
        copy_metal_libs "$work/ac-metallib-$arch/bin" audiocpp_server
    fi
    strip -x "$out/audiocpp_server"
    check_static "$out/audiocpp_server"
    check_dist "$out/audiocpp_server"
    check_patched "$out/audiocpp_server"
    cp "$ac/LICENSE" "$out/licenses/audio.cpp.LICENSE"
    copy_audiocpp_licenses "$ac" "$out/licenses"
    echo "built $out/audiocpp_server"
fi

# The commits these binaries were built from, for ox-say-bench's report.
write_pins_stamp "$here/pins.env" "$out"
