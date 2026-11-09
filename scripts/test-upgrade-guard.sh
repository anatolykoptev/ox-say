#!/usr/bin/env bash
# Test of the path guard of scripts/test-upgrade-from-release.sh: a TMPDIR that is a symlink into the (fake) real
# install must be refused, with nothing written there. The real install is never involved: the guard's
# OX_SAY_UPGRADE_TEST_REAL_INSTALL / _REAL_BIN overrides point at directories made here.
#
# Mutation that must turn this RED: in test-upgrade-from-release.sh make physical() print its argument
# unchanged (a lexical check) -- the three symlinked cases then pass the guard.
set -u

root=$(cd "$(dirname "$0")/.." && pwd -P)
t=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-guardtest.XXXXXX")
trap 'chmod -R u+rwX "${t:?}" 2>/dev/null; rm -rf "${t:?}"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 - got [$2], want [$3]"; fails=$((fails + 1)); fi; }

mkdir -p "$t/fake/install" "$t/fake/bin" "$t/safe"
mkdir "$t/empty" && : >"$t/empty/x" && tar -czf "$t/pkg.tar.gz" -C "$t/empty" x # not a package: a run that passes the guard stops at "not an ox-say package"
ln -s "$t/fake/install" "$t/link-install"
ln -s "$t/fake/bin" "$t/link-bin"
mkdir -p "$t/fake/install/sub"
ln -s "$t/fake/install/sub" "$t/link-parent"

run() { # <tmpdir> -> prints "rc|first matching message"
    local out rc=0
    out=$(env TMPDIR="$1" OX_SAY_UPGRADE_TEST_REAL_INSTALL="$t/fake/install" OX_SAY_UPGRADE_TEST_REAL_BIN="$t/fake/bin" \
        bash "$root/scripts/test-upgrade-from-release.sh" "$t/pkg.tar.gz" v0.0.0 2>&1) || rc=$?
    printf '%s|%s\n' "$rc" "$(printf '%s\n' "$out" | grep -E 'refusing|not an ox-say package' | head -n 1 | sed 's/ resolves to .*//; s/, .* overlaps.*//')"
}

check "TMPDIR symlinked to the real install is refused" "$(run "$t/link-install")" "2|upgrade-test: refusing"
check "TMPDIR symlinked into a subdir of the real install is refused" "$(run "$t/link-parent")" "2|upgrade-test: refusing"
check "TMPDIR symlinked to the real bin dir is refused" "$(run "$t/link-bin")" "2|upgrade-test: refusing"
check "nothing was written into the fake real install" "$(find "$t/fake" -type f | wc -l | tr -d ' ')|$(find "$t/fake" -mindepth 2 -type d -name 'ox-say-upgrade-test.*' | wc -l | tr -d ' ')" "0|0"
check "a TMPDIR outside it passes the guard" "$(run "$t/safe")" "2|upgrade-test: $t/pkg.tar.gz is not an ox-say package (no VERSION or scripts/install-release.sh)"

[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
