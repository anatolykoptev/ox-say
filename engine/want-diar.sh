# shellcheck shell=bash
# Sourced by engine/build.sh and scripts/test-lib-install.sh.
#
# want_diar: build ox-diar (speaker diarization)? It is a Swift 6.2 package (Xcode 26) and refuses to run before
# macOS 15, while a source install is promised to work on macOS 13.3 with the command line tools alone. So a source
# build makes it only when it can, or when asked:
#   OX_SAY_DIST=1        release packaging: the package must carry it, and a toolchain that cannot build it fails
#                        the build loudly instead of shipping a package without it
#   OX_SAY_WITH_DIAR=1   the user asks for it and has the toolchain (OX_SAY_DIAR_DEVELOPER_DIR names an Xcode 26)
#   macOS 15 or later with Swift 6.2 or later already selected (or named by OX_SAY_DIAR_DEVELOPER_DIR)
want_diar() {
    [ "${OX_SAY_DIST:-0}" = 1 ] || [ "${OX_SAY_WITH_DIAR:-0}" = 1 ] || diar_can_build
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

# diar_gate <out-dir>: true when the build should go on. When it is not wanted, drop an ox-diar an earlier build left
# in <out-dir> (an installer copies whatever is there), say so in one line, and return false: the daemon then
# reports the diarizer as unavailable (os_too_old or engine_missing) and records meetings without voices.
diar_gate() {
    if want_diar; then
        return 0
    fi
    rm -f "$1/ox-diar"
    echo "engine/build.sh: ox-diar (speaker diarization) not built: it needs macOS 15+ and Swift 6.2+ (Xcode 26); OX_SAY_WITH_DIAR=1 builds it anyway" >&2
    return 1
}
