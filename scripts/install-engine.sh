#!/usr/bin/env bash
# Install the built engines (engine/build.sh output) into "$OX_SAY_HOME/engine".
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib-install.sh source-path=SCRIPTDIR
. "$root/scripts/lib-install.sh"
# shellcheck disable=SC2034  # read by oxs_install_engines
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
if [ ! -x "$root/build/engine/out/tts-server" ]; then
    echo "ox-say install: no engines in $root/build/engine/out — run engine/build.sh first" >&2
    exit 1
fi
# A kill mid-staging must not strand .new copies beside the engines (#508); a no-op once the commit ran.
trap 'oxs_stage_abort_quiet' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
oxs_install_engines "$root/build/engine/out"
