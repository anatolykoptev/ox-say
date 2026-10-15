# shellcheck shell=bash
# Sourced by engine/build.sh and scripts/test-lib-install.sh.
#
# want_audiocpp <arch>: build audio.cpp's server (VoxCPM2)? Only on arm64, and
# only when asked: a distribution build (release packaging sets OX_SAY_DIST=1, so
# the arm64 package always carries it) or OX_SAY_WITH_VOXCPM2=1. A plain source
# install must not clone and build a second engine nobody requested.
want_audiocpp() {
    [ "$1" = arm64 ] && { [ "${OX_SAY_DIST:-0}" = 1 ] || [ "${OX_SAY_WITH_VOXCPM2:-0}" = 1 ]; }
}

# audiocpp_gate <arch> <out-dir>: true when the build should go on. When it is
# not wanted, drop an audiocpp_server an earlier build left in <out-dir> (an
# installer copies whatever is there) and return false.
audiocpp_gate() {
    if want_audiocpp "$1"; then
        return 0
    fi
    rm -f "$2/audiocpp_server"
    return 1
}
