# shellcheck shell=bash
# Sourced by engine/build.sh and scripts/test-engine-checks.sh. Checks on a built engine binary.
# Every failure is a `return 1` with a message, also where errexit is suppressed (a caller inside
# `if ( … )` or a `&&` chain, as diar_build in want-diar.sh): a command substitution that fails
# must not leave an empty string for the next test to pass.

# check_static <binary>: a thin binary of $arch (set by the caller) with no @rpath dependency.
# shellcheck disable=SC2154 # arch comes from engine/build.sh / the test
check_static() {
    local libs archs
    archs=$(lipo -archs "$1") || { echo "$1: lipo could not read it" >&2; return 1; }
    if [ "$archs" != "$arch" ]; then
        echo "$1 is built for $archs, expected $arch" >&2
        return 1
    fi
    # Capture, then match: `otool | grep -q` under pipefail lets grep's early
    # exit SIGPIPE otool and turn a hit into a pass. A failed otool is a failure,
    # not an empty list of libraries.
    libs=$(otool -L "$1") || { echo "$1: otool -L failed; cannot check its libraries" >&2; return 1; }
    case $libs in
        *@rpath*)
            echo "$1 still links @rpath libraries:" >&2
            printf '%s\n' "$libs" >&2
            return 1
            ;;
    esac
}

# The format string the Metal patches (patches/ggml/0003, patches/audiocpp/0003,
# patches/llamacpp/0001) add. A binary built from an unpatched tree lacks it and would
# ignore its precompiled <bin>.metallib, silently compiling shaders at every first run.
OXS_METALLIB_PATCH_MARKER="the precompiled metal library targets macOS 14.0"

# check_patched <binary>: the binary carries the Metal patch's marker string. grep -c reads
# everything (no SIGPIPE under pipefail); a grep error (status 2) is a failure too.
check_patched() {
    local n rc=0
    n=$(grep -aFc -- "$OXS_METALLIB_PATCH_MARKER" "$1") || rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "$1: could not search it for the Metal patch marker" >&2
        return 1
    fi
    if [ "${n:-0}" = 0 ]; then
        echo "$1 lacks the Metal patch ('$OXS_METALLIB_PATCH_MARKER'): it was built from an unpatched tree and would ignore its precompiled metallib" >&2
        return 1
    fi
}

# check_help_flags <binary> <flag>...: the binary's --help names every flag. The daemon starts ox-llm
# with these (internal/daemon/meetings.go notesServerArgs); a llama.cpp bump that renames one would
# make every notes run fail at spawn. The help text is captured whole: under pipefail `| grep -q` can
# SIGPIPE the writer and fail a pass. The exit status is ignored (usage may exit nonzero), the text is not.
check_help_flags() {
    local bin=$1 help flag
    shift
    help=$("$bin" --help 2>&1 || true)
    if [ -z "$help" ]; then
        echo "engine/lib-check.sh: $bin --help printed nothing (it did not run, or is not the server); cannot check its flags" >&2
        return 1
    fi
    for flag in "$@"; do
        case $help in
            *"$flag"*) ;;
            *)
                echo "engine/lib-check.sh: $bin no longer has $flag; the daemon would fail to start it" >&2
                return 1
                ;;
        esac
    done
}
