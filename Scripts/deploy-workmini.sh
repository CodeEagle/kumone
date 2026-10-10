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
# Keep bundle, executable and Dock names identical. The bundle identifier is
# unchanged so existing preferences and login data carry over.
export DISPLAY_NAME="MiuMiu"
export APP_NAME="MiuMiu"
export KUMONE_DEPLOY_APP_PATH="/Applications/MiuMiu.app"

exec "$SCRIPT_DIR/deploy.sh" "$@"
