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

if grep -q 'glossary.json' "$root/scripts/uninstall.sh"; then pass "uninstall.sh names glossary.json in its help text"; else fail "uninstall.sh does not mention glossary.json"; fi

[ "$fails" = 0 ] || { printf '%s failed\n' "$fails"; exit 1; }
printf 'all ok\n'
