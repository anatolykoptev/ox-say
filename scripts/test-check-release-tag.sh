#!/bin/bash
# Tests for scripts/check-release-tag.sh on throwaway git repos. Compatible with /bin/bash 3.2.
#
# Run: bash scripts/test-check-release-tag.sh
#
# Mutations that must turn this RED:
#   * check-release-tag.sh: test `git merge-base --is-ancestor` instead of first-parent membership —
#     "a release commit that is only on a side branch" passes
#   * check-release-tag.sh: drop the newest-release-commit loop — "the reverted release commit of a re-released
#     version" passes
#   * check-release-tag.sh: drop the `echo` before an `exit 1` — the "says why" checks fail
#   * workflows/release.yml: inline the checks again instead of calling the script — "both jobs call it" fails
#   * workflows/release.yml: delete the `[ "$stamped" = 0.0.0 ]` guard under "Check the package" (or its `exit 1`, or
#     the RELEASE_CREATED env line) — "a created release fails on a 0.0.0 stamp" fails
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
script=$root/scripts/check-release-tag.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-tagtest.XXXXXX")
fails=0
trap 'find "$tmp" -depth -delete 2>/dev/null || true' EXIT

pass()  { printf 'ok   %s\n' "$1"; }
fail()  { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — got [$2], want [$3]"; fi; }

command -v jq >/dev/null || { echo "jq is needed for this test" >&2; exit 1; }

repo=$tmp/repo
git init -q "$repo"
cd "$repo" || exit 1
git config user.email t@example.com
git config user.name t
git config commit.gpgsign false
manifest() { printf '{".": "%s"}\n' "$1" >.release-please-manifest.json; }
commit() { git add -A && git commit -q -m "$1" && git rev-parse HEAD; }

manifest 0.1.0;  echo a >f; A=$(commit "a")
manifest 0.1.1;  R1=$(commit "release 0.1.1")
echo b >f;       B=$(commit "work")
git checkout -q -b side
manifest 0.1.2;  R2=$(commit "release 0.1.2 on a side branch")
git checkout -q -
git merge -q --no-ff side -m "merge side" && M=$(git rev-parse HEAD)
git tag v0.1.1 "$R1"
git tag v0.1.2 "$R2"
git tag v0.1.0 "$A"
git checkout -q -b unmerged "$A"
manifest 0.1.3;  R3=$(commit "release 0.1.3 never merged")
git tag v0.1.3 "$R3"
git checkout -q - 

# run <name> <want rc> <tag> <sha> [env...]; stdout/stderr in $tmp/out, $tmp/err
run() {
    local name=$1 want=$2 rc=0
    shift 2
    "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    [ "$rc" = 0 ] || rc=1
    check "$name: exit" "$rc" "$want"
}
errhas() { if grep -qF -- "$2" "$tmp/err"; then pass "$1"; else fail "$1 — stderr: $(cat "$tmp/err")"; fi; }

run "release commit is the run's commit" 0 bash "$script" v0.1.1 "$B"
check "prints the commit" "$(cat "$tmp/out")" "$R1"
run "release commit older than the run's commit" 0 bash "$script" v0.1.1 "$M"
run "a release commit that is only on a side branch" 1 bash "$script" v0.1.2 "$M"
errhas "side-branch refusal says why" "first-parent"
run "a commit that is not an ancestor" 1 bash "$script" v0.1.3 "$M"
errhas "non-ancestor refusal says why" "not on the main line"
run "a tag on an older commit" 1 bash "$script" v0.1.1 "$A"
errhas "older-commit refusal says why" "not on the main line"
run "tag created on a non-release commit" 1 bash -c "cd '$repo' && git tag v0.1.9 '$B' && bash '$script' v0.1.9 '$M'"
errhas "wrong-commit refusal says why" "not the commit that released 0.1.9"
run "no such tag" 1 bash "$script" v9.9.9 "$M"
errhas "missing tag says why" "v9.9.9"
run "tag on the first commit (no parent)" 1 bash -c "cd '$repo' && git tag v0.1.0 '$A' -f && bash '$script' v0.1.0 '$A'"

# revert and re-release: two first-parent commits move the manifest to 0.4.0; only the newer one may be tagged
git checkout -q -b rerelease "$A"
manifest 0.4.0;  RA=$(commit "release 0.4.0")
manifest 0.1.0;  commit "revert release 0.4.0" >/dev/null
manifest 0.4.0;  RB=$(commit "release 0.4.0 again")
head=$(git rev-parse HEAD)
run "the reverted release commit of a re-released version" 1 bash -c "cd '$repo' && git tag v0.4.0 '$RA' && bash '$script' v0.4.0 '$head'"
errhas "reverted-release refusal says why" "newer commit"
run "the newest release commit of a re-released version" 0 bash -c "cd '$repo' && git tag -f v0.4.0 '$RB' >/dev/null && bash '$script' v0.4.0 '$head'"
check "re-release prints the newer commit" "$(cat "$tmp/out")" "$RB"

# no jq on PATH: a message about jq, not a bare failure
mkdir "$tmp/nojq"
for t in git grep sed cat; do ln -s "$(command -v $t)" "$tmp/nojq/$t"; done
run "jq missing" 1 env PATH="$tmp/nojq" /bin/bash "$script" v0.1.1 "$B"
errhas "missing jq says so" "jq"

# no manifest at the tag's commit
git checkout -q -b nomanifest "$A"
git rm -q .release-please-manifest.json && NM=$(commit "no manifest")
git tag v0.2.0 "$NM"
run "no manifest at the tag" 1 bash "$script" v0.2.0 "$NM"
errhas "missing manifest says so" ".release-please-manifest.json"

# both release.yml jobs use the script and none keeps its own copy of the checks
# (comment lines are not calls: the file's header comment names the script too)
n=$(grep -v '^[[:space:]]*#' "$root/.github/workflows/release.yml" | grep -c 'scripts/check-release-tag.sh' || true)
check "release.yml calls the script in both jobs" "$n" 2
n=$(grep -c 'merge-base --is-ancestor' "$root/.github/workflows/release.yml" || true)
check "release.yml has no inline ancestor test" "$n" 0

# a created release is never published stamped 0.0.0 (#384.5): the package check reads the stamp back from the app's
# Info.plist, and fails the job on 0.0.0 when the release was created
wf=$root/.github/workflows/release.yml
guard=$(grep -v '^[[:space:]]*#' "$wf" | grep -c '"\$RELEASE_CREATED" = true \] && \[ "\$stamped" = 0\.0\.0 \]' || true)
check "a created release fails on a 0.0.0 stamp (the guard)" "$guard" 1
n=$(grep -c 'RELEASE_CREATED: \${{ needs.release-please.outputs.release_created }}' "$wf" || true)
check "the package check is told whether a release was created" "$n" 1
n=$(grep -c 'stamped=$(plutil -extract CFBundleShortVersionString raw -o - app/OxSayDictation.app/Contents/Info.plist)' "$wf" || true)
check "the guard reads the stamp from the built app, not from VERSION" "$n" 1
after=$(grep -A3 '"\$RELEASE_CREATED" = true' "$wf" | grep -c 'exit 1' || true)
check "the guard exits non-zero" "$after" 1

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
