#!/bin/bash
# Changmun Headless.app: the browser for tests and agents. It stays off screen, never takes focus or plays sound,
# and has its own profile (settings, cookies, history in ~/Library/Application Support/Changmun Headless).
#
#   scripts/headless.sh start               copy build/Changmun.app as the headless app and start it
#   scripts/headless.sh call <tool> [json]  run a browser tool: list_tabs, open_tab, navigate, read_page, click, screenshot…
#   scripts/headless.sh shot <file.png>     capture the front window, sidebar and all
#   scripts/headless.sh mouse <down|drag|up|right> <x> <y>   a mouse event at a point in the window, from its top left
#   scripts/headless.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Changmun Headless.app"
ENDPOINT="$HOME/Library/Application Support/Changmun Headless/control.json"

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
running() { [[ -f "$ENDPOINT" ]] && kill -0 "$(field pid)" 2>/dev/null; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: headless.sh" -H "Content-Type: application/json" --data-binary "$2"
}

case "${1:-}" in
start)
    if running; then echo "already running (pid $(field pid))"; exit 0; fi
    [[ -d build/Changmun.app ]] || scripts/bundle.sh
    # Signed outside the project folder, like bundle.sh: a synced folder adds Finder info that codesign rejects.
    WORK="$(mktemp -d)"
    ditto build/Changmun.app "$WORK/Changmun Headless.app"
    PLIST="$WORK/Changmun Headless.app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string io.github.namekun.Changmun.headless "$PLIST"
    plutil -replace CFBundleName -string "Changmun Headless" "$PLIST"
    plutil -replace LSBackgroundOnly -bool true "$PLIST"
    # Not a browser to macOS, so it never shows up among the default browsers or gets sent links.
    plutil -remove CFBundleURLTypes "$PLIST"
    plutil -remove CFBundleDocumentTypes "$PLIST"
    xattr -cr "$WORK/Changmun Headless.app"
    codesign --force --sign - "$WORK/Changmun Headless.app" >/dev/null
    rm -rf "$APP"
    ditto "$WORK/Changmun Headless.app" "$APP"
    rm -rf "$WORK"
    rm -f "$ENDPOINT"
    open -g "$APP"
    for _ in $(seq 100); do
        if running; then echo "started (pid $(field pid))"; exit 0; fi
        sleep 0.15
    done
    echo "did not start" >&2; exit 1
    ;;
call)
    running || { echo "not running: $0 start" >&2; exit 1; }
    [[ $# -ge 2 ]] || { echo "usage: $0 call <tool> [json arguments]" >&2; exit 2; }
    post /call "{\"name\": \"$2\", \"arguments\": ${3:-"{}"}}"
    echo
    ;;
shot)
    running || { echo "not running: $0 start" >&2; exit 1; }
    [[ $# -ge 2 ]] || { echo "usage: $0 shot <file.png>" >&2; exit 2; }
    post /window-image '{}' | python3 -I -c 'import base64, json, sys; open(sys.argv[1], "wb").write(base64.b64decode(json.load(sys.stdin)["png"]))' "$2"
    echo "$2"
    ;;
mouse)
    running || { echo "not running: $0 start" >&2; exit 1; }
    [[ $# -eq 4 ]] || { echo "usage: $0 mouse <down|drag|up|right> <x> <y>" >&2; exit 2; }
    post /window-event "{\"type\": \"$2\", \"x\": $3, \"y\": $4}"
    echo
    ;;
stop)
    if running; then kill "$(field pid)"; echo stopped; else echo "not running"; fi
    ;;
*)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
