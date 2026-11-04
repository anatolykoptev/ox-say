# shellcheck shell=bash
# Sourced by engine/build.sh and scripts/test-lib-install.sh, scripts/test-engine-checks.sh.
#
# The Swift helpers built beside the ggml engines share one gate: ox-diar (speaker diarization, engine/diar) and
# ox-clean (voice cleanup, engine/clean). Both are Swift 6.2 packages (Xcode 26) that refuse to run before macOS 15,
# while a source install is promised to work on macOS 14.2 with the command line tools alone. Each helper declares
# its name, the architectures it is built for, and the two variables that steer it; everything else is one code path:
#
#   helper     built for        asks with            names an Xcode 26 in
#   diar       arm64            OX_SAY_WITH_DIAR=1   OX_SAY_DIAR_DEVELOPER_DIR
#   clean      arm64 x86_64     OX_SAY_WITH_CLEAN=1  OX_SAY_CLEAN_DEVELOPER_DIR
#
# (diar is Apple Silicon only: the Intel smoke failed, plan Task 20a. clean runs on Intel too: decision 8 of the
# voice-cleanup plan, measured on a real Intel Mac.) The public names of the first helper (diar_mode, want_diar,
# diar_can_build, diar_gate, diar_build) stay as thin wrappers for their callers and tests.
#
# helper_mode <name>: why the helper should be built, one word on stdout; fails, printing nothing, when it should not.
# A source build makes it only when it can, or when asked:
#   dist       OX_SAY_DIST=1: release packaging. The package must carry it, and a toolchain that cannot build it fails
#              the build loudly instead of shipping a package without it
#   requested  the helper's OX_SAY_WITH_* variable is 1: the user asks for it and has the toolchain (the helper's
#              OX_SAY_*_DEVELOPER_DIR names an Xcode 26). A build failure is fatal
#   auto       macOS 15 or later with Swift 6.2 or later already selected (or named by OX_SAY_*_DEVELOPER_DIR) and
#              nobody asked. A build failure must not break an install that worked before: see helper_build
helper_mode() {
    local ask
    ask=$(helper_var "$1" WITH) || return 1
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        echo dist
    elif [ "${!ask:-0}" = 1 ]; then
        echo requested
    elif helper_can_build "$1"; then
        echo auto
    else
        return 1
    fi
}

# helper_var <name> WITH|DEVELOPER_DIR: the name of the environment variable that steers the helper.
helper_var() {
    case $1 in
        diar | clean) ;;
        *) echo "engine/want-diar.sh: no Swift helper called '$1'" >&2; return 1 ;;
    esac
    case $2 in
        WITH) echo "OX_SAY_WITH_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" ;;
        DEVELOPER_DIR) echo "OX_SAY_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')_DEVELOPER_DIR" ;;
        *) return 1 ;;
    esac
}

# helper_archs <name>: the architectures the helper is built for, space separated (uname -m spelling).
helper_archs() {
    case $1 in
        diar) echo "arm64" ;;
        clean) echo "arm64 x86_64" ;;
        *) echo "engine/want-diar.sh: no Swift helper called '$1'" >&2; return 1 ;;
    esac
}

# helper_title <name>: what the helper is for, in the words of the messages.
helper_title() {
    case $1 in
        diar) echo "speaker diarization" ;;
        clean) echo "voice cleanup" ;;
        *) return 1 ;;
    esac
}

# helper_builds_on <name> <arch>: true when the helper is built for that architecture.
helper_builds_on() {
    local a
    for a in $(helper_archs "$1"); do
        [ "$a" = "$2" ] && return 0
    done
    return 1
}

helper_can_build() {
    local major version swift_major swift_minor devdir
    major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    [ "${major:-0}" -ge 15 ] 2>/dev/null || return 1
    devdir=$(helper_var "$1" DEVELOPER_DIR) || return 1
    if [ -n "${!devdir:-}" ]; then
        version=$(DEVELOPER_DIR=${!devdir} swift --version 2>/dev/null)
    else
        version=$(swift --version 2>/dev/null)
    fi
    version=$(printf '%s\n' "$version" | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -1)
    read -r swift_major swift_minor <<< "$version"
    [ -n "${swift_minor:-}" ] || return 1
    [ "$swift_major" -gt 6 ] || { [ "$swift_major" -eq 6 ] && [ "$swift_minor" -ge 2 ]; }
}

# helper_gate <name> <out-dir>: true when the build should go on, with HELPER_MODE set to the mode that opened it
# (helper_mode) and one line on stderr naming it. When it is not wanted, drop a binary an earlier build left in
# <out-dir> (an installer copies whatever is there), say so in one line, and return false: the daemon then reports the
# helper as unavailable (os_too_old or engine_missing) and carries on without it.
helper_gate() {
    local name=$1 out=$2 ask devdir
    if HELPER_MODE=$(helper_mode "$name"); then
        echo "engine/build.sh: building ox-$name ($(helper_title "$name")), mode: $HELPER_MODE" >&2
        return 0
    fi
    HELPER_MODE=
    ask=$(helper_var "$name" WITH)
    devdir=$(helper_var "$name" DEVELOPER_DIR)
    rm -f "$out/ox-$name"
    echo "engine/build.sh: ox-$name ($(helper_title "$name")) not built: it needs macOS 15+ and Swift 6.2+ (Xcode 26; $devdir names one); $ask=1 builds it anyway" >&2
    return 1
}

# helper_build <name> <mode> <engine-dir> <work-dir> <out-dir>: build ox-<name> and run engine/build.sh's check_static
# and check_dist on it (the caller defines them). Where the gate opened by itself (mode auto) a failure drops the
# binary, warns once and returns 0: a source install that worked before must keep working. A requested or release
# build fails.
helper_build() {
    local name=$1 mode=$2 here=$3 work=$4 out=$5 ask
    if ("$here/$name/build.sh" "$work" "$out" && check_static "$out/ox-$name" && check_dist "$out/ox-$name"); then
        echo "built $out/ox-$name"
        return 0
    fi
    if [ "$mode" = auto ]; then
        ask=$(helper_var "$name" WITH)
        rm -f "$out/ox-$name"
        echo "engine/build.sh: warning: ox-$name did not build (see above); continuing without $(helper_title "$name"). $ask=1 makes this fatal" >&2
        return 0
    fi
    return 1
}

# build_swift_helper <name> <arch> <engine-dir> <work-dir> <out-dir>: engine/build.sh's whole step for one helper. On
# an architecture the helper is not built for, a binary an earlier build left in <out-dir> goes and the step ends
# (the package for that architecture carries none); elsewhere the gate decides and helper_build builds.
build_swift_helper() {
    local name=$1 arch=$2 here=$3 work=$4 out=$5
    if ! helper_builds_on "$name" "$arch"; then
        if [ -e "$out/ox-$name" ]; then
            rm -f "$out/ox-$name"
            echo "engine/build.sh: removed a stale ox-$name from $out: the $arch package carries none (built for: $(helper_archs "$name"))" >&2
        fi
        return 0
    fi
    if helper_gate "$name" "$out"; then
        helper_build "$name" "$HELPER_MODE" "$here" "$work" "$out"
    fi
}

# --- ox-diar: the first helper's names, kept for their callers ---
diar_mode() { helper_mode diar; }

want_diar() {
    diar_mode > /dev/null
}

diar_can_build() { helper_can_build diar; }

# diar_gate <out-dir>: helper_gate for ox-diar, with DIAR_MODE set to the mode that opened it.
diar_gate() {
    local rc=0
    helper_gate diar "$1" || rc=$?
    DIAR_MODE=$HELPER_MODE
    return "$rc"
}

# diar_build <engine-dir> <work-dir> <out-dir>: helper_build for ox-diar in the mode diar_gate recorded.
diar_build() {
    helper_build diar "${DIAR_MODE:-}" "$@"
}

# --- ox-clean ---
clean_mode() { helper_mode clean; }

want_clean() {
    clean_mode > /dev/null
}
