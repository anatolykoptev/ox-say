#!/usr/bin/env bash
# Package a release for get.sh: builds the engines in distribution mode and the
# ox-say binary, lays them out as get.sh expects and writes the tarball plus
# SHA256SUMS into dist/.
#   scripts/package-release.sh <version>      e.g. v0.2.0
set -euo pipefail

version=${1:?usage: $0 <version>}
root=$(cd "$(dirname "$0")/.." && pwd -P)
work="$root/build/engine-dist"
stage="$root/build/release/ox-say"
dist="$root/dist"
asset=ox-say-macos-x86_64.tar.gz

OX_SAY_DIST=1 "$root/engine/build.sh" "$work"
(cd "$root" && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath \
    -ldflags "-s -w -X main.version=$version" -o "$root/build/ox-say-dist" ./cmd/ox-say)

# The engines must not use AVX-512: most Intel MacBooks have none, and one such
# instruction is a SIGILL there. -march=native on a build machine that has it
# would slip this in silently.
for bin in tts-server ox-stt ox-align; do
    # grep -c reads everything: a `| grep -q` would exit early, SIGPIPE otool
    # and, under pipefail, turn a match into a pass.
    zmm=$(otool -tv "$work/out/$bin" | grep -c '%zmm' || true)
    if [ "${zmm:-0}" -gt 0 ]; then
        echo "$bin uses AVX-512 registers ($zmm instructions); distribution builds must not" >&2
        exit 1
    fi
done

rm -rf "$root/build/release" "$dist"
mkdir -p "$stage/bin" "$stage/engine/licenses" "$stage/launchd" "$stage/scripts" "$dist"
echo "$version" > "$stage/VERSION"
cp "$root/build/ox-say-dist" "$stage/bin/ox-say"
cp "$work"/out/tts-server "$work"/out/ox-stt "$work"/out/ox-align "$stage/engine/"
cp "$work"/out/licenses/* "$stage/engine/licenses/"
cp "$root"/launchd/*.plist.in "$stage/launchd/"
cp "$root"/scripts/install-release.sh "$root"/scripts/lib-install.sh "$root"/scripts/fetch-models.sh \
    "$root"/scripts/uninstall.sh "$stage/scripts/"
cp "$root"/LICENSE "$root"/NOTICE "$root"/README.md "$stage/"

tar -C "$root/build/release" -czf "$dist/$asset" ox-say
(cd "$dist" && shasum -a 256 "$asset" > SHA256SUMS)
cat "$dist/SHA256SUMS"
