#!/bin/bash
# The release signing job refuses a bundle holding any file scripts/sign-release.sh
# does not list (check_bundle), and it runs only on a release — so a file added to
# app/dictation/build.sh without the allowlist breaks the first release after it.
# This compares a freshly built app with that allowlist on every PR.
#
# Usage: bash scripts/test-bundle-shape.sh [path/to/OxSayDictation.app]
#   default: build/dictation/OxSayDictation.app (run app/dictation/build.sh first)
#
# Mutation: delete a `Contents/Resources/*.lproj/InfoPlist.strings` line from
# bundle_files in sign-release.sh -> this script exits 1 naming the file.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd -P)
app=${1:-"$root/build/dictation/OxSayDictation.app"}
[ -d "$app" ] || { echo "test-bundle-shape: no bundle at $app (run app/dictation/build.sh)" >&2; exit 2; }

allowed=$(sed -n "/^bundle_files='/,/'\$/p" "$root/scripts/sign-release.sh" | sed "s/^bundle_files='//; s/'\$//")
[ -n "$allowed" ] || { echo "test-bundle-shape: cannot read bundle_files from sign-release.sh" >&2; exit 2; }
extra=$(cd "$app" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | LC_ALL=C comm -23 - <(printf '%s\n' "$allowed" | LC_ALL=C sort))
if [ -n "$extra" ]; then
    echo "bundle holds files scripts/sign-release.sh does not allow:" >&2
    printf '  %s\n' $extra >&2
    exit 1
fi
echo "ok   the bundle holds only files sign-release.sh allows"
