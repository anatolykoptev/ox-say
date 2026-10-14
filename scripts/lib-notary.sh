#!/usr/bin/env bash
# Notarization helpers for scripts/sign-release.sh. Source it.
#
# `xcrun stapler validate` asks Apple's CloudKit for the ticket, so it can fail
# on a flaky network (NSURLErrorDomain -1005, exit 68) even when the staple is
# fine. oxs_stapler_validate retries only those transient failures; any other
# failure (no ticket stapled, invalid ticket) fails at once, closed.
#
#   oxs_stapler_validate <app>
# OXS_RETRY_DELAYS: seconds slept before retry 1, 2, 3 (default "5 15 45").

# Output that means the lookup failed, not that the ticket is bad.
oxs_transient_notary_error() {
    grep -qiE 'NSURLErrorDomain|network connection was lost|timed out|inconsistent' "$1"
}

oxs_stapler_validate() {
    local app=$1 out rc=0 attempt=1 delay
    local -a delays
    # shellcheck disable=SC2206 # splitting the delay list is the point
    delays=(${OXS_RETRY_DELAYS:-5 15 45})
    out=$(mktemp "${TMPDIR:-/tmp}/stapler-validate.XXXXXX") || return 1
    while :; do
        rc=0
        xcrun stapler validate "$app" >"$out" 2>&1 || rc=$?
        cat "$out" >&2
        if [ "$rc" -eq 0 ]; then
            rm -f "$out"
            return 0
        fi
        if ! oxs_transient_notary_error "$out" || [ "$attempt" -gt "${#delays[@]}" ]; then
            rm -f "$out"
            return "$rc"
        fi
        delay=${delays[$((attempt - 1))]}
        echo "stapler validate: transient network error (attempt $attempt/$((${#delays[@]} + 1))), retry in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}
