#!/bin/bash
# The entitlements the dictation app may carry, and the check that an app
# carries exactly these. Sourced by sign-release.sh and test-entitlements.sh;
# compatible with /bin/bash 3.2 and macOS's plutil.

# audio-input for the microphone, apple-events to pause Music and Spotify.
# The signature vouches for exactly these: anything more is refused, not signed.
OXS_ENTITLEMENT_KEYS="com.apple.security.automation.apple-events com.apple.security.device.audio-input"

# oxs_entitlements_json: the expected entitlements as JSON, every key true.
oxs_entitlements_json() {
    local key out=
    for key in $OXS_ENTITLEMENT_KEYS; do
        out="$out${out:+,}\"$key\":true"
    done
    printf '{%s}' "$out"
}

# oxs_entitlements_check <plist>: succeeds when the plist holds exactly the
# keys above, each a boolean true — whatever order the plist lists them in
# (plutil -convert json does not promise one). Says what differs on stderr.
oxs_entitlements_check() {
    local plist=$1 key path listed ok=0
    for key in $OXS_ENTITLEMENT_KEYS; do
        path=${key//./\\.} # plutil reads an unescaped dot as a nested key
        if [ "$(plutil -type "$path" "$plist" 2>/dev/null)" != bool ] ||
            [ "$(plutil -extract "$path" raw -o - "$plist" 2>/dev/null)" != true ]; then
            echo "entitlement missing or not true: $key" >&2
            ok=1
        fi
    done
    # the top-level keys, as plutil -p prints them (two-space indent)
    listed=$(plutil -p "$plist" 2>/dev/null | sed -n 's/^  "\(.*\)" => .*/\1/p') || true
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        case " $OXS_ENTITLEMENT_KEYS " in
            *" $key "*) ;;
            *) echo "entitlement not allowed: $key" >&2; ok=1 ;;
        esac
    done <<EOF
$listed
EOF
    return $ok
}
