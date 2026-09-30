#!/usr/bin/env bash
# Sign the dictation app with a Developer ID, notarize it with Apple, staple the
# ticket, and put it into a release package in place of the unsigned one:
#   scripts/sign-release.sh <dist-dir> <OxSayDictation.app>
# <dist-dir> holds ox-say-macos-x86_64.tar.gz + SHA256SUMS; the app is one built
# from this checkout by app/dictation/build.sh, not the one in the package, so
# the key vouches only for first-party code built next to it.
#
# With a Developer ID signature macOS keeps the app's microphone and
# Accessibility permissions across updates (the grant follows the team, not the
# exact binary), and a notarized app opens without a Gatekeeper warning.
#
# Settings:
#   SIGN_IDENTITY       "Developer ID Application: <name> (<team>)", required
#   SIGN_KEYCHAIN       keychain holding it (CI imports it into a temporary one)
# and one of, for notarization:
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (.p8 path)
#   NOTARY_PROFILE      a `xcrun notarytool store-credentials` profile
#   APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID
set -euo pipefail

dist=${1:?usage: $0 <dist-dir> <OxSayDictation.app>}
src_app=${2:?usage: $0 <dist-dir> <OxSayDictation.app>}
dist=$(cd "$dist" && pwd -P)
asset=ox-say-macos-x86_64.tar.gz
bundle_id=io.github.anatolykoptev.ox-say.dictation
identity=${SIGN_IDENTITY:?set SIGN_IDENTITY to the Developer ID Application identity}
team=${identity##*(}
team=${team%)}
case "$identity" in
    "Developer ID Application: "*"($team)") [ -n "$team" ] || { echo "SIGN_IDENTITY has an empty team ID" >&2; exit 1; } ;;
    *) echo "SIGN_IDENTITY must be a \"Developer ID Application: … (TEAMID)\" identity" >&2; exit 1 ;;
esac

if [ -n "${NOTARY_KEY:-}" ]; then
    notary=(--key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER:?}")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    notary=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    notary=(--apple-id "$APPLE_ID" --team-id "${APPLE_TEAM_ID:-$team}" --password "$APPLE_APP_PASSWORD")
else
    echo "set NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER, NOTARY_PROFILE, or APPLE_ID and APPLE_APP_PASSWORD" >&2
    exit 1
fi
keychain=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then
    keychain=(--keychain "$SIGN_KEYCHAIN")
fi

# The one shape of bundle build.sh makes (plus the stapled ticket), and the only
# entitlement it may carry. The signature vouches for exactly this: anything
# more is refused, not signed.
bundle_files='Contents
Contents/CodeResources
Contents/Info.plist
Contents/MacOS
Contents/MacOS/OxSayDictation
Contents/PkgInfo
Contents/_CodeSignature
Contents/_CodeSignature/CodeResources'
entitlements_json='{"com.apple.security.device.audio-input":true}'

# check_bundle <app>: a real directory holding only those files, no symlinks,
# with our identifier and executable.
check_bundle() {
    local a=$1 extra
    if [ -L "$a" ] || [ ! -d "$a" ]; then
        echo "$a is not a bundle directory" >&2
        return 1
    fi
    extra=$(cd "$a" && find . -mindepth 1 | sed 's|^\./||' | sort | comm -23 - <(printf '%s\n' "$bundle_files" | sort))
    if [ -n "$extra" ]; then
        echo "$a holds files build.sh does not create: $extra" >&2
        return 1
    fi
    if [ -n "$(cd "$a" && find . -mindepth 1 -type l)" ]; then
        echo "$a contains symlinks" >&2
        return 1
    fi
    if [ "$(plutil -extract CFBundleIdentifier raw -o - "$a/Contents/Info.plist")" != "$bundle_id" ] ||
        [ "$(plutil -extract CFBundleExecutable raw -o - "$a/Contents/Info.plist")" != OxSayDictation ]; then
        echo "$a is not OxSay Dictation" >&2
        return 1
    fi
}

(cd "$dist" && shasum -a 256 -c SHA256SUMS)
work=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-sign.XXXXXX")
cleanup() {
    # only what this script made, and only under its own temp dir
    case "$work" in
        "${TMPDIR:-/tmp}"/ox-say-sign.*) rm -r "$work" ;;
    esac
}
trap cleanup EXIT
cp "$dist/$asset" "$work/unsigned.tar.gz"
tar -xzf "$dist/$asset" -C "$work"
if [ ! -d "$work/ox-say/app/OxSayDictation.app" ]; then
    echo "the package has no app/OxSayDictation.app" >&2
    exit 1
fi

# The app to sign: the one built here, checked before the key touches it.
check_bundle "$src_app"
rm -r "$work/ox-say/app/OxSayDictation.app"
ditto "$src_app" "$work/ox-say/app/OxSayDictation.app"
app=$work/ox-say/app/OxSayDictation.app

codesign -d --entitlements - --xml "$app" > "$work/built.plist" 2>/dev/null
if [ "$(plutil -convert json -o - "$work/built.plist")" != "$entitlements_json" ]; then
    echo "the app's entitlements differ from the one it may carry ($entitlements_json):" >&2
    plutil -convert json -o - "$work/built.plist" >&2 || true
    exit 1
fi
printf '%s' "$entitlements_json" > "$work/entitlements.json"
plutil -convert xml1 -o "$work/entitlements.plist" "$work/entitlements.json"
codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" \
    --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$app" # empty-array safe under bash 3.2 set -u
codesign --verify --strict "$app"
signed_team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [ "$signed_team" != "$team" ]; then
    echo "signed by team '$signed_team', expected '$team'" >&2
    exit 1
fi

# Notarize: Apple scans the app and records it. The verdict decides, not
# notarytool's exit code, so an Invalid verdict still reaches the log fetch;
# --timeout keeps a stuck queue from eating the job.
ditto -c -k --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" "${notary[@]}" --wait --timeout 40m \
    --output-format json > "$work/notary.json" || true
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

# Repack, then check the archive users will download, not the tree it came
# from: the app signed, stapled, ours and of the expected shape, and nothing
# but the app changed.
COPYFILE_DISABLE=1 tar -C "$work" -czf "$work/signed.tar.gz" ox-say
mkdir "$work/check"
tar -xzf "$work/signed.tar.gz" -C "$work/check"
checked=$work/check/ox-say/app/OxSayDictation.app
check_bundle "$checked"
codesign --verify --strict "$checked"
xcrun stapler validate "$checked"
tar -tzf "$work/unsigned.tar.gz" | grep -v '^ox-say/app/' | sort > "$work/files.unsigned"
tar -tzf "$work/signed.tar.gz" | grep -v '^ox-say/app/' | sort > "$work/files.signed"
if ! cmp -s "$work/files.unsigned" "$work/files.signed"; then
    echo "repacking changed files outside the app:" >&2
    diff "$work/files.unsigned" "$work/files.signed" >&2 || true
    exit 1
fi
mv "$work/signed.tar.gz" "$dist/$asset"
(cd "$dist" && shasum -a 256 "$asset" > SHA256SUMS)
echo "signed and notarized: $(cat "$dist/SHA256SUMS")"
