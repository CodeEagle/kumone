#!/bin/bash
# Zero-human hero-transition verification.
#
# Builds the app, launches it with KUMONE_HERO_SELF_TEST=1 so it runs one
# now-playing round trip on its own (see HeroSelfTest), and asserts the probe
# log gained a PASS line for the now-playing artwork. Repeatable: it never
# truncates /tmp/kumone-hero.log, only ever reading the lines this run added.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="/tmp/kumone-hero.log"
APP_BIN="$ROOT/.build/app/Kumone.app/Contents/MacOS/Kumone"

# The lines this run adds start right after this offset.
if [ -f "$LOG_FILE" ]; then
    startLines=$(wc -l < "$LOG_FILE" | tr -d '[:space:]')
else
    startLines=0
fi

newLines() {
    tail -n "+$((startLines + 1))" "$LOG_FILE" 2>/dev/null || true
}

bash "$SCRIPT_DIR/build-app.sh" debug

KUMONE_HERO_SELF_TEST=1 exec "$APP_BIN" &
APP_PID=$!

kill_app() {
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
    fi
}
trap kill_app EXIT

# The self-test writes a "HERO SELFTEST END" summary line once it is done, win
# or lose; until then the app is still flying the transition.
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -f "$LOG_FILE" ] && newLines | grep -q "HERO SELFTEST END"; then
        break
    fi
    sleep 1
done

kill_app
trap - EXIT

status=1
if newLines | grep -q "HERO FAIL"; then
    status=1
elif newLines | grep -q "HERO SELFTEST END pass=1"; then
    status=0
fi

# Everything this run produced, verdict first, then the full transcript.
newLines
exit "$status"
