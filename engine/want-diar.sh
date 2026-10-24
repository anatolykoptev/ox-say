# shellcheck shell=bash
# Sourced by engine/build.sh and scripts/test-lib-install.sh.
#
# diar_mode: why ox-diar (speaker diarization) should be built, one word on stdout; fails, printing nothing, when it
# should not. It is a Swift 6.2 package (Xcode 26) and refuses to run before macOS 15, while a source install is
# promised to work on macOS 13.3 with the command line tools alone. So a source build makes it only when it can, or
# when asked:
#   dist       OX_SAY_DIST=1: release packaging. The package must carry it, and a toolchain that cannot build it fails
#              the build loudly instead of shipping a package without it
#   requested  OX_SAY_WITH_DIAR=1: the user asks for it and has the toolchain (OX_SAY_DIAR_DEVELOPER_DIR names an
#              Xcode 26). A build failure is fatal
#   auto       macOS 15 or later with Swift 6.2 or later already selected (or named by OX_SAY_DIAR_DEVELOPER_DIR) and
#              nobody asked. A build failure must not break an install that worked before: see diar_build
diar_mode() {
    if [ "${OX_SAY_DIST:-0}" = 1 ]; then
        echo dist
    elif [ "${OX_SAY_WITH_DIAR:-0}" = 1 ]; then
        echo requested
    elif diar_can_build; then
        echo auto
    else
        return 1
    fi
}

want_diar() {
    diar_mode > /dev/null
}

diar_can_build() {
    local major version swift_major swift_minor
    major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    [ "${major:-0}" -ge 15 ] 2>/dev/null || return 1
    if [ -n "${OX_SAY_DIAR_DEVELOPER_DIR:-}" ]; then
        version=$(DEVELOPER_DIR=$OX_SAY_DIAR_DEVELOPER_DIR swift --version 2>/dev/null)
    else
        version=$(swift --version 2>/dev/null)
    fi
    version=$(printf '%s\n' "$version" | sed -n 's/.*Swift version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -1)
    read -r swift_major swift_minor <<< "$version"
    [ -n "${swift_minor:-}" ] || return 1
    [ "$swift_major" -gt 6 ] || { [ "$swift_major" -eq 6 ] && [ "$swift_minor" -ge 2 ]; }
}

# diar_gate <out-dir>: true when the build should go on, with DIAR_MODE set to the mode that opened it (diar_mode) and
# one line on stderr naming it. When it is not wanted, drop an ox-diar an earlier build left in <out-dir> (an
# installer copies whatever is there), say so in one line, and return false: the daemon then reports the diarizer as
# unavailable (os_too_old or engine_missing) and records meetings without voices.
diar_gate() {
    if DIAR_MODE=$(diar_mode); then
        echo "engine/build.sh: building ox-diar (speaker diarization), mode: $DIAR_MODE" >&2
        return 0
    fi
    DIAR_MODE=
    rm -f "$1/ox-diar"
    echo "engine/build.sh: ox-diar (speaker diarization) not built: it needs macOS 15+ and Swift 6.2+ (Xcode 26; OX_SAY_DIAR_DEVELOPER_DIR names one); OX_SAY_WITH_DIAR=1 builds it anyway" >&2
    return 1
}

# diar_build <engine-dir> <work-dir> <out-dir>: build ox-diar and run engine/build.sh's check_static and check_dist
# on it (the caller defines them). Where the gate opened by itself (DIAR_MODE=auto) a failure drops the binary, warns
# once and returns 0: a source install that worked before must keep working. A requested or release build fails.
diar_build() {
    local here=$1 work=$2 out=$3
    if ("$here/diar/build.sh" "$work" "$out" && check_static "$out/ox-diar" && check_dist "$out/ox-diar"); then
        echo "built $out/ox-diar"
        return 0
    fi
    if [ "${DIAR_MODE:-}" = auto ]; then
        rm -f "$out/ox-diar"
        echo "engine/build.sh: warning: ox-diar did not build (see above); continuing without speaker diarization. OX_SAY_WITH_DIAR=1 makes this fatal" >&2
        return 0
    fi
    return 1
}
