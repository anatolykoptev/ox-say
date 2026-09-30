#!/usr/bin/env bash
# Install the built engines (engine/build.sh output) into "$OX_SAY_HOME/engine".
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib-install.sh source-path=SCRIPTDIR
. "$root/scripts/lib-install.sh"
# shellcheck disable=SC2034  # read by oxs_install_engines
home=${OX_SAY_HOME:-"$HOME/Library/Application Support/ox-say"}
oxs_install_engines "$root/build/engine/out"
