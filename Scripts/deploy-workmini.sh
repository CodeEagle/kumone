#!/bin/bash
# Deploy Kumone to the work machine (workmini).
#
# Address mirrors the `workmini` ssh alias in ~/.config/nix-darwin/flake.nix.
# Usage: Scripts/deploy-workmini.sh [debug|release] [--dry-run]
#        (no argument defaults to release, per deploy.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# workmini — the remote work machine.
export KUMONE_DEPLOY_HOST="df-38bf-70a7-8777-6307-0.d.heiyu.space"
export KUMONE_DEPLOY_USER="lincoln"
# Ship the app under the user-facing name Miumiu: the executable, bundle id and
# install path stay Kumone (login data and the deploy scripts' process checks
# keep working); only Launchpad/Dock read CFBundleDisplayName.
export DISPLAY_NAME="Miumiu"
# Ship as /Applications/miumiu.app with a miumiu executable: the bundle id
# stays fun.selfstudio.mumu so login data carries over, and the install path
# is where the app now lives.
export APP_NAME="miumiu"
export KUMONE_DEPLOY_APP_PATH="/Applications/miumiu.app"

exec "$SCRIPT_DIR/deploy.sh" "$@"
