#!/bin/bash
# The test copy never puts a window on a screen: with Settings open, with the AI panel in a window of its own, and with a page open, the
# window server (CGWindowListCopyWindowInfo, through scripts/check-offscreen.swift) lists no window of the test copy that overlaps any display.
# The test copy is started if it isn't running (it needs a fresh bundle: rm -rf build/Changmun.app && scripts/bundle.sh), and stopped again then.
# The control.json is shared with other agents' tests: only run it when no other Changmun Headless is in use.
#
#   scripts/test-headless-offscreen.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SUPPORT="$HOME/Library/Application Support/Changmun Headless"
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$SUPPORT/control.json}"
STARTED=""
FAILED=0

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-headless-offscreen.sh" -H "Content-Type: application/json" --data-binary "$2"
}
running_pid() { pgrep -f "Changmun Headless[.]app/Contents/MacOS" | head -1; }
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; FAILED=1; }
cleanup() {
    if [[ -n "$STARTED" ]]; then
        scripts/headless.sh stop >/dev/null 2>&1
        rm -f "$ENDPOINT"
    fi
}
trap cleanup EXIT
# Nothing of the test copy on a screen, as the window server sees it.
nothing_on_screen() {
    local pid output
    pid="$(running_pid)"
    [[ -n "$pid" ]] || { bad "$1: the test copy isn't running"; return; }
    if output="$(swift scripts/check-offscreen.swift "$pid" 2>&1)"; then ok "$1: $(tail -1 <<<"$output" | sed 's/ (displays.*//')"; else bad "$1: $output"; fi
}

if [[ -f /tmp/claude-501/release.lock ]]; then echo "a release is under way (/tmp/claude-501/release.lock): wait for it" >&2; exit 2; fi
if running_pid >/dev/null; then
    [[ -f "$ENDPOINT" ]] || { echo "another Changmun Headless is running without an endpoint" >&2; exit 2; }
else
    [[ -d build/Changmun.app ]] || scripts/bundle.sh >/dev/null || exit 1
    scripts/headless.sh start >/dev/null 2>&1 || { echo "the app didn't start" >&2; exit 1; }
    STARTED=1
    sleep 1.5
fi

scripts/headless.sh call open_tab '{"url": "about:blank"}' >/dev/null
sleep 1
nothing_on_screen "a page open"
# Settings: opened as the app opens it, and left open while the windows are listed (the picture is taken in the same request).
post /settings-image '{"page": "general"}' >/dev/null || bad "Settings didn't open"
nothing_on_screen "Settings open"
sleep 1
nothing_on_screen "Settings open, a second later"
# The AI panel in a window of its own.
post /panel '{"popOut": true}' >/dev/null || bad "the AI window didn't open"
sleep 1
nothing_on_screen "the AI panel in its own window"
post /panel '{"popOut": false}' >/dev/null
sleep 0.5
nothing_on_screen "the AI panel docked again"

if (( FAILED )); then echo "FAILED" >&2; exit 1; fi
echo "no window of the test copy reached a screen"
