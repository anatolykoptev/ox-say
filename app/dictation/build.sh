#!/usr/bin/env bash
# Build OxSayDictation.app, the menu-bar dictation app.
#
#   app/dictation/build.sh             build into build/dictation/
#   app/dictation/build.sh --install   build, replace ~/Applications/OxSayDictation.app, open it
#
# Signing: OX_SAY_SIGN_IDENTITY names a "Developer ID Application: …" identity in
# the keychain. Without it the app is signed ad hoc: macOS then ties its
# Accessibility permission to the exact binary and asks again after every
# rebuild or update, and Gatekeeper refuses it when it arrives through a browser
# download (a curl download, as get.sh does, carries no quarantine). With a
# Developer ID identity the permission survives updates, and with
# OX_SAY_NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) the app
# is also notarized and stapled, so it opens anywhere without a warning.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
name=OxSayDictation
bundle_id=io.github.anatolykoptev.ox-say.dictation
out=$root/build/dictation
app=$out/$name.app

install=0
case "${1:-}" in
    "") ;;
    --install) install=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
esac

# CFBundleShortVersionString must be three numbers; a dev build is 0.0.0.
version=${VERSION:-0.0.0}
version=${version#v}
if [[ $version =~ ^([0-9]+\.[0-9]+\.[0-9]+)([-+].*)?$ ]]; then
    version=${BASH_REMATCH[1]}
else
    version=0.0.0
fi

# Refuses unless $1 is absent or a bundle this script built: a real directory
# holding only the files it creates. Anything else is not ours to delete.
check_app() {
    local a=$1 entry
    [ -e "$a" ] || [ -L "$a" ] || return 0
    if [ -L "$a" ] || [ ! -d "$a" ]; then
        echo "build.sh: $a is not a directory this script created; not replacing it" >&2
        exit 1
    fi
    while IFS= read -r entry; do
        case "${entry#"$a"/}" in
            Contents | Contents/Info.plist | Contents/PkgInfo | Contents/MacOS | "Contents/MacOS/$name" | \
                Contents/_CodeSignature | Contents/_CodeSignature/CodeResources | Contents/CodeResources) ;;
            *)
                echo "build.sh: $a holds $entry, which this script does not create; not replacing it" >&2
                exit 1
                ;;
        esac
    done < <(find "$a" -mindepth 1)
}

# Removes a bundle this script built: its files by name, then its directories.
remove_app() {
    local a=$1
    check_app "$a"
    [ -e "$a" ] || return 0
    rm -f "$a/Contents/Info.plist" "$a/Contents/PkgInfo" "$a/Contents/MacOS/$name" \
        "$a/Contents/_CodeSignature/CodeResources" "$a/Contents/CodeResources"
    rmdir "$a/Contents/_CodeSignature" "$a/Contents/MacOS" "$a/Contents" "$a"
}

# Refuse a bundle that is not ours before spending a build on it.
check_app "$app"
if [ "$install" = 1 ]; then "$here/install-app.sh" --check; fi
swift build -c release --package-path "$here"
bin=$(swift build -c release --package-path "$here" --show-bin-path)

remove_app "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/$name" "$app/Contents/MacOS/$name"
printf 'APPL????' > "$app/Contents/PkgInfo"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>OxSay Dictation</string>
    <key>CFBundleDisplayName</key><string>OxSay Dictation</string>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- The daemon speaks plain http on 127.0.0.1; this allows only local hosts. -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>NSMicrophoneUsageDescription</key>
    <string>OxSay Dictation records your voice while you hold the dictation key and sends it to the ox-say daemon on this Mac, which turns it into text. Nothing leaves your Mac.</string>
</dict>
</plist>
EOF
plutil -lint "$app/Contents/Info.plist" >/dev/null

# The hardened runtime blocks the microphone unless this entitlement is present.
entitlements=$(mktemp "${TMPDIR:-/tmp}/ox-say-dictation.XXXXXX")
trap 'rm -f "$entitlements"' EXIT
cat > "$entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
EOF

identity=${OX_SAY_SIGN_IDENTITY:--}
sign_args=(--force --options runtime --entitlements "$entitlements" --sign "$identity")
[ "$identity" = - ] || sign_args+=(--timestamp)
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"

if [ "$identity" != - ] && [ -n "${OX_SAY_NOTARY_PROFILE:-}" ]; then
    zip=$out/$name.zip
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$OX_SAY_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    rm -f "$zip"
fi

if [ "$identity" = - ]; then
    echo "built $app ($version, signed ad hoc: macOS asks for Accessibility again after each rebuild)"
else
    echo "built $app ($version, signed by $identity)"
fi

if [ "$install" = 1 ]; then
    "$here/install-app.sh" "$app"
fi
