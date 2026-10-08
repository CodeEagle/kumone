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
# The self test's first hop is a MainActor task that is not scheduled while the
# main thread sits parked in its event wait (see HeroSelfTest's runLoopTick for
# the same class of stall). The bare SwiftPM executable works where the app
# bundle hangs; prefer it when it exists.
APP_BIN="$ROOT/.build/debug/Kumone"
if [ ! -x "$APP_BIN" ]; then
    APP_BIN="$ROOT/.build/app/MiuMiu.app/Contents/MacOS/MiuMiu"
fi

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

# A parked main thread will not schedule the self test's first hop on its own.
# A few synthetic mouse moves are run-loop events that wake it; the app that
# responds is the one that just launched.
if [ ! -x /tmp/kumone-mousepump ]; then
    cat > /tmp/kumone-mousepump.swift <<'SWIFT'
import CoreGraphics
for i in 0..<10 {
    let point = CGPoint(x: 900 + Double(i % 8) * 40, y: 400 + Double(i % 5) * 30)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(300_000)
}
SWIFT
    swiftc /tmp/kumone-mousepump.swift -o /tmp/kumone-mousepump 2>/dev/null || true
fi
[ -x /tmp/kumone-mousepump ] && /tmp/kumone-mousepump || true

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
