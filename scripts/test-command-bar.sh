#!/bin/bash
# Return in the command bar opens the row that is highlighted, not a row from an older list: bookmarks are added so that the list shown
# for the typed words differs from the one the field had when its text last changed (before the local results came in), the second
# row is highlighted with the arrow key, and Return must open that row's page. Uses Changmun Headless.app, starting it if it isn't
# running (and stopping it again then); it refuses to share one that another run is using.
#
#   scripts/test-command-bar.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
FOLDER="Command bar check"
QUERY="zzquux.test"
STARTED=""

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-command-bar.sh" -H "Content-Type: application/json" --data-binary "$2"
}
key() { post /window-key "{\"chars\": \"$1\", \"keyCode\": $2}" >/dev/null; }
page() { echo "[\"data:text/html,<title>$1</title>\", \"$1 $QUERY\"]"; }
front_tab() { scripts/headless.sh call list_tabs | python3 -I -c 'import json, sys; print("\n".join(l for l in json.load(sys.stdin)["content"][0]["text"].splitlines() if l.startswith("*")))'; }

cleanup() {
    post /ui "{\"command\": \"none\", \"folder\": {\"name\": \"$FOLDER\", \"remove\": true, \"pages\": [$(page zz-target)$(for i in 1 2 3 4 5 6 7 8 9; do echo -n ", $(page zz-filler-$i)"; done)]}}" >/dev/null 2>&1
    [[ -z "$STARTED" ]] || scripts/headless.sh stop >/dev/null
}
trap cleanup EXIT

if pgrep -f "Changmun Headless[.]app/Contents" >/dev/null && [[ ! -f "$ENDPOINT" ]]; then echo "another Changmun Headless is running without an endpoint" >&2; exit 2; fi
if ! scripts/headless.sh call list_tabs >/dev/null 2>&1; then
    scripts/headless.sh start >/dev/null || exit 1
    STARTED=1
fi

# The target first, then more recent bookmarks than the list of an empty field has room for: those are what the field's list holds before the results come in.
post /ui "{\"folder\": {\"name\": \"$FOLDER\", \"pages\": [$(page zz-target)]}}" >/dev/null
for i in 1 2 3 4 5 6 7 8 9; do post /ui "{\"folder\": {\"name\": \"$FOLDER\", \"pages\": [$(page zz-filler-$i)]}}" >/dev/null; done
scripts/headless.sh call navigate '{"url": "https://example.com/"}' >/dev/null
post /ui '{"command": "editCurrent"}' >/dev/null
sleep 0.5
key "$QUERY" 0
sleep 2
key '\uF701' 125   # down
key '\uF701' 125
key '\r' 36
sleep 2
FRONT="$(front_tab)"
echo "$FRONT"
if [[ "$FRONT" == *zz-target* ]]; then echo "ok: Return opened the highlighted row"; else echo "FAIL: Return opened another row than the highlighted one" >&2; exit 1; fi
