# shellcheck shell=bash
# Sourced by engine/build.sh.
#
# want_aec: build ox-aec (WebRTC AEC3, engine/aec)? Only when asked:
# OX_SAY_WITH_AEC=1 on the full path, or OX_SAY_ONLY=aec — that one exits
# before the gate is reached. A plain full build must not clone webrtc and run
# meson for a binary no installer or package stage yet; unlike the Swift
# helpers, having the toolchain does NOT opt in — a source install that has
# meson for other reasons must not suddenly build an AEC engine.
# Distribution builds are not wanted either: the packager ships no ox-aec, so
# building it there would only leave stale licence notices in out/licenses.
want_aec() {
    [ "${OX_SAY_WITH_AEC:-0}" = 1 ]
}

# aec_gate <out-dir>: true when the build should go on. When it is not wanted,
# drop an ox-aec an earlier build left in <out-dir> — an installer copies
# whatever is there — and the licence files build_ox_aec wrote: the packager
# ships every file in out/licenses, so notices for a binary that is not there
# must not stay.
aec_gate() {
    if want_aec; then
        return 0
    fi
    rm -f "$1/ox-aec" \
        "$1/licenses/webrtc-audio-processing.LICENSE" \
        "$1/licenses/abseil-cpp.LICENSE" \
        "$1/licenses/pffft.LICENSE" \
        "$1/licenses/rnnoise.COPYING" \
        "$1/licenses/webrtc-fft-olesen.LICENSE" \
        "$1/licenses/ooura-fft.LICENSE"
    echo "engine/build.sh: ox-aec not built (OX_SAY_WITH_AEC=1 builds it; OX_SAY_ONLY=aec builds only it)" >&2
    return 1
}
