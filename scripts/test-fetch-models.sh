#!/bin/bash
# Sandbox test for scripts/fetch-models.sh --notes-only. Nothing is downloaded:
# OX_SAY_MODELS_FROM serves a local file, and the checksum is the pinned one,
# so a file of the wrong content must be refused. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-fetch-models.sh
#
# Mutations that must turn this RED:
#   * fetch-models.sh: delete the `models=("Qwen3.5-4B..."` line in the
#     notes_only block -> the script goes for the other models too -> "only the
#     notes model" fails
#   * fetch-models.sh: change the notes sha256 -> the live acceptance probe
#     (a real copy of the model) fails; this sandbox test cannot see it, because
#     it only proves a WRONG file is refused (see Task 6 in the plan)
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-fetchtest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

name=Qwen3.5-4B-Q4_K_M.gguf
mkdir -p "$tmp/from" "$tmp/dest"
echo "not the model" > "$tmp/from/$name"
out=$(OX_SAY_MODELS_FROM="$tmp/from" bash "$root/scripts/fetch-models.sh" --notes-only "$tmp/dest" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then pass "a wrong notes model is refused (exit $rc)"; else fail "a wrong notes model was accepted"; fi
case $out in *"checksum mismatch for $name"*) pass "the mismatch names the file" ;; *) fail "no mismatch message: $out" ;; esac
case $out in
    *fetch*) fail "--notes-only tried to download something: $out" ;;
    *) pass "only the notes model is looked at" ;;
esac
if [ ! -e "$tmp/dest/$name" ] && [ ! -e "$tmp/dest/$name.part" ]; then
    pass "no model and no .part left behind"
else
    fail "files left in dest: $(ls "$tmp/dest")"
fi
case $out in *"copy    $name"*) pass "the local copy path ran for the notes model" ;; *) fail "OX_SAY_MODELS_FROM was not used: $out" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
