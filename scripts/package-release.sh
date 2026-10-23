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
# One package per architecture, built on a Mac of that architecture: the
# engines, the dictation app and the Go binary all target $(uname -m).
arch=$(uname -m)
case $arch in
    x86_64) goarch=amd64; baseline=check-no-avx512.sh ;;
    arm64) goarch=arm64; baseline=check-arm64-baseline.sh ;;
    *) echo "package-release.sh: unsupported architecture $arch" >&2; exit 1 ;;
esac
asset=ox-say-macos-$arch.tar.gz

OX_SAY_DIST=1 "$root/engine/build.sh" "$work"
VERSION="$version" "$root/app/dictation/build.sh"
(cd "$root" && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go build -trimpath \
    -ldflags "-s -w -X main.version=$version" -o "$root/build/ox-say-dist" ./cmd/ox-say)

# The engines must stay within the architecture's distribution baseline:
# x86_64 without AVX-512 (most Intel MacBooks have none), arm64 without the
# i8mm/BF16/SME an M1 lacks. One such instruction is a SIGILL there, and a
# build machine that has it would slip it in silently. The guards fail
# closed on an otool error.
for bin in tts-server ox-stt ox-align $( [ -f "$work/out/audiocpp_server" ] && echo audiocpp_server ); do
    "$root/scripts/$baseline" "$work/out/$bin"
done

rm -rf "$root/build/release" "$dist"
mkdir -p "$stage/bin" "$stage/engine/licenses" "$stage/launchd" "$stage/scripts" "$dist"
echo "$version" > "$stage/VERSION"
cp "$root/build/ox-say-dist" "$stage/bin/ox-say"
cp "$work"/out/tts-server "$work"/out/ox-stt "$work"/out/ox-align "$stage/engine/"
# VoxCPM2's server: the arm64 package only.
if [ -f "$work/out/audiocpp_server" ]; then
    cp "$work/out/audiocpp_server" "$stage/engine/"
fi
# The precompiled Metal libraries: each engine probes <bin>.metallib next to
# the binary and falls back to the shader source embedded in it, so a package
# without them would still run — with the old first-run shader compile for
# every user. That compile is what this release removes, so refuse to package
# without the libraries. arm64 also carries <bin>-tensor.metallib (Metal4
# devices; only a macOS 26 SDK toolchain builds them).
metallibs="tts-server.metallib ox-stt.metallib ox-align.metallib"
if [ "$arch" = arm64 ]; then
    metallibs="$metallibs audiocpp_server.metallib tts-server-tensor.metallib ox-stt-tensor.metallib ox-align-tensor.metallib"
fi
for lib in $metallibs; do
    if [ -s "$work/out/$lib" ]; then
        continue
    fi
    case $lib in
        *-tensor.metallib)
            echo "package-release.sh: $lib missing from $work/out — it builds only with the Metal toolchain on the macOS 26 SDK (xcodebuild -downloadComponent MetalToolchain on Xcode 26)" >&2 ;;
        *)
            echo "package-release.sh: $lib missing from $work/out — it needs the Metal toolchain (xcodebuild -downloadComponent MetalToolchain)" >&2 ;;
    esac
    exit 1
done
cp "$work"/out/*.metallib "$stage/engine/"
cp "$work"/out/licenses/* "$stage/engine/licenses/"
cp "$root"/launchd/*.plist.in "$stage/launchd/"
cp "$root"/scripts/install-release.sh "$root"/scripts/lib-install.sh "$root"/scripts/fetch-models.sh \
    "$root"/scripts/uninstall.sh "$root"/app/dictation/install-app.sh "$stage/scripts/"
mkdir -p "$stage/app"
ditto "$root/build/dictation/OxSayDictation.app" "$stage/app/OxSayDictation.app"
cp "$root"/LICENSE "$root"/NOTICE "$root"/README.md "$stage/"

# The Go binary is statically linked: ship the license of every module it
# links, the way engine/licenses does for the C++ engines, plus the Go
# runtime's own. A module with no license file fails the package — shipping a
# binary without its notices is worse than no build.
modpath=$(cd "$root" && go list -m)
(cd "$root" && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go list -deps -f '{{with .Module}}{{.Path}} {{.Dir}}{{end}}' ./cmd/ox-say | sort -u) \
    > "$work/go-modules.txt"
while read -r mod dir; do
    if [ -z "${mod:-}" ] || [ -z "${dir:-}" ] || [ "$mod" = "$modpath" ]; then
        continue
    fi
    dst="$stage/licenses/go/${mod//\//_}"
    mkdir -p "$dst"
    found=
    for f in "$dir"/LICENSE* "$dir"/LICENCE* "$dir"/COPYING* "$dir"/NOTICE*; do
        if [ -f "$f" ]; then
            cp "$f" "$dst/"
            found=1
        fi
    done
    if [ -z "$found" ]; then
        echo "module $mod ($dir) ships no LICENSE/COPYING/NOTICE — cannot package a binary that links it" >&2
        exit 1
    fi
done < "$work/go-modules.txt"
# Go's own license lives at GOROOT/LICENSE in a source install; Homebrew puts
# it one level above libexec.
golicense=$(go env GOROOT)/LICENSE
[ -f "$golicense" ] || golicense=$(dirname "$(go env GOROOT)")/LICENSE
if [ ! -f "$golicense" ]; then
    echo "Go's LICENSE not found under $(go env GOROOT) or its parent" >&2
    exit 1
fi
mkdir -p "$stage/licenses/go/go"
cp "$golicense" "$stage/licenses/go/go/LICENSE"

# COPYFILE_DISABLE: no AppleDouble ._ files for extended attributes in the archive
COPYFILE_DISABLE=1 tar -C "$root/build/release" -czf "$dist/$asset" ox-say
(cd "$dist" && shasum -a 256 "$asset" > SHA256SUMS)
cat "$dist/SHA256SUMS"
