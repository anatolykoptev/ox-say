#!/usr/bin/env bash
# Tests for release_check.sh with stand-ins for sysctl, lipo, swift and python3 on the PATH (no model, no Core ML).
#   bash engine/clean/test_release_check.sh
# Mutations (each makes the named check fail):
#   * release_check.sh: delete the proc_translated block -> "Rosetta is refused"
#   * release_check.sh: delete the `[ -n "$filter" ]` line -> "an empty filter is refused"
#   * release_check.sh: change `-le 0` to `-lt 0` in golden() -> "0 tests executed fails"
#   * release_check.sh: delete the lipo line -> "a binary of the other architecture is refused"
set -u
here=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ox-rc-test.XXXXXX") || exit 2
trap 'rm -rf "${tmp:?}"' EXIT
fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }

mkdir -p "$tmp/fake" "$tmp/models/mossformer2-se-48k"
printf '#!/bin/sh\necho "${FAKE_TRANSLATED:-0}"\n' > "$tmp/fake/sysctl"
printf '#!/bin/sh\necho "${FAKE_ARCH:-$(uname -m)}"\n' > "$tmp/fake/lipo"
printf '#!/bin/sh\nprintf "%%s\\n" "$FAKE_SWIFT_OUT"\n' > "$tmp/fake/swift"
printf '#!/bin/sh\nexit 0\n' > "$tmp/fake/python3"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin"
chmod +x "$tmp/fake/"* "$tmp/bin"

rc() { # extra env assignments... -> sets rc and out
    out=$(env PATH="$tmp/fake:$PATH" "$@" bash "$here/release_check.sh" "$tmp/bin" "$tmp/models" 2>&1); rc=$?
}

rc FAKE_TRANSLATED=1 FAKE_SWIFT_OUT="Executed 3 tests, with 0 failures"
case $out in *Rosetta*) [ "$rc" -ne 0 ] && pass "Rosetta is refused (exit $rc)" || fail "Rosetta: exit 0" ;; *) fail "Rosetta: no sentence: $out" ;; esac
case $out in *"=== "*) fail "Rosetta: work started before the refusal" ;; *) pass "nothing ran before the Rosetta refusal" ;; esac

rc OX_CLEAN_RELEASE_FILTER= FAKE_SWIFT_OUT="Executed 3 tests, with 0 failures"
case $out in *"filter is empty"*) [ "$rc" -ne 0 ] && pass "an empty filter is refused (exit $rc)" || fail "empty filter: exit 0" ;; *) fail "empty filter: no sentence: $out" ;; esac

rc FAKE_ARCH=notthisarch FAKE_SWIFT_OUT="Executed 3 tests, with 0 failures"
case $out in *"this Mac is"*) [ "$rc" -ne 0 ] && pass "a binary of the other architecture is refused" || fail "arch: exit 0" ;; *) fail "arch: no sentence: $out" ;; esac

rc FAKE_SWIFT_OUT="Executed 0 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds"
case $out in *"no real-model test ran"*"--- FAILED: ModelGoldenTests"*) [ "$rc" -ne 0 ] && pass "0 tests executed fails (exit $rc)" || fail "0 tests: exit 0" ;; *) fail "0 tests: not reported as a failure: $out" ;; esac

rc FAKE_SWIFT_OUT="Executed 2 tests, with 2 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds"
case $out in *"no real-model test ran"*) pass "all tests skipped fails" ;; *) fail "all skipped passed: $out" ;; esac

rc FAKE_SWIFT_OUT="Executed 3 tests, with 0 failures (0 unexpected) in 9.1 (9.1) seconds"
case $out in *"--- ok: ModelGoldenTests"*) pass "tests that ran pass the golden step" ;; *) fail "3 tests did not pass the golden step: $out" ;; esac

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed" >&2; exit 1; fi
