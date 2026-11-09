#!/bin/bash
# Tests for scripts/swiftpm-resolve.sh's bounded retry, against a fake `swift` and a recording `sleep` on PATH.
# Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-swiftpm-resolve.sh
#
# Mutations that must turn this RED:
#   * swiftpm-resolve.sh: attempts=3 -> attempts=1 — "two failures then success" exits 1
#   * swiftpm-resolve.sh: drop the final `exit 1` — "always fails" exits 0
#   * swiftpm-resolve.sh: drop the sleeps (retry without waiting) — "backoff is 10 s then 30 s" fails
#   * swiftpm-resolve.sh: stop forwarding the caller's flags — "caller's flags reach swift" fails
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
script=$root/scripts/swiftpm-resolve.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-swiftpm.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }

export FAKE_STATE=$tmp/state FAKE_SLEEPS=$tmp/sleeps FAKE_ARGS=$tmp/args
fakebin=$tmp/bin
mkdir -p "$fakebin"
cat > "$fakebin/swift" <<'EOF'
#!/usr/bin/env bash
# Fails the first $FAKE_FAILS invocations (a counter in $FAKE_STATE), succeeds after.
n=$(cat "$FAKE_STATE" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$FAKE_STATE"
printf 'swift %s\n' "$*" >> "$FAKE_ARGS"
if [ "$n" -le "${FAKE_FAILS:-0}" ]; then
    echo "fake swift: error: failed downloading 'https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.1/NemoTextProcessing.xcframework.zip' which is required by binary target 'NemoTextProcessing'" >&2
    exit 1
fi
exit 0
EOF
cat > "$fakebin/sleep" <<'EOF'
#!/usr/bin/env bash
# Records the requested delay instead of waiting.
echo "$1" >> "$FAKE_SLEEPS"
EOF
chmod +x "$fakebin/swift" "$fakebin/sleep"

# run <name> <want rc> <failures-before-success> [swiftpm-resolve.sh args...]
run() {
    local name=$1 want=$2 nfails=$3 rc=0
    shift 3
    rm -f "$FAKE_STATE" "$FAKE_SLEEPS" "$FAKE_ARGS"
    FAKE_FAILS=$nfails PATH="$fakebin:/usr/bin:/bin" bash "$script" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    [ "$rc" = 0 ] || rc=1
    check "$name: exit" "$rc" "$want"
}
sleeps() { if [ -f "$FAKE_SLEEPS" ]; then cat "$FAKE_SLEEPS"; fi; }
calls() { if [ -f "$FAKE_ARGS" ]; then wc -l < "$FAKE_ARGS" | tr -d ' '; else echo 0; fi; }

run "succeeds first try" 0 0 some/pkg
check "succeeds first try: one resolve" "$(calls)" 1
check "succeeds first try: no waiting" "$(sleeps)" ""

run "one failure then success" 0 1 some/pkg
check "one failure then success: two resolves" "$(calls)" 2
check "one failure then success: waited 10 s" "$(sleeps)" "10"

run "two failures then success" 0 2 engine/diar --force-resolved-versions
check "two failures then success: three resolves" "$(calls)" 3
check "backoff is 10 s then 30 s" "$(sleeps)" "$(printf '10\n30')"

run "always fails" 1 99 some/pkg
check "always fails: exactly three attempts" "$(calls)" 3
check "always fails: waited 10 s then 30 s" "$(sleeps)" "$(printf '10\n30')"
if grep -qF 'failed 3 times' "$tmp/err"; then pass "always fails: stderr names the attempts"; else fail "always fails: stderr names the attempts — stderr: $(cat "$tmp/err")"; fi

run "caller's flags reach swift" 0 0 engine/clean --force-resolved-versions
if grep -qFx 'swift package resolve --package-path engine/clean --force-resolved-versions' "$FAKE_ARGS"; then
    pass "caller's flags reach swift"
else
    fail "caller's flags reach swift — got: $(cat "$FAKE_ARGS")"
fi

run "no package path" 1 0
if grep -qi 'usage' "$tmp/err"; then pass "no package path: stderr says usage"; else fail "no package path: stderr says usage — stderr: $(cat "$tmp/err")"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
