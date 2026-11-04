#!/usr/bin/env bash
# Build ox-clean, the offline voice-cleanup helper (MossFormer2_SE_48K on Core ML), for this Mac's architecture.
# engine/build.sh will call it (Task 9); it also runs on its own.
#   engine/clean/build.sh <work-dir> <out-dir>      -> <out-dir>/ox-clean and its licences in <out-dir>/licenses/
#
# One build per host architecture (x86_64 or arm64); the universal binary is Task 9's. The package has no dependencies,
# so there is no Package.resolved to guard. The manifest asks for Swift tools 6.2, so Xcode 26: a runner whose default
# Xcode is older names one in OX_SAY_CLEAN_DEVELOPER_DIR.
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
    *) echo "engine/clean/build.sh: unsupported architecture $arch" >&2; exit 1 ;;
esac
if [ -n "${OX_SAY_CLEAN_DEVELOPER_DIR:-}" ]; then
    export DEVELOPER_DIR=$OX_SAY_CLEAN_DEVELOPER_DIR
fi

scratch="$work/clean-build-$arch"
if ! swift build -c release --package-path "$here" --scratch-path "$scratch" --arch "$arch" --product ox-clean \
    > "$work/clean-build.log" 2>&1; then
    tail -30 "$work/clean-build.log" >&2
    echo "engine/clean/build.sh: swift build failed (Swift tools 6.2 needs Xcode 26: set OX_SAY_CLEAN_DEVELOPER_DIR)" >&2
    exit 1
fi
bin=$(swift build -c release --package-path "$here" --scratch-path "$scratch" --arch "$arch" --product ox-clean --show-bin-path)/ox-clean
cp "$bin" "$out/ox-clean"
strip -x "$out/ox-clean"

# The binary must name the model revision scripts/fetch-models.sh downloads. A Pins.swift nobody updated (or a
# fetch-models.sh bumped alone) fails here, not in the field. Not a unit test: it needs a built binary.
rev=$(sed -n 's/^clean_rev=\([0-9a-f]\{8\}\)[0-9a-f]*$/\1/p' "$here/../../scripts/fetch-models.sh")
if [ -z "$rev" ]; then
    echo "engine/clean/build.sh: no clean_rev=<40 hex> line in scripts/fetch-models.sh" >&2
    exit 1
fi
want="ox-clean 1 (model $rev)"
got=$("$out/ox-clean" --version)
if [ "$got" != "$want" ]; then
    echo "engine/clean/build.sh: ox-clean reports '$got', expected '$want'" >&2
    exit 1
fi

# Licences: the package has no dependencies, so the only third-party text is the model's. The weights are a derivative
# conversion of Alibaba SLAB's MossFormer2_SE_48K (Apache-2.0); LICENSE and NOTICE ship beside the binary.
cp -f "$here/model/LICENSE" "$out/licenses/MossFormer2-SE.LICENSE"
cp -f "$here/model/NOTICE.md" "$out/licenses/NOTICE.md"
echo "built $out/ox-clean ($want)"
