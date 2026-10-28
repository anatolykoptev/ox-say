#!/bin/bash
# Tests for scripts/lib-entitlements.sh (oxs_entitlements_check) on real plists:
# the allowed keys in either order and in either plist format pass; a missing
# key, an extra key, a key that is not true and a non-dictionary fail.
# Needs macOS's plutil. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-entitlements.sh
#
# Mutations that must turn this RED:
#   * make oxs_entitlements_check return 0 before the loops — every "fails" case
#   * drop the plutil -p loop (the extra-key half) — "an extra key fails"
#   * drop the key-count block (`got=$(plutil -convert xml1 ...` and its `if`) — "an empty
#     key fails" and "a key with a newline fails" (plutil -p shows neither on one line)
#   * drop the first loop (the missing-key half) — "a missing key fails"
#   * compare `plutil -convert json` against the expected JSON string again —
#     "the same keys in another order passes" is RED only where plutil lists
#     keys in plist order (checked with a plutil shim that does); macOS 26's
#     plutil sorts them, so on such a Mac that mutant stays green.
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-entitlements.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# shellcheck source=scripts/lib-entitlements.sh
. "$root/scripts/lib-entitlements.sh" 2>/dev/null || { fail "scripts/lib-entitlements.sh is missing or does not source"; echo "$fails check(s) failed" >&2; exit 1; }

A=com.apple.security.automation.apple-events
B=com.apple.security.device.audio-input

# plist <name> <body>: an XML plist with the given <dict> body
plist() {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>%s</dict></plist>\n' "$2" >"$tmp/$1.plist"
}
k() { printf '<key>%s</key><%s/>' "$1" "${2:-true}"; }

# expect <name> <pass|fail> <plist name>
expect() {
    local rc=0
    oxs_entitlements_check "$tmp/$3.plist" >"$tmp/out" 2>&1 || rc=$?
    if [ "$2" = pass ] && [ "$rc" = 0 ]; then pass "$1"
    elif [ "$2" = fail ] && [ "$rc" != 0 ]; then pass "$1"
    else fail "$1 — exit $rc: $(cat "$tmp/out")"; fi
}

plist same "$(k $A)$(k $B)"
plist reordered "$(k $B)$(k $A)"
plist missing "$(k $A)"
plist extra "$(k $A)$(k $B)$(k com.apple.security.cs.allow-jit)"
plist notTrue "$(k $A)$(k $B false)"
plist empty ""
plist emptykey "$(k $A)$(k $B)<key></key><true/>"
plist newlinekey "$(k $A)$(k $B)<key>x&#10;y</key><true/>"
printf 'this is not a plist\n' >"$tmp/garbage.plist"
: >"$tmp/zero.plist"
printf '<?xml version="1.0"?><plist version="1.0"><array><true/></array></plist>\n' >"$tmp/array.plist"
plutil -convert binary1 -o "$tmp/binary.plist" "$tmp/reordered.plist"

expect "the allowed keys pass" pass same
expect "the same keys in another order passes" pass reordered
expect "the same keys in another order, binary plist, passes" pass binary
expect "a missing key fails" fail missing
expect "an extra key fails" fail extra
expect "a key that is false fails" fail notTrue
expect "an empty dictionary fails" fail empty
expect "a plist that is not a dictionary fails" fail array
expect "an empty key fails" fail emptykey
expect "a key with a newline fails" fail newlinekey
expect "a text file that is not a plist fails" fail garbage
expect "a zero-byte file fails" fail zero
expect "a file that does not exist fails" fail nonexistent

# The failure names the key.
oxs_entitlements_check "$tmp/extra.plist" 2>&1 | grep -q 'not allowed: com.apple.security.cs.allow-jit' &&
    pass "an extra key is named" || fail "an extra key is named"
oxs_entitlements_check "$tmp/missing.plist" 2>&1 | grep -q "missing or not true: $B" &&
    pass "a missing key is named" || fail "a missing key is named"

# What gets signed is the same JSON as before, both keys.
want='{"com.apple.security.automation.apple-events":true,"com.apple.security.device.audio-input":true}'
if [ "$(oxs_entitlements_json)" = "$want" ]; then pass "the JSON to sign is unchanged"; else fail "the JSON to sign is $(oxs_entitlements_json)"; fi
# ... and it is what the checker accepts.
printf '%s' "$(oxs_entitlements_json)" >"$tmp/signed.json"
plutil -convert xml1 -o "$tmp/signed.plist" "$tmp/signed.json"
expect "the JSON to sign passes the check" pass signed

# sign-release.sh uses the checker, not a string compare.
n=$(grep -c '^if ! oxs_entitlements_check "\$work/built.plist"' "$root/scripts/sign-release.sh" || true)
if [ "${n:-x}" = 1 ]; then pass "sign-release.sh uses the checker"; else fail "sign-release.sh uses the checker (found ${n:-x})"; fi
n=$(grep -c 'convert json.*!= "\$entitlements_json"' "$root/scripts/sign-release.sh" || true)
if [ "${n:-x}" = 0 ]; then pass "sign-release.sh has no exact-string compare"; else fail "sign-release.sh has an exact-string compare"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
