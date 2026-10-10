#!/bin/bash
# Run on the deployed Mac. UI only stimulates the transition; acceptance
# evidence comes from lifecycle logs and native heap snapshots, not pixels.
set -euo pipefail
DIAG_PID="${1:-$(pgrep -x miumiu)}"
DIAG_ROUNDS="${2:-3}"
case "$DIAG_PID" in ''|*[!0-9]*) echo 'Expected exactly one miumiu PID' >&2; exit 1;; esac
case "$DIAG_ROUNDS" in ''|*[!0-9]*) exit 1;; esac
DIAG_DIR="$(mktemp -d /tmp/kumone-artlife.XXXXXX)"
echo "ARTLIFE_REPORT=$DIAG_DIR PID=$DIAG_PID"

mini_help() {
  osascript -e 'tell application "System Events" to tell process "miumiu" to get help of button 1 of group 1 of window 1'
}
track_id() {
  /usr/libexec/PlistBuddy -c 'Print :player.state' "$HOME/Library/Preferences/im.missuo.Kumone.plist" |
    ruby -rjson -e 'puts JSON.parse(STDIN.read)["currentID"]'
}
sample() {
  /usr/bin/footprint -p "$DIAG_PID" > "$DIAG_DIR/$1-footprint.txt"
  /usr/bin/heap -s -z "$DIAG_PID" > "$DIAG_DIR/$1-heap.txt"
  head -n 3 "$DIAG_DIR/$1-footprint.txt"
  grep '^Zone DefaultPurgeable.*nodes - Sizes:' "$DIAG_DIR/$1-heap.txt" || true
}

[ "$(mini_help)" = 'Open Now Playing' ] || { echo 'Start from the minibar with a current track' >&2; exit 1; }
DIAG_TRACK="$(track_id)"
sample before
for ((DIAG_ROUND=1; DIAG_ROUND<=DIAG_ROUNDS; DIAG_ROUND++)); do
  osascript -e 'tell application "System Events" to tell process "miumiu" to click button 1 of group 1 of window 1' >/dev/null
  sleep 3
  [ "$(mini_help)" != 'Open Now Playing' ] || { echo 'Detail did not open' >&2; exit 1; }
  DIAG_CLOSE_SIZE="$(osascript -e 'tell application "System Events" to tell process "miumiu" to get size of button 2 of group 1 of window 1')"
  [ "$DIAG_CLOSE_SIZE" = '44, 44' ] || { echo 'Unrecognized close button; stopping' >&2; exit 1; }
  osascript -e 'tell application "System Events" to tell process "miumiu" to click button 2 of group 1 of window 1' >/dev/null
  sleep 16
  [ "$(mini_help)" = 'Open Now Playing' ] || { echo 'Detail did not close' >&2; exit 1; }
  [ "$(track_id)" = "$DIAG_TRACK" ] || { echo 'Track changed; invalidate comparison' >&2; exit 1; }
  echo "ROUND=$DIAG_ROUND closed=true track=$DIAG_TRACK"
  sample "closed-$DIAG_ROUND"
done
/usr/bin/log show --last 10m --info --style compact --predicate \
  "processIdentifier == $DIAG_PID AND (eventMessage CONTAINS \"ARTLIFE\" OR eventMessage CONTAINS \"HERO DIR end now-playing-artwork\" OR eventMessage CONTAINS \"SHADER APPLY\")" \
  > "$DIAG_DIR/lifecycle.txt"
echo "ARTLIFE_REPORT=$DIAG_DIR"
