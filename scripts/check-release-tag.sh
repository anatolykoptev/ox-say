#!/usr/bin/env bash
# check-release-tag.sh <tag> <sha>: refuse a release tag that is not the release commit on main.
# Run from a checkout with full history and the tag fetched; prints the tag's commit on stdout.
#   <sha>  the commit this workflow run was started for (main, which the environment admitted)
# The tag's commit must be
#   1. on <sha>'s first-parent line: the main line itself. A commit that is only an ancestor can sit on a
#      side branch merged into main, which the environment never admitted;
#   2. the release commit itself: the one whose manifest became this version. release-please adopts a tag
#      that already exists, so a tag created on an older main commit would otherwise turn old code into a
#      signed release under the new number.
# Every refusal says why on stderr. scripts/test-check-release-tag.sh covers all of it.
set -euo pipefail

tag=${1:?usage: $0 <tag> <sha>}
sha=${2:?usage: $0 <tag> <sha>}
for tool in git jq; do
    command -v "$tool" >/dev/null || { echo "check-release-tag: $tool is not installed" >&2; exit 1; }
done

commit=$(git rev-parse --verify --quiet "$tag^{commit}") || { echo "check-release-tag: tag $tag does not exist here (fetch it first)" >&2; exit 1; }
# Captured whole: `| grep -q` would SIGPIPE rev-list on a hit and, under pipefail, fail it.
mainline=$(git rev-list --first-parent "$sha") || { echo "check-release-tag: cannot list the history of $sha" >&2; exit 1; }
if ! printf '%s\n' "$mainline" | grep -Fxq -- "$commit"; then
    if git merge-base --is-ancestor "$commit" "$sha" 2>/dev/null; then
        echo "check-release-tag: $tag points at $commit, which is in the history of $sha but not on its first-parent line (a side branch merged into main)" >&2
    else
        echo "check-release-tag: $tag points at $commit, which is not on the main line of $sha" >&2
    fi
    exit 1
fi

want=${tag#v}
manifest() { # <rev>
    git show "$1:.release-please-manifest.json" 2>/dev/null | jq -r '."."' ||
        { echo "check-release-tag: no readable .release-please-manifest.json at $1" >&2; return 1; }
}
got=$(manifest "$commit")
before=$(manifest "$commit^1") || { echo "check-release-tag: $commit has no parent to compare the manifest with" >&2; exit 1; }
if [ "$got" != "$want" ] || [ "$before" = "$want" ]; then
    echo "check-release-tag: $tag points at $commit, which is not the commit that released $want (manifest $before -> $got)" >&2
    exit 1
fi
printf '%s\n' "$commit"
