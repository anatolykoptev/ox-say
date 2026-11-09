#!/usr/bin/env bash
# Release gate: install the NEW package over the real, published PREVIOUS release.
#
# Usage: scripts/test-upgrade-from-release.sh <new-package.tar.gz> [previous-tag]
#
# Why: 0.1.29 installed the FluidAudio licences 0400 (the packages carried them read-only, from a SwiftPM
# checkout) and 0.1.30's installer copied licences with a plain `cp` into those files, failed AFTER it had replaced
# the engines, and left every Apple Silicon Mac on 0.1.30 engines under a 0.1.29 daemon. The installer tests used
# fake packages, so release N was never installed over a real release N-1. This does it:
#   1. download the previous published release for this machine's architecture and verify its SHA256SUMS
#      (default: the newest published release below the new package's version);
#   2. install it into a temp HOME with ITS OWN scripts/install-release.sh;
#   3. install the new package over it with the new package's own scripts/install-release.sh;
#   4. check the result on disk.
# Everything runs in a fresh temp HOME / OX_SAY_HOME / OX_SAY_BINDIR; the script refuses to run when a computed
# path is not under that root, and never reaches the real install, launchctl or the real daemon port.
#
# What is stubbed (only what cannot run headless; every file-layer step is real). The old release's installer runs
# first and cannot be edited, so every stub works from outside it: PATH shims and the installer's own env switches
# that already exist in both releases.
#   * launchctl (PATH shim): `print` says "not loaded", bootstrap/bootout succeed. The real oxs_load_agent runs and
#     moves the real rendered plist into the temp HOME; no agent is loaded.
#   * curl (PATH shim): only `.../status` is answered, with the version the installer waits for (oxs_wait_version
#     runs for real against it); every other curl call goes to the real curl.
#   * fetch-models.sh (BASH_ENV guard): the model download (about 2 GB) is skipped. The script itself is
#     installed for real and byte-compared; it just exits 0 when the installer runs it. It is a download, not a
#     file-layer step: nothing in the install reads the weights.
#   * OX_SAY_NO_SELFTEST=1 (no speech/transcription headless), OX_SAY_NO_DICTATION=1 (app bundle + relaunch),
#     OX_SAY_NO_MCP=1 (claude mcp registration). All three exist in the 0.1.29 installer too.
#   * ffmpeg (PATH shim, only when none is installed): oxs_require wants it, only the self-test uses it.
# Assertions after the upgrade: exit 0; every file the package installs is present and byte-identical to it;
# no file under the install root lacks owner write permission; no *.new leftover; the installed binary carries the
# new VERSION and the package's VERSION file is the one asked for.
#
# Env: OX_SAY_UPGRADE_REPO (default $GITHUB_REPOSITORY or anatolykoptev/ox-say), OX_SAY_UPGRADE_KEEP=1 (keep the
# temp root for inspection), OX_SAY_UPGRADE_TRIES (download attempts, default 4).
set -eu

usage() {
    echo "usage: $0 <new-package.tar.gz> [previous-tag]" >&2
    exit 2
}
[ $# -ge 1 ] && [ $# -le 2 ] || usage
pkg_arg=$1
prev_tag=${2:-}
[ -f "$pkg_arg" ] || {
    echo "upgrade-test: no such package: $pkg_arg" >&2
    exit 2
}

repo=${OX_SAY_UPGRADE_REPO:-${GITHUB_REPOSITORY:-anatolykoptev/ox-say}}
tries=${OX_SAY_UPGRADE_TRIES:-4}
case $tries in '' | *[!0-9]* | 0) tries=4 ;; esac
real_home=$HOME
case $(uname -m) in
    arm64 | x86_64) arch=$(uname -m) ;;
    *)
        echo "upgrade-test: unsupported architecture $(uname -m)" >&2
        exit 2
        ;;
esac
asset=ox-say-macos-$arch.tar.gz
for tool in curl jq shasum tar cmp plutil; do
    command -v "$tool" >/dev/null || {
        echo "upgrade-test: $tool not found" >&2
        exit 2
    }
done

# --- the temp root: everything the installers write lives here ---------------------------------------------------
# physical <path>: the path with every symlink resolved, also for a path that does not exist yet (its nearest
# existing ancestor is resolved, the rest appended). Lexical checks are not enough: a TMPDIR or parent of the temp
# root that is a symlink into the real install would put the whole test, and its cleanup, inside it.
physical() {
    local p=$1 rest=
    while [ ! -d "$p" ]; do
        rest=/${p##*/}$rest
        p=${p%/*}
        [ -n "$p" ] || p=/
    done
    p=$(cd "$p" && pwd -P)
    [ "$p" = / ] && p=
    printf '%s%s\n' "$p" "$rest"
}
# overlap <a> <b>: succeeds when the physical paths are equal or one contains the other
overlap() {
    case $1/ in "$2"/*) return 0 ;; esac
    case $2/ in "$1"/*) return 0 ;; esac
    return 1
}
# The real install the test must never touch. OX_SAY_UPGRADE_TEST_REAL_* exist only for the guard's own test.
real_dirs=$(
    physical "${OX_SAY_UPGRADE_TEST_REAL_INSTALL:-$real_home/Library/Application Support/ox-say}"
    physical "${OX_SAY_UPGRADE_TEST_REAL_BIN:-$real_home/.local/bin}"
    physical "$real_home/Library/LaunchAgents"
    physical "$real_home/Library/Logs/ox-say"
)

root=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-upgrade-test.XXXXXX")
case $root in
    /*/ox-say-upgrade-test.?*) ;;
    *)
        echo "upgrade-test: unexpected temp root '$root'" >&2
        exit 2
        ;;
esac
root=$(cd "$root" && pwd -P) # the physical root, from here on
th=$root/home                # the HOME the installers see
home=$th/ox-say
bindir=$th/bin
stubs=$root/stubs

# Refuse unless every path an installer will write is physically under $root, and none overlaps the real install.
guard() {
    local p pp r
    for p in "$th" "$home" "$bindir" "$th/Library/LaunchAgents" "$th/Library/Logs/ox-say"; do
        pp=$(physical "$p")
        case $pp in
            "$root"/*) ;;
            *)
                echo "upgrade-test: refusing, $p resolves to $pp, not under the temp root $root" >&2
                return 1
                ;;
        esac
    done
    for p in "$root" "$th" "$home" "$bindir"; do
        pp=$(physical "$p")
        while IFS= read -r r; do
            if overlap "$pp" "$r"; then
                echo "upgrade-test: refusing, $pp overlaps the real install path $r" >&2
                return 1
            fi
        done <<EOF
$real_dirs
EOF
    done
}
if ! guard; then
    rmdir "$root" 2>/dev/null || true # empty: nothing was written yet
    exit 2
fi
cleanup() {
    if [ "${OX_SAY_UPGRADE_KEEP:-0}" = 1 ]; then
        echo "upgrade-test: kept $root"
        return
    fi
    # earlier installs leave read-only files and directories (the bug under test): make them deletable first
    chmod -R u+rwX "${root:?}" 2>/dev/null || true
    rm -rf "${root:?}"
}
trap cleanup EXIT
trap 'exit 143' TERM HUP PIPE
trap 'exit 130' INT
mkdir -p "$th" "$stubs" "$root/dl" "$root/old" "$root/new"

# --- download with bounded retries -------------------------------------------------------------------------------
# fetch <url> <dest> [curl args]: up to $tries attempts, backoff 5 s * attempt; fails loudly after the last.
fetch() {
    local url=$1 dest=$2 n=1
    shift 2
    while :; do
        if curl -fsSL --connect-timeout 15 --max-time 600 "$@" -o "$dest" "$url"; then
            return 0
        fi
        if [ "$n" -ge "$tries" ]; then
            echo "upgrade-test: FAILED to download $url after $n attempts" >&2
            return 1
        fi
        echo "upgrade-test: download of $url failed (attempt $n/$tries); retrying in $((n * 5)) s" >&2
        sleep $((n * 5))
        n=$((n + 1))
    done
}
api_auth=()
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    api_auth=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
fi

# --- the new package ----------------------------------------------------------------------------------------------
tar -xzf "$pkg_arg" -C "$root/new"
new=$root/new/ox-say
[ -f "$new/VERSION" ] && [ -x "$new/scripts/install-release.sh" ] || {
    echo "upgrade-test: $pkg_arg is not an ox-say package (no VERSION or scripts/install-release.sh)" >&2
    exit 2
}
new_version=$(cat "$new/VERSION")

# --- the previous release -----------------------------------------------------------------------------------------
if [ -z "$prev_tag" ]; then
    fetch "https://api.github.com/repos/$repo/releases?per_page=100" "$root/dl/releases.json" \
        -H 'Accept: application/vnd.github+json' ${api_auth[@]+"${api_auth[@]}"} || exit 1
    # published, non-prerelease tags that sort strictly below the new version (a dev build sorts above all of them)
    tags=$(jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' "$root/dl/releases.json")
    prev_tag=
    for t in $(printf '%s\n' "$tags" | sed 's/^v//' | sort -t. -k1,1nr -k2,2nr -k3,3nr); do
        case $new_version in
            v[0-9]*.[0-9]*.[0-9]*)
                nv=${new_version#v}
                [ "$t" = "$nv" ] && continue
                top=$(printf '%s\n%s\n' "$t" "$nv" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
                [ "$top" = "$nv" ] || continue
                ;;
        esac
        prev_tag=v$t
        break
    done
    if [ -z "$prev_tag" ]; then
        echo "upgrade-test: no published release below $new_version in $repo; not skipping silently" >&2
        exit 1
    fi
fi
echo "upgrade-test: $prev_tag -> $new_version ($arch)"

base="https://github.com/$repo/releases/download/$prev_tag"
fetch "$base/$asset" "$root/dl/$asset" || exit 1
fetch "$base/SHA256SUMS" "$root/dl/SHA256SUMS" || exit 1
want=$(awk -v a="$asset" '$2 == a || $2 == "*" a { print $1 }' "$root/dl/SHA256SUMS")
got=$(shasum -a 256 "$root/dl/$asset" | awk '{print $1}')
if [ -z "$want" ] || [ "$want" != "$got" ]; then
    echo "upgrade-test: checksum of $prev_tag $asset does not match SHA256SUMS (want '${want:-none}', got $got)" >&2
    exit 1
fi
echo "upgrade-test: $prev_tag $asset verified ($got)"
tar -xzf "$root/dl/$asset" -C "$root/old"
old=$root/old/ox-say
[ -x "$old/scripts/install-release.sh" ] || {
    echo "upgrade-test: $prev_tag has no scripts/install-release.sh" >&2
    exit 1
}
old_version=$(cat "$old/VERSION")

# --- stubs --------------------------------------------------------------------------------------------------------
cat >"$stubs/launchctl" <<'EOF'
#!/bin/bash
# nothing is ever loaded: `print` reports "no such job", the rest succeeds
[ "${1:-}" = print ] && exit 113
exit 0
EOF
cat >"$stubs/curl" <<'EOF'
#!/bin/bash
# answer the installer's version wait; everything else is the real curl
for a in "$@"; do
    case $a in
        http://*/status)
            printf '{"version":"%s"}\n' "$(cat "$OXS_UT_VERSION_FILE")"
            exit 0
            ;;
    esac
done
exec "$OXS_UT_REAL_CURL" "$@"
EOF
if ! command -v ffmpeg >/dev/null; then
    printf '#!/bin/bash\nexit 0\n' >"$stubs/ffmpeg"
fi
chmod +x "$stubs"/*
# Sourced by every non-interactive bash the installer starts: only the model download is cut short.
cat >"$stubs/bash-env.sh" <<'EOF'
case ${0:-} in
    */scripts/fetch-models.sh)
        echo "upgrade-test: model download skipped"
        exit 0
        ;;
esac
EOF
real_curl=$(command -v curl)
version_file=$root/stub-version

# run_installer <label> <release dir> <expected version>: the release's own installer, clean environment.
run_installer() {
    local name=$1 rel=$2 version=$3 rc=0
    guard || exit 2
    printf '%s\n' "$version" >"$version_file"
    echo "upgrade-test: running $name installer ($rel/scripts/install-release.sh)"
    env -i PATH="$stubs:$PATH" HOME="$th" TMPDIR="$root" \
        OX_SAY_HOME="$home" OX_SAY_BINDIR="$bindir" OX_SAY_ADDR=127.0.0.1:18094 \
        OX_SAY_NO_SELFTEST=1 OX_SAY_NO_DICTATION=1 OX_SAY_NO_MCP=1 \
        BASH_ENV="$stubs/bash-env.sh" OXS_UT_VERSION_FILE="$version_file" OXS_UT_REAL_CURL="$real_curl" \
        "$rel/scripts/install-release.sh" >"$root/$name.log" 2>&1 || rc=$?
    return "$rc"
}

# --- phase 1: the previous release over nothing -------------------------------------------------------------------
if ! run_installer old "$old" "$old_version"; then
    echo "upgrade-test: FAIL: the previous release $prev_tag could not be installed (a broken baseline, not the upgrade):" >&2
    tail -n 25 "$root/old.log" >&2
    exit 1
fi
ro=$(cd "$th" && find . ! -perm -u+w | wc -l | tr -d ' ')
echo "upgrade-test: $prev_tag installed; $ro files without owner write (the state that broke 0.1.29 -> 0.1.30)"

# --- phase 2: the new package over it -----------------------------------------------------------------------------
rc=0
run_installer new "$new" "$new_version" || rc=$?
if [ "$rc" -ne 0 ]; then
    echo "upgrade-test: FAIL: installing $new_version over $prev_tag exited $rc:" >&2
    tail -n 25 "$root/new.log" >&2
    echo "upgrade-test: FAIL $prev_tag -> $new_version ($arch): the installer failed" >&2
    exit 1
fi

# --- assertions ---------------------------------------------------------------------------------------------------
fails=0
bad() {
    echo "upgrade-test: FAIL: $1" >&2
    fails=$((fails + 1))
}
# same_file <package file> <installed file>
same_file() {
    if [ ! -f "$2" ]; then
        bad "missing: ${2#"$th"/} (from ${1#"$new"/})"
    elif ! cmp -s "$1" "$2"; then
        bad "differs from the package: ${2#"$th"/}"
    fi
}
checked=0
# engines, metallibs and the engine's licences: every file of engine/ lands in $home/engine under its own name
while IFS= read -r f; do
    rel=${f#"$new/engine/"}
    same_file "$f" "$home/engine/$rel"
    checked=$((checked + 1))
done <<EOF
$(find "$new/engine" -type f | LC_ALL=C sort)
EOF
# the Go binary's licence tree: licenses/go -> engine/licenses/go
while IFS= read -r f; do
    rel=${f#"$new/licenses/go/"}
    same_file "$f" "$home/engine/licenses/go/$rel"
    checked=$((checked + 1))
done <<EOF
$(find "$new/licenses/go" -type f | LC_ALL=C sort)
EOF
same_file "$new/bin/ox-say" "$bindir/ox-say"
same_file "$new/scripts/uninstall.sh" "$home/uninstall.sh"
same_file "$new/scripts/fetch-models.sh" "$home/fetch-models.sh"
checked=$((checked + 3))
[ -x "$bindir/ox-say" ] || bad "$bindir/ox-say is not executable"
[ -x "$home/uninstall.sh" ] || bad "uninstall.sh is not executable"
for b in tts-server ox-stt ox-align ox-llm; do
    [ -x "$home/engine/$b" ] || bad "engine/$b is not executable"
done

# Stale engine files: the installer replaces what the package carries and removes only the metallibs of the known
# engines; a binary or library of the previous release that the new package no longer ships would stay and keep
# being picked up. Top-level files of engine/ must all come from the package. No exemptions: the daemon only reads
# engine/ (internal/config fallback "engine"), nothing creates files there at runtime. engine/licenses is not
# pruned by the installer by design (oxs_install_engines overwrites the files of the package and
# oxs_install_go_licenses replaces only licenses/go), so a licence file dropped from a package stays; not checked.
for f in "$home"/engine/* "$home"/engine/.[!.]*; do
    [ -f "$f" ] || [ -L "$f" ] || continue
    [ -e "$new/engine/${f##*/}" ] || bad "stale file left from $prev_tag, not in the new package: engine/${f##*/}"
done

unwritable=$(cd "$th" && find . ! -perm -u+w)
[ -z "$unwritable" ] || bad "files without owner write permission:
$unwritable"
leftovers=$(cd "$th" && find . -name '*.new')
[ -z "$leftovers" ] || bad "*.new leftovers:
$leftovers"

# There is no installed VERSION file: the version lives in the binary (-X main.version) and in the LaunchAgent wait.
[ "$new_version" = "$(cat "$new/VERSION")" ] || bad "package VERSION changed"
grep -aqF "$new_version" "$bindir/ox-say" || bad "the installed ox-say binary does not carry $new_version"
grep -qF "ox-say $new_version is running" "$root/new.log" || bad "the installer did not reach the version check for $new_version"
[ -f "$th/Library/LaunchAgents/io.github.anatolykoptev.ox-say.plist" ] || bad "no LaunchAgent plist rendered"

if [ "$fails" -ne 0 ]; then
    echo "upgrade-test: FAIL $prev_tag -> $new_version ($arch): $fails check(s) failed" >&2
    exit 1
fi
echo "upgrade-test: PASS $prev_tag -> $new_version ($arch): installer exit 0, $checked package files identical, none read-only, no .new leftovers"
