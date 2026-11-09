#!/usr/bin/env bash
# Resolve a Swift package's dependencies, retrying a transient download failure.
#
#   scripts/swiftpm-resolve.sh <package-path> [swift package resolve flags]
#
# CI and the release build fetch FluidAudio and its binary targets from
# third-party GitHub release URLs inside `swift test`/`swift build`; one hiccup
# on someone else's server failed a PR gate and a package build on 2026-11-09
# (PR #505, NemoTextProcessing.xcframework.zip). Resolving first, with a bounded
# retry, keeps a single transient failure from failing the job; the downloads
# land in the shared SwiftPM cache ~/Library/Caches/org.swift.swiftpm, which the
# workflows cache across runs, so the builds after this step need no network.
#
# Three attempts, 10 s then 30 s between them. A real failure — a moved pin, a
# checksum mismatch, a missing version — still fails the third time and exits
# non-zero. The flags are the caller's: pass --force-resolved-versions where the
# build uses it.
set -euo pipefail

pkg=${1:?usage: $0 <package-path> [swift package resolve flags]}
shift

attempts=3
attempt=1
delay=10
while :; do
    if swift package resolve --package-path "$pkg" ${@+"$@"}; then
        exit 0
    fi
    if [ "$attempt" -ge "$attempts" ]; then
        echo "swiftpm-resolve.sh: 'swift package resolve --package-path $pkg' failed $attempts times" >&2
        exit 1
    fi
    echo "swiftpm-resolve.sh: resolve of $pkg failed (attempt $attempt of $attempts); retrying in ${delay}s" >&2
    sleep "$delay"
    delay=30
    attempt=$((attempt + 1))
done
