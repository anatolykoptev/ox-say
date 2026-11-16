#!/bin/bash
# Tests for scripts/release-notes-floor.sh on tiny stand-in packages (plists in the package's own layout).
# Run: bash scripts/test-release-notes-floor.sh
# Mutations (each must turn the named cases RED):
#   * release-notes-floor.sh: read the key `LSMinimumSystemVersion` as `CFBundleVersion` -> "reads the packaged floor"
#   * drop the `grep -v` of the old marker -> "a second run replaces the marker"
#   * write to "$notes" before the floor checks -> "an unreadable floor leaves the notes alone"
set -u
root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-floortest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT
check() { if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s - got [%s], want [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi; }

pkg() { # name plist-body
    local d="$tmp/$1-src/ox-say/app/OxSayDictation.app/Contents"
    mkdir -p "$d"
    printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n%s\n</dict></plist>\n' "$2" >"$d/Info.plist"
    tar -C "$tmp/$1-src" -czf "$tmp/$1.tar.gz" ox-say
}
pkg good '<key>CFBundleVersion</key><string>7</string>
    <key>LSMinimumSystemVersion</key><string>14.2</string>'
pkg three '    <key>LSMinimumSystemVersion</key><string>15.4.1</string>'
pkg none '<key>CFBundleVersion</key><string>7</string>'
pkg junk '<key>LSMinimumSystemVersion</key><string>latest</string>'
pkg dots '<key>LSMinimumSystemVersion</key><string>14..2</string>'

run() { sh "$root/scripts/release-notes-floor.sh" "$@" >"$tmp/out" 2>&1; echo $?; }

printf '## Fixes\n- one\n' >"$tmp/n1"
check "exit status" "$(run "$tmp/good.tar.gz" "$tmp/n1")" 0
check "reads the packaged floor and appends the marker" "$(cat "$tmp/n1")" '## Fixes
- one

<!-- ox-say-min-macos: 14.2 -->'
run "$tmp/three.tar.gz" "$tmp/n1" >/dev/null
check "a second run replaces the marker" "$(cat "$tmp/n1")" '## Fixes
- one

<!-- ox-say-min-macos: 15.4.1 -->'
run "$tmp/good.tar.gz" "$tmp/n-new" >/dev/null
check "a missing notes file is created" "$(tail -n 1 "$tmp/n-new")" '<!-- ox-say-min-macos: 14.2 -->'
for bad in none junk dots; do
    printf 'keep\n' >"$tmp/n-$bad"
    rc=$(run "$tmp/$bad.tar.gz" "$tmp/n-$bad")
    check "$bad: fails" "$([ "$rc" != 0 ] && echo failed)" failed
    check "$bad: an unreadable floor leaves the notes alone" "$(cat "$tmp/n-$bad")" keep
done
check "a missing package fails" "$([ "$(run "$tmp/nope.tar.gz" "$tmp/n1")" != 0 ] && echo failed)" failed

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
