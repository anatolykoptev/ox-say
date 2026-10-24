#!/usr/bin/env bash
# Build ox-diar, the speaker diarization engine (FluidAudio's Core ML port of pyannote's community-1 pipeline), for
# this Mac's architecture. engine/build.sh calls it; it also runs on its own.
#   engine/diar/build.sh <work-dir> <out-dir>      -> <out-dir>/ox-diar and its licences in <out-dir>/licenses/
#
# SwiftPM resolves FluidAudio from Package.resolved (--force-resolved-versions: a build never moves the pin) and
# needs network once per work-dir. The manifest asks for Swift tools 6.2, so Xcode 26: a runner whose default Xcode
# is older names one in OX_SAY_DIAR_DEVELOPER_DIR (release.yml does for the Intel image).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: $0 <work-dir> <out-dir>}
out=${2:?usage: $0 <work-dir> <out-dir>}
mkdir -p "$work" "$out/licenses"
work=$(cd "$work" && pwd)
out=$(cd "$out" && pwd)

arch=$(uname -m)
case $arch in
    x86_64 | arm64) ;;
    *) echo "engine/diar/build.sh: unsupported architecture $arch" >&2; exit 1 ;;
esac
if [ -n "${OX_SAY_DIAR_DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=$OX_SAY_DIAR_DEVELOPER_DIR
fi

scratch="$work/diar-build-$arch"
cp "$here/Package.resolved" "$work/Package.resolved.before"
if ! swift build -c release --package-path "$here" --scratch-path "$scratch" --arch "$arch" --force-resolved-versions \
    > "$work/diar-build.log" 2>&1; then
    tail -30 "$work/diar-build.log" >&2
    echo "engine/diar/build.sh: swift build failed (Swift tools 6.2 needs Xcode 26: set OX_SAY_DIAR_DEVELOPER_DIR)" >&2
    exit 1
fi
bin=$(swift build -c release --package-path "$here" --scratch-path "$scratch" --arch "$arch" --force-resolved-versions --show-bin-path)/ox-diar
cp "$bin" "$out/ox-diar"
strip -x "$out/ox-diar"

# A build must not move the pin: --force-resolved-versions refuses a conflicting manifest, but the toolchain may still
# rewrite Package.resolved (its originHash is computed by SwiftPM), and a different Xcode on another runner would
# then build something nobody committed.
if ! cmp -s "$work/Package.resolved.before" "$here/Package.resolved"; then
    echo "engine/diar/build.sh: this toolchain rewrote Package.resolved; commit that change or use the pinned Xcode" >&2
    exit 1
fi

# The binary must name the FluidAudio SwiftPM resolved and the models fetch-models.sh downloads. plutil reads
# Package.resolved (JSON); a mismatch is a Pins.swift nobody updated.
fluid=$(plutil -extract pins.0.state.version raw -o - "$here/Package.resolved")
rev=$(sed -n 's/^diar_rev=\([0-9a-f]\{8\}\).*/\1/p' "$here/../../scripts/fetch-models.sh")
want="ox-diar 1 (FluidAudio $fluid, models $rev)"
got=$("$out/ox-diar" --version)
if [ "$got" != "$want" ]; then
    echo "engine/diar/build.sh: ox-diar reports '$got', expected '$want'" >&2
    exit 1
fi

# Licences, derived from the resolved checkout: a hand list cannot notice one it lacks. FluidAudio's own (Apache-2.0)
# and every third-party licence it ships (fastcluster, VBx, ...).
checkout="$scratch/checkouts/FluidAudio"
if [ ! -f "$checkout/LICENSE" ]; then
    echo "engine/diar/build.sh: no LICENSE in the FluidAudio checkout $checkout" >&2
    exit 1
fi
cp "$checkout/LICENSE" "$out/licenses/FluidAudio.LICENSE"
for f in "$checkout"/ThirdPartyLicenses/*.md; do
    [ -f "$f" ] && cp "$f" "$out/licenses/FluidAudio-$(basename "$f")"
done
echo "built $out/ox-diar ($want)"
