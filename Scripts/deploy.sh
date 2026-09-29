#!/bin/bash
# Usage: Scripts/deploy.sh [debug|release] [--dry-run]
set -euo pipefail

# Default target is the remote work machine (workmini); override with
# KUMONE_DEPLOY_HOST for other hosts (e.g. localhost for the local box).
REMOTE_HOST="${KUMONE_DEPLOY_HOST:-df-38bf-70a7-8777-6307-0.d.heiyu.space}"
REMOTE_USER="${KUMONE_DEPLOY_USER:-lincoln}"
REMOTE_APP_PATH="${KUMONE_DEPLOY_APP_PATH:-/Applications/Kumone.app}"
REMOTE_STAGING="${KUMONE_DEPLOY_STAGING:-~/Downloads}"
APP_NAME="${APP_NAME:-Kumone}"
CONF=release
DRY_RUN=false
CONF_SET=false
LOCAL_TMP=
STEP=initialization

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
trap 'printf "ERROR: %s failed (line %s).\n" "$STEP" "$LINENO" >&2' ERR
trap 'if [ -n "$LOCAL_TMP" ]; then rm -rf -- "$LOCAL_TMP"; fi' EXIT

for arg in "$@"; do
  case "$arg" in
    debug|release)
      [ "$CONF_SET" = false ] || fail 'Specify only one build configuration.'
      CONF="$arg"
      CONF_SET=true
      ;;
    --dry-run) DRY_RUN=true ;;
    *) fail "Unknown argument: $arg. Usage: $0 [debug|release] [--dry-run]" ;;
  esac
done

case "$REMOTE_APP_PATH" in
  /*.app) ;;
  *) fail 'KUMONE_DEPLOY_APP_PATH must be an absolute path ending in .app.' ;;
esac
case "$REMOTE_STAGING" in
  /*|'~/'*) ;;
  *) fail 'KUMONE_DEPLOY_STAGING must be absolute or start with ~/.' ;;
esac
case "$REMOTE_USER@$REMOTE_HOST" in
  -*|*[[:space:]]*) fail 'Invalid SSH user or host.' ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REMOTE_USER@$REMOTE_HOST"
# A unique upload name prevents an interrupted transfer from reusing an old file.
UPLOAD_NAME="$APP_NAME.app.$(date +%s).$$.tar.gz"
REMOTE_UPLOAD="${REMOTE_STAGING%/}/$UPLOAD_NAME"
# scp -O uses the remote shell: quote paths while allowing only the initial ~/.
case "$REMOTE_UPLOAD" in
  '~/'*) printf -v SCP_PATH '~/%q' "${REMOTE_UPLOAD#\~/}" ;;
  *) printf -v SCP_PATH '%q' "$REMOTE_UPLOAD" ;;
esac

remote_script() {
  printf 'APP_NAME=%q\nREMOTE_APP_PATH=%q\nREMOTE_STAGING=%q\nUPLOAD_NAME=%q\n' \
    "$APP_NAME" "$REMOTE_APP_PATH" "$REMOTE_STAGING" "$UPLOAD_NAME"
  cat <<'REMOTE'
set -euo pipefail
STEP=preflight
TEMP_DIR=
BACKUP_PATH="$REMOTE_APP_PATH.bak"
remote_error() {
  printf 'ERROR: Remote %s failed.\n' "$STEP" >&2
  if [ -e "$BACKUP_PATH" ] || [ -L "$BACKUP_PATH" ]; then
    printf 'Backup remains at %s; restore it manually if needed.\n' "$BACKUP_PATH" >&2
  fi
}
trap remote_error ERR
trap 'if [ -n "$TEMP_DIR" ]; then rm -rf -- "$TEMP_DIR"; fi' EXIT
case "$REMOTE_STAGING" in
  '~/'*) REMOTE_STAGING="$HOME/${REMOTE_STAGING#\~/}" ;;
esac
ARCHIVE="${REMOTE_STAGING%/}/$UPLOAD_NAME"
test -s "$ARCHIVE"
APP_PARENT="$(dirname "$REMOTE_APP_PATH")"
test -d "$APP_PARENT"
test -w "$APP_PARENT"
TEMP_DIR="$(mktemp -d "$APP_PARENT/.Kumone-deploy.XXXXXX")"

STEP='application shutdown'
# Only the app being replaced is touched: the path-keyed and name-keyed
# patterns below target this deploy's own executable and never a different
# bundle that happens to live next to it (e.g. a Kumone.app kept alongside).
# Escape regex metacharacters so a configurable path matches literally.
PROCESS_PATTERN="$(printf '%s' "$REMOTE_APP_PATH/Contents/MacOS/$APP_NAME" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
pkill -f "$PROCESS_PATTERN" || [ "$?" -eq 1 ]
# Also clear any other live instances (e.g. a build-dir copy) so the
# deployment leaves exactly one running instance, the freshly installed one.
pkill -x "$APP_NAME" || [ "$?" -eq 1 ]
sleep 2
if pgrep -x "$APP_NAME" >/dev/null; then
  printf 'ERROR: Application is still running; installation was not replaced.\n' >&2
  exit 1
fi

STEP='backup of previous application'
if [ -e "$REMOTE_APP_PATH" ] || [ -L "$REMOTE_APP_PATH" ]; then
  rm -rf -- "$BACKUP_PATH"
  mv -- "$REMOTE_APP_PATH" "$BACKUP_PATH"
fi
STEP='archive extraction (previous application is retained in .bak when present)'
tar -xzf "$ARCHIVE" -C "$TEMP_DIR"
test -f "$TEMP_DIR/$APP_NAME.app/Contents/Info.plist"
test -x "$TEMP_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME"
STEP='application replacement'
mv -- "$TEMP_DIR/$APP_NAME.app" "$REMOTE_APP_PATH"
STEP='quarantine removal'
xattr -cr "$REMOTE_APP_PATH"
STEP='application launch'
open -a "$REMOTE_APP_PATH"
STEP='version lookup'
VERSION="$(defaults read "$REMOTE_APP_PATH/Contents/Info" CFBundleShortVersionString)"
STEP='upload cleanup'
rm -f -- "$ARCHIVE"
printf 'Deployment complete: %s %s at %s\n' "$APP_NAME" "$VERSION" "$REMOTE_APP_PATH"
REMOTE
}

if [ "$DRY_RUN" = true ]; then
  printf '# Dry run: no build, transfer, or remote execution. Configuration: %s\n' "$CONF"
  printf 'ssh -o BatchMode=yes -o ConnectTimeout=10 %q true\n' "$TARGET"
  printf '# After local build and packaging, upload to the existing staging directory:\n'
  printf 'scp -O -o BatchMode=yes -o ConnectTimeout=10 %q %q\n' \
    '/tmp/kumone-deploy.XXXXXX/Kumone.app.tar.gz' "$TARGET:$SCP_PATH"
  printf "ssh -o BatchMode=yes -o ConnectTimeout=10 %q /bin/bash -s <<'KUMONE_REMOTE'\n" "$TARGET"
  remote_script
  printf 'KUMONE_REMOTE\n'
  exit 0
fi

STEP='SSH connectivity check'
ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" true || \
  fail "Cannot reach $TARGET using non-interactive SSH; check network and SSH keys."
STEP="local $CONF build"
/bin/bash "$SCRIPT_DIR/build-app.sh" "$CONF"
test -d "$ROOT/.build/app/$APP_NAME.app"
STEP='local archive creation'
LOCAL_TMP="$(mktemp -d /tmp/kumone-deploy.XXXXXX)"
ARCHIVE="$LOCAL_TMP/$APP_NAME.app.tar.gz"
tar -czf "$ARCHIVE" -C "$ROOT/.build/app" "$APP_NAME.app"
STEP='archive transfer'
# rsync replaces `scp -O` on this link: the legacy SCP protocol stalls
# mid-transfer here while the connection itself stays responsive, whereas
# rsync compresses on the wire, resumes partial files and survives the trip.
rsync -az --partial -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
  "$ARCHIVE" "$TARGET:$REMOTE_UPLOAD" || \
  fail "Transfer to $TARGET:$REMOTE_STAGING failed; remote installation was not replaced."
STEP='remote installation'
remote_script | ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" /bin/bash -s
