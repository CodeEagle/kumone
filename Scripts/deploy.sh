#!/bin/bash
# Usage: Scripts/deploy.sh [debug|release] [--dry-run]
set -euo pipefail

# Default target is the remote work machine (workmini); override with
# KUMONE_DEPLOY_HOST for other hosts (e.g. localhost for the local box).
REMOTE_HOST="${KUMONE_DEPLOY_HOST:-df-38bf-70a7-8777-6307-0.d.heiyu.space}"
REMOTE_USER="${KUMONE_DEPLOY_USER:-lincoln}"
REMOTE_APP_PATH="${KUMONE_DEPLOY_APP_PATH:-/Applications/MiuMiu.app}"
REMOTE_STAGING="${KUMONE_DEPLOY_STAGING:-~/Downloads}"
APP_NAME="${APP_NAME:-MiuMiu}"
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
# The upload name pins on the shipped commit: an interrupted transfer can
# resume the very same file on the next attempt, while a freshly built
# commit gets a fresh name and never reuses a stale leftover.
SHORT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)" || \
  fail "Could not read the git commit at $ROOT; deploy from a clean checkout."
UPLOAD_NAME="$APP_NAME.app.$SHORT_COMMIT.tar.gz"
REMOTE_UPLOAD="${REMOTE_STAGING%/}/$UPLOAD_NAME"

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
# bundle that happens to live next to it (e.g. an older Kumone.app kept alongside).
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
  printf '# After local build and packaging, upload to the staging directory:\n'
  printf 'rsync -az --partial --append-verify -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \\\n'
  printf '  %q %q  # retried up to 5 times with backoff while the tunnel is flaky\n' \
    "/tmp/kumone-deploy.XXXXXX/$APP_NAME.app.$SHORT_COMMIT.tar.gz" "$TARGET:$REMOTE_UPLOAD"
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
# gzip -n omits the mtime and name headers, so repackaging the same tree is
# byte-identical — a prerequisite for resuming a half-uploaded archive over
# --append-verify instead of writing a mismatched tail onto it.
tar -cf - -C "$ROOT/.build/app" "$APP_NAME.app" | gzip -n > "$ARCHIVE"
STEP='archive transfer'
# The workmini link is an IPv6 tunnel that drops mid-transfer while staying
# reachable in fits and starts, so the upload is resumable and retried:
# --partial keeps the half-file on the remote, --append-verify refuses to
# stitch a mismatching tail onto it, and each retry resumes where it left off.
TRANSFER_TRIES=5
TRANSFER_DELAY=5
TRANSFER_OK=false
for ((ATTEMPT = 1; ATTEMPT <= TRANSFER_TRIES; ATTEMPT++)); do
  if rsync -az --partial --append-verify \
      -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
      "$ARCHIVE" "$TARGET:$REMOTE_UPLOAD"; then
    TRANSFER_OK=true
    break
  fi
  RSYNC_STATUS=$?
  if [ "$RSYNC_STATUS" -eq 23 ]; then
    # rsync 23 covers a failed --append-verify: the leftover remote file is
    # not our archive. Drop it so the next attempt resends from scratch
    # instead of failing forever on the same corrupt overlap.
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" \
      "rm -f -- $(printf '%q' "$REMOTE_UPLOAD")" || true
  fi
  if [ "$ATTEMPT" -lt "$TRANSFER_TRIES" ]; then
    printf 'Transfer attempt %s/%s failed (rsync exit %s); retrying in %ss.\n' \
      "$ATTEMPT" "$TRANSFER_TRIES" "$RSYNC_STATUS" "$TRANSFER_DELAY" >&2
    sleep "$TRANSFER_DELAY"
    TRANSFER_DELAY=$((TRANSFER_DELAY + 5))
  fi
done
[ "$TRANSFER_OK" = true ] || \
  fail "Transfer to $TARGET:$REMOTE_STAGING failed after $TRANSFER_TRIES attempts; remote installation was not replaced."
STEP='remote installation'
remote_script | ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" /bin/bash -s
