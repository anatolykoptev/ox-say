#!/usr/bin/env bash
# check-no-avx512.sh <binary>: exit 1 if a Mach-O binary's disassembly uses
# AVX-512 forms — %zmm registers, %k1-%k7 mask registers, xmm/ymm16-31 (those
# exist only under EVEX) or {1toN} embedded broadcast. Distribution builds
# must not carry one: most Intel MacBooks have no AVX-512 and a single such
# instruction is a SIGILL there. An otool failure fails the check (closed),
# so a non-Mach-O input is a failure, not a pass.
set -euo pipefail

bin=${1:?usage: $0 <binary>}
# otool exits 0 even on a non-object file (the error goes to stderr and the
# disassembly comes out empty), so confirm the input is Mach-O first —
# otherwise a corrupt or wrong binary would pass the guard.
case $(file -b "$bin") in
    "Mach-O "*) : ;;
    *) echo "$bin is not a Mach-O binary — cannot verify it is AVX-512-free" >&2
       exit 1 ;;
esac
disasm=$(mktemp "${TMPDIR:-/tmp}/ox-say-disasm.XXXXXX")
trap 'rm -f "$disasm"' EXIT
otool -tv "$bin" >"$disasm"
# grep -c reads everything: `| grep -q` exits early, SIGPIPEs the writer and,
# under pipefail, could turn a match into a pass.
pat='%zmm|%k[0-7]|%[xy]mm(1[6-9]|2[0-9]|3[01])|\{1to'
bad=$(grep -cE "$pat" "$disasm" || true)
if [ "$bad" -gt 0 ]; then
    echo "$bin uses AVX-512 forms ($bad instructions); distribution builds must not" >&2
    grep -nE -m5 "$pat" "$disasm" >&2 || true
    exit 1
fi
