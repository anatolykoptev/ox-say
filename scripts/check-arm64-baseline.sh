#!/usr/bin/env bash
# check-arm64-baseline.sh <binary>: exit 1 if an arm64 Mach-O binary uses
# instructions an Apple M1 lacks — i8mm (smmla/ummla/usmmla/usdot/sudot), BF16
# (bfdot/bfmmla/bfmlalb/bfmlalt/bfcvt), SME (smstart/smstop) or SVE
# z-registers. Distribution builds run on every Apple Silicon Mac, and one
# such instruction is a SIGILL on an M1. A native build on a newer chip
# emits them: the M5 Pro's ggml carries ~280 smmla per engine. An otool
# failure fails the check (closed), so a non-arm64 input is a failure.
set -euo pipefail

bin=${1:?usage: $0 <binary>}
case $(file -b "$bin") in
    "Mach-O 64-bit executable arm64"*) : ;;
    *) echo "$bin is not an arm64 Mach-O executable — cannot verify its baseline" >&2
       exit 1 ;;
esac
disasm=$(mktemp "${TMPDIR:-/tmp}/ox-say-disasm.XXXXXX")
trap 'rm -f "$disasm"' EXIT
otool -tv "$bin" >"$disasm"
# otool prints a bare mnemonic at the end of the line ("\tsmmla"), so a
# mnemonic ends at whitespace or at the end of the line.
pat='[[:space:]](smmla|ummla|usmmla|usdot|sudot|bfdot|bfmmla|bfmlal[bt]|bfcvtn?2?|smstart|smstop)([[:space:]]|$)|[[:space:]]z[0-9]+\.[bhsdq]'
# grep -c reads everything: `| grep -q` exits early, SIGPIPEs the writer and,
# under pipefail, could turn a match into a pass.
bad=$(grep -cE "$pat" "$disasm" || true)
# Anything but a clean 0 fails: a grep error leaves $bad empty.
if [ "${bad:-x}" != 0 ]; then
    echo "$bin uses instructions an Apple M1 lacks (${bad:-scan failed}); distribution builds must not" >&2
    grep -nE -m5 "$pat" "$disasm" >&2 || true
    exit 1
fi
