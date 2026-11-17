#!/usr/bin/env bash
# check-package-contents.sh <build-out-dir> <staged-engine-dir>
#
# Every engine binary the build left in <build-out-dir> must be in the staged
# package: a name dropped from package-release.sh's copy list would ship a
# package missing an engine the build produced, with no error anywhere. The
# expected set is read off the build output itself — out/ holds only engine
# binaries, *.metallib, pins.env and the licenses/ directory — not a second
# hand-written list that could forget the same name.
set -euo pipefail

out=${1:?usage: $0 <build-out-dir> <staged-engine-dir>}
stage=${2:?usage: $0 <build-out-dir> <staged-engine-dir>}
missing=0
for f in "$out"/*; do
    name=${f##*/}
    case $name in
        pins.env | *.metallib) continue ;;
    esac
    [ -f "$f" ] || continue # licenses/ is a directory; it travels by its own glob
    if [ ! -f "$stage/$name" ]; then
        echo "check-package-contents.sh: $name is in the build output but not in the package" >&2
        missing=1
    fi
done
exit "$missing"
