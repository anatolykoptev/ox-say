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
