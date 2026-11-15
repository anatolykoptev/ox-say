#!/bin/bash
# Sandbox test for scripts/uninstall.sh --purge: HOME is a scratch dir, no installed OxSay is touched. Compatible
# with /bin/bash 3.2.
#
# Run: bash scripts/test-uninstall-purge.sh
#
# --purge removes what ox-say creates as engine state (engine, models, voices, run) and keeps what is the user's:
# meetings, transcripts and glossary.json (#555).
#
# Mutations that must turn this RED:
#   * add glossary.json to the `rm -f "$home/uninstall.sh" ...` line in uninstall.sh — "glossary.json survives" fails
#   * drop `run` from the `for d in engine models voices run` loop — "run is purged" fails
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-uninstall.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1 — $2 is gone"; fi; }
gone()   { if [ ! -e "$2" ]; then pass "$1"; else fail "$1 — $2 is still there"; fi; }

# uninstall.sh boots the agent out with launchctl and stops the dictation app: on a Mac with OxSay installed the real
# tools would stop the live daemon. Stubs come first in PATH and the test refuses to go on unless they win.
stubs="$tmp/stubs"
mkdir -p "$stubs"
printf '#!/bin/bash\necho "launchctl $*" >> "%s/calls"\nexit 0\n' "$tmp" > "$stubs/launchctl"
for t in pkill pgrep; do printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\nexit 1\n' "$t" "$tmp" > "$stubs/$t"; done
printf '#!/bin/bash\nexit 1\n' > "$stubs/plutil"
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"
if [ "$(command -v launchctl)" != "$stubs/launchctl" ]; then
    echo "FAIL the launchctl stub is not first in PATH; refusing to run uninstall.sh" >&2
    exit 1
fi

export HOME="$tmp/home"
home="$HOME/Library/Application Support/ox-say"
mkdir -p "$home/engine" "$home/models" "$home/voices" "$home/run" "$home/meetings/m1" "$home/transcripts/t1"
printf '{"corrections":[]}\n' > "$home/glossary.json"
printf 'x\n' > "$home/meetings/m1/meta.json"
printf 'x\n' > "$home/transcripts/t1/meta.json"
printf '#!/bin/sh\n' > "$home/uninstall.sh"
printf 'x\n' > "$home/engine/e"; printf 'x\n' > "$home/models/m"; printf 'x\n' > "$home/voices/v"; printf 'x\n' > "$home/run/r"

bash "$root/scripts/uninstall.sh" --purge >"$tmp/out" 2>"$tmp/err"
rc=$?
if [ "$rc" = 0 ]; then pass "uninstall.sh --purge exits 0"; else fail "uninstall.sh --purge exits $rc: $(cat "$tmp/err")"; fi

gone   "engine is purged" "$home/engine"
gone   "models is purged" "$home/models"
gone   "voices is purged" "$home/voices"
gone   "run is purged" "$home/run"
gone   "uninstall.sh copy is purged" "$home/uninstall.sh"
exists "glossary.json survives --purge" "$home/glossary.json"
exists "meetings survives --purge" "$home/meetings/m1/meta.json"
exists "transcripts survives --purge" "$home/transcripts/t1/meta.json"

if grep -q 'launchctl bootout' "$tmp/calls" 2>/dev/null; then pass "the launchctl stub, not the real launchctl, took the bootout"; else fail "the launchctl stub was not called"; fi
if grep -q 'glossary.json kept' "$tmp/out"; then pass "the final message says glossary.json was kept"; else fail "the final message does not mention glossary.json"; fi

[ "$fails" = 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
printf 'all ok\n'
