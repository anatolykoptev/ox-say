#!/bin/bash
# Tests for scripts/lib-notary.sh (oxs_stapler_validate, oxs_stapler_staple) with a fake xcrun on
# PATH; backoff sleeps are zeroed. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-lib-notary.sh
#
# Mutations that must turn this RED:
#   * make the retry condition in oxs_stapler_validate match any output (retry
#     on every non-zero) — "non-transient error fails without retry" fails
#   * drop the call from sign-release.sh back to a bare `xcrun stapler
#     validate` or `xcrun stapler staple` — the "sign-release.sh uses the
#     helper" checks fail
#   * make oxs_stapler_run never retry — the staple "transient" cases fail
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-notarytest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }

# shellcheck source=scripts/lib-notary.sh
. "$root/scripts/lib-notary.sh" 2>/dev/null || { fail "scripts/lib-notary.sh is missing or does not source"; echo "$fails check(s) failed" >&2; exit 1; }

mkdir "$tmp/bin"
# Fake xcrun: counts calls in $FAKE_COUNT; call N prints line N of $FAKE_SCRIPT
# ("ok" -> exit 0; "transient" / "ticket" -> exit 68 with that kind of output;
# the last line repeats).
cat >"$tmp/bin/xcrun" <<'FAKE'
#!/bin/bash
n=$(( $(cat "$FAKE_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$FAKE_COUNT"
echo "$*" >>"$FAKE_COUNT.args"
step=$(sed -n "${n}p" "$FAKE_SCRIPT"); [ -n "$step" ] || step=$(tail -n 1 "$FAKE_SCRIPT")
case $step in
    ok) echo "The $2 action worked!"; exit 0 ;;
    transient) echo "Error Domain=NSURLErrorDomain Code=-1005 \"The network connection was lost.\"" >&2; exit 68 ;;
    timeout) echo "The request timed out." >&2; exit 68 ;;
    ticket) echo "Processing: /x.app does not have a ticket stapled to it." >&2; exit 65 ;;
esac
FAKE
chmod +x "$tmp/bin/xcrun"

# run <name> <expected rc> <expected calls> <step>...   (validate)
# runs <name> ... : the same for staple; both record the actions xcrun saw.
run() { fn=oxs_stapler_validate; action=validate; _run "$@"; }
runs() { fn=oxs_stapler_staple; action=staple; _run "$@"; }
_run() {
    local name=$1 want_rc=$2 want_calls=$3 rc
    shift 3
    printf '%s\n' "$@" >"$tmp/script"
    rm -f "$tmp/count" "$tmp/count.args"
    FAKE_SCRIPT=$tmp/script FAKE_COUNT=$tmp/count PATH="$tmp/bin:$PATH" OXS_RETRY_DELAYS="0 0 0" \
        "$fn" /x.app >"$tmp/out" 2>"$tmp/err"
    rc=$?
    if [ "$rc" != 0 ]; then rc=nonzero; fi
    if [ "$want_rc" != 0 ]; then want_rc=nonzero; fi
    check "$name: exit" "$rc" "$want_rc"
    check "$name: xcrun calls" "$(cat "$tmp/count")" "$want_calls"
    check "$name: every call is 'stapler $action /x.app'" "$(sort -u "$tmp/count.args")" "stapler $action /x.app"
}

run "success first try" 0 1 ok
run "transient twice then success" 0 3 transient transient ok
n=$(grep -c retry "$tmp/err" || true)
check "retries are announced on stderr" "$n" 2
run "timeout then success" 0 2 timeout ok
run "transient 4x fails" 1 4 transient
run "non-transient error fails without retry" 1 1 ticket ok

runs "staple: success first try" 0 1 ok
runs "staple: transient twice then success" 0 3 transient transient ok
n=$(grep -c "stapler staple: transient" "$tmp/err" || true)
check "staple: retries are announced on stderr" "$n" 2
runs "staple: persistent transient fails after 4 attempts" 1 4 transient
runs "staple: non-transient error fails without retry" 1 1 ticket ok
cat "$tmp/err" | grep -q "does not have a ticket" && pass "staple: the tool's message reaches stderr" || fail "staple: the tool's message was swallowed"

# oxs_versions_match <a> <b>: equal and non-empty. Two apps whose Info.plist lack
# CFBundleShortVersionString both read as "", which must not pass as a match.
vm() { local rc=0; oxs_versions_match "$2" "$3" >/dev/null 2>&1 || rc=$?; [ "$rc" = 0 ] || rc=1; check "versions: $1" "$rc" "$4"; }
vm "equal" "0.1.29" "0.1.29" 0
vm "different" "0.1.29" "0.1.28" 1
vm "both empty" "" "" 1
vm "one empty" "0.1.29" "" 1
vm "other empty" "" "0.1.29" 1
n=$(grep -c 'oxs_versions_match' "$root/scripts/sign-release.sh" || true)
check "sign-release.sh compares versions through the helper" "${n:-x}" 1

for pat in 'oxs_stapler_staple "[$]app"' 'oxs_stapler_validate "[$]app"' 'oxs_stapler_validate "[$]checked"'; do
    n=$(grep -cE "^$pat" "$root/scripts/sign-release.sh" || true)
    check "sign-release.sh uses the helper: $pat" "${n:-x}" 1
done
n=$(grep -cE '^xcrun stapler (validate|staple)' "$root/scripts/sign-release.sh" || true)
check "sign-release.sh has no bare stapler call" "${n:-x}" 0

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
