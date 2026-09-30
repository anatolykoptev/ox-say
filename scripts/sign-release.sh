#!/usr/bin/env bash
# Sign the dictation app in a release package with a Developer ID, notarize it
# with Apple, staple the ticket, and repack the package in place:
#   scripts/sign-release.sh <dist-dir>     (holds ox-say-macos-x86_64.tar.gz + SHA256SUMS)
#
# With a Developer ID signature macOS keeps the app's microphone and
# Accessibility permissions across updates (the grant follows the team, not the
# exact binary), and a notarized app opens without a Gatekeeper warning even
# when it was downloaded through a browser.
#
# Settings:
#   SIGN_IDENTITY       "Developer ID Application: <name> (<team>)", required
#   SIGN_KEYCHAIN       keychain holding it (CI imports it into a temporary one)
#   NOTARY_PROFILE      a `xcrun notarytool store-credentials` profile, or
#   APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID   the same credentials directly
set -euo pipefail

dist=${1:?usage: $0 <dist-dir>}
dist=$(cd "$dist" && pwd -P)
asset=ox-say-macos-x86_64.tar.gz
identity=${SIGN_IDENTITY:?set SIGN_IDENTITY to the Developer ID Application identity}
team=${identity##*(}
team=${team%)}
case "$identity" in
    "Developer ID Application: "*"($team)") ;;
    *) echo "SIGN_IDENTITY must be a \"Developer ID Application: … (TEAMID)\" identity" >&2; exit 1 ;;
esac

if [ -n "${NOTARY_PROFILE:-}" ]; then
    notary=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    notary=(--apple-id "$APPLE_ID" --team-id "${APPLE_TEAM_ID:-$team}" --password "$APPLE_APP_PASSWORD")
else
    echo "set NOTARY_PROFILE, or APPLE_ID and APPLE_APP_PASSWORD" >&2
    exit 1
fi
keychain=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then
    keychain=(--keychain "$SIGN_KEYCHAIN")
fi

(cd "$dist" && shasum -a 256 -c SHA256SUMS)
work=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-sign.XXXXXX")
cleanup() {
    # only what this script made, and only under its own temp dir
    case "$work" in
        "${TMPDIR:-/tmp}"/ox-say-sign.*) rm -r "$work" ;;
    esac
}
trap cleanup EXIT
tar -xzf "$dist/$asset" -C "$work"
app=$work/ox-say/app/OxSayDictation.app
if [ ! -d "$app" ]; then
    echo "the package has no app/OxSayDictation.app" >&2
    exit 1
fi

# Re-sign with the entitlements the build gave it (the microphone under the
# hardened runtime), read back from its current signature.
codesign -d --entitlements - --xml "$app" > "$work/entitlements.plist" 2>/dev/null
if ! grep -F 'com.apple.security.device.audio-input' "$work/entitlements.plist" >/dev/null; then
    echo "the app's signature carries no audio-input entitlement; refusing to sign it without" >&2
    exit 1
fi
codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" \
    --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app" # empty-array safe under bash 3.2 set -u
codesign --verify --strict "$app"
signed_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$signed_team" != "$team" ]; then
    echo "signed by team '$signed_team', expected '$team'" >&2
    exit 1
fi

# Notarize: Apple scans the app and records it; `--wait` returns once it has a
# verdict, and anything but Accepted fails with Apple's log.
ditto -c -k --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --output-format json > "$work/notary.json"
status=$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)
if [ "$status" != Accepted ]; then
    id=$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)
    echo "notarization: ${status:-no verdict} (submission ${id:-unknown})" >&2
    if [ -n "$id" ]; then
        xcrun notarytool log "$id" "${notary[@]}" >&2 || true
    fi
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app" 2> "$work/spctl.txt" || { cat "$work/spctl.txt" >&2; exit 1; }
if ! grep -F 'source=Notarized Developer ID' "$work/spctl.txt" >/dev/null; then
    cat "$work/spctl.txt" >&2
    echo "Gatekeeper does not see a notarized Developer ID app" >&2
    exit 1
fi

# Repack in place, with a new checksum.
COPYFILE_DISABLE=1 tar -C "$work" -czf "$dist/$asset.new" ox-say
mv "$dist/$asset.new" "$dist/$asset"
(cd "$dist" && shasum -a 256 "$asset" > SHA256SUMS)
echo "signed and notarized: $(cat "$dist/SHA256SUMS")"
