#!/bin/bash
# Sandbox tests for scripts/lib-install.sh. Every scenario runs in a child
# bash with HOME pointed at a scratch dir: no launchctl, nothing outside the
# sandbox is touched. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-lib-install.sh
#
# Mutation that must turn this RED: restore the render loop in
# lib-install.sh that writes every OX_SAY_* variable (drop the
# oxs_daemon_var filter) — scenario A fails.
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
label=io.github.anatolykoptev.ox-say
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-libtest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }
check_in_log() { if grep -qF "$3" "$2"; then pass "$1"; else fail "$1 — missing [$3] in log"; fi; }

# The allowlist the installer hands to lib-install.sh. Prefer the real
# binary's `env-keys` output so the lib↔binary seam is exercised too; fall
# back to a fixed list when go is unavailable (the table↔loader consistency
# itself is covered by the Go tests).
if command -v go >/dev/null 2>&1; then
    (cd "$root" && go build -o "$tmp/ox-say" ./cmd/ox-say)
    bin=$tmp/ox-say
    keysfile=
else
    bin=
    keysfile=$tmp/env-keys
    printf '%s\n' OX_SAY_ADDR OX_SAY_CACHE_DIR OX_SAY_HOME OX_SAY_STT_GPU >"$keysfile"
fi

# One install scenario: read settings, render the agent, copy the result to
# $OXS_TMP/render.plist and record the post-settings environment.
cat >"$tmp/scenario-render.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export HOME=$OXS_HOME
. "$OXS_ROOT/scripts/lib-install.sh"
if [ -n "${OXS_BIN:-}" ]; then
    oxs_env_keys_from "$OXS_BIN"
else
    oxs_env_keys=$(cat "$OXS_KEYS")
fi
oxs_settings
compgen -e | grep '^OX_SAY_' >"$OXS_TMP/env-after-settings.txt" 2>/dev/null || true
t=$(oxs_render_agent "$OXS_TEMPLATE")
cp "$t" "$OXS_TMP/render.plist"
EOF

# oxs_settings must refuse to run before the env-key list is known: an empty
# allowlist would silently drop every carried-over setting.
cat >"$tmp/scenario-nokeys.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export HOME=$OXS_HOME
. "$OXS_ROOT/scripts/lib-install.sh"
oxs_settings
echo reached >"$OXS_TMP/installed"
EOF

plist_keys() {
    plutil -extract EnvironmentVariables xml1 -o - "$1" 2>/dev/null |
        sed -n 's|.*<key>\([^<]*\)</key>.*|\1|p' | LC_ALL=C sort
}
plist_val() { plutil -extract "EnvironmentVariables.$2" raw -o - "$1" 2>/dev/null || true; }

# scenario <name> <script> [env assignments…] — runs the child with a scrubbed
# environment (env -i), captures its log at $tmp/<name>.log
scenario() {
    local name=$1 script=$2
    shift 2
    env -i PATH="$PATH" OXS_ROOT="$root" OXS_TMP="$tmp" \
        OXS_BIN="$bin" OXS_KEYS="$keysfile" \
        OXS_HOME="$tmp/home-$name" OXS_TEMPLATE="$tmp/template-$name.plist" \
        "$@" bash "$tmp/$script" >"$tmp/$name.log" 2>&1
}

for s in render carry stale nokeys; do
    cp "$root/launchd/$label.plist.in" "$tmp/template-$s.plist"
done

# --- A: the render writes only variables the daemon reads -------------------
scenario render scenario-render.sh \
    OX_SAY_NO_SELFTEST=1 OX_SAY_NO_MCP=1 OX_SAY_GET_URL=x OX_SAY_ADDR=127.0.0.1:9999 \
    || fail "render scenario failed: $(tail -3 "$tmp/render.log")"
if [ -f "$tmp/render.plist" ]; then
    check "render writes only daemon vars" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
    check "OX_SAY_ADDR value" "$(plist_val "$tmp/render.plist" OX_SAY_ADDR)" "127.0.0.1:9999"
fi

# --- B: carry-over from an installed agent ----------------------------------
# Install A's plist as the existing agent, then re-run with nothing set.
mkdir -p "$tmp/home-carry/Library/LaunchAgents"
cp "$tmp/render.plist" "$tmp/home-carry/Library/LaunchAgents/$label.plist"
scenario carry scenario-render.sh \
    || fail "carry scenario failed: $(tail -3 "$tmp/carry.log")"
if [ -f "$tmp/render.plist" ]; then
    check "carry-over keeps only OX_SAY_ADDR" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
    check "carried value" "$(plist_val "$tmp/render.plist" OX_SAY_ADDR)" "127.0.0.1:9999"
fi
check_in_log "carry-over announced" "$tmp/carry.log" "keeping OX_SAY_ADDR"

# --- C: a stale installer knob in the installed plist is dropped ------------
# Seed the installed agent with OX_SAY_GET_URL (the live plist carries it —
# the denylist forgot it). It must not be exported, nor reach the next render.
mkdir -p "$tmp/home-stale/Library/LaunchAgents"
cp "$root/launchd/$label.plist.in" "$tmp/home-stale/Library/LaunchAgents/$label.plist"
plutil -replace EnvironmentVariables.OX_SAY_GET_URL -string http://stale \
    "$tmp/home-stale/Library/LaunchAgents/$label.plist"
plutil -replace EnvironmentVariables.OX_SAY_ADDR -string 127.0.0.1:9999 \
    "$tmp/home-stale/Library/LaunchAgents/$label.plist"
scenario stale scenario-render.sh \
    || fail "stale scenario failed: $(tail -3 "$tmp/stale.log")"
if [ -f "$tmp/render.plist" ]; then
    check "stale GET_URL gone from render" "$(plist_keys "$tmp/render.plist")" "OX_SAY_ADDR
PATH"
fi
if grep -qx 'OX_SAY_GET_URL' "$tmp/env-after-settings.txt" 2>/dev/null; then
    fail "OX_SAY_GET_URL exported into the environment"
else
    pass "OX_SAY_GET_URL not exported"
fi
check_in_log "drop announced" "$tmp/stale.log" "dropping OX_SAY_GET_URL"

# --- D: no env-key list -> refuse (fail closed) ------------------------------
rm -f "$tmp/installed"
scenario nokeys scenario-nokeys.sh
rc=$?
if [ $rc -ne 0 ] && [ ! -f "$tmp/installed" ]; then
    pass "oxs_settings refuses before oxs_env_keys_from"
else
    fail "nokeys: rc=$rc installed=$([ -f "$tmp/installed" ] && echo yes || echo no)"
fi
check_in_log "refusal names the fix" "$tmp/nokeys.log" "oxs_env_keys_from"

echo
if [ "$fails" -eq 0 ]; then
    echo "all checks passed"
else
    echo "$fails check(s) failed" >&2
    exit 1
fi
