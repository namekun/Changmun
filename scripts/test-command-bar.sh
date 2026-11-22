#!/bin/bash
# What the command bar opens for a row. Bookmarks are added so that the list shown for the typed words differs from the one the field had
# when its text last changed (before the local results came in):
#   Return    after the arrow key has moved the highlight to the second row, opens that row's page, not a row of the older list;
#   a click   on the row opens that row's page, also when an input method settles the syllable it was composing as the mouse goes down
#             (which changes the typed words, and with them the list, before the click is done), and a row that is gone by then opens nothing;
#   composing  a Korean syllable still being composed is part of what the list, its first row, Return and a click go by (the field shows
#             "위키" while the text it holds is "위");
#   the find bar  opened over the bar (⌘F) lends its typing to nobody: the list stays that of the words typed in the bar;
#   a site's name  the start of a visited site's name (example.com) is filled in after what is typed, selected (the next letter typed along
#             it keeps it, → keeps it and Backspace then takes a letter off it rather than filling it in again), Return opens the site, and
#             Delete takes the filled-in part away, after which Return searches.
# Uses Changmun Headless.app, starting it if it isn't running (and stopping it again then).
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
post /ui '{"command": "none"}' >/dev/null
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
FAILED=0
if [[ "$FRONT" == *zz-target* ]]; then echo "ok: Return opened the highlighted row"; else echo "FAIL: Return opened another row than the highlighted one" >&2; FAILED=1; fi

# The rows are 36 pt apart from 177 pt down, in a panel in the middle of the page: the target is the third (after the typed words and Ask AI).
ROW=249
mouse() { post /window-event "{\"type\": \"$1\", \"x\": 700, \"y\": $ROW, \"direct\": true${2:+, \"$2\": true}}" >/dev/null; }
scenario() {
    scripts/headless.sh call navigate '{"url": "https://example.com/"}' >/dev/null
    post /ui '{"command": "none"}' >/dev/null
    post /ui '{"command": "editCurrent", "sidebar": true}' >/dev/null
    sleep 0.5
    key "${QUERY%?}" 0
    post /window-text "{\"marked\": \"${QUERY: -1}\"}" >/dev/null
    sleep 2
}
scenario
mouse down; mouse up
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *zz-target* ]]; then echo "ok: a click opened the row"; else echo "FAIL: a click opened another page than its row" >&2; FAILED=1; fi

scenario
mouse down commitAfter; sleep 1; mouse up
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *zz-target* ]]; then echo "ok: a click opened its row though the typed words were settled as it went down"; else echo "FAIL: a click whose input method settled the typed words did not open its row" >&2; FAILED=1; fi

# A syllable still being composed: the first row and Return take it too, as the field shows it.
KOREAN='q=%EC%9C%84%ED%82%A4'
composing() {
    scripts/headless.sh call navigate '{"url": "https://example.com/"}' >/dev/null
    post /ui '{"command": "none"}' >/dev/null
    post /ui '{"command": "editCurrent", "sidebar": true}' >/dev/null
    sleep 0.5
    key "위" 0
    post /window-text '{"marked": "키"}' >/dev/null
    sleep 2
}
composing
ROW=177
mouse down; mouse up
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *"$KOREAN"* ]]; then echo "ok: the first row searched for the composing syllable too"; else echo "FAIL: the first row searched for less than the field shows" >&2; FAILED=1; fi
composing
key '\r' 36
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *"$KOREAN"* ]]; then echo "ok: Return searched for the composing syllable too"; else echo "FAIL: Return searched for less than the field shows" >&2; FAILED=1; fi
# The find bar opens while the bar is up and the user types in it: that is not the bar's field, and the list keeps the bar's own words.
ROW=177
scripts/headless.sh call navigate '{"url": "https://example.com/"}' >/dev/null
post /ui '{"command": "none"}' >/dev/null
post /ui '{"command": "editCurrent", "sidebar": true}' >/dev/null
sleep 0.5
key "zz quux" 0
sleep 2
post /ui '{"find": true}' >/dev/null
sleep 1
key "needlexyz" 0
sleep 2
mouse down; mouse up
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *"q=zz%20quux"* && "$FRONT" != *needlexyz* ]]; then echo "ok: typing in the find bar did not change the bar's list"; else echo "FAIL: the bar followed the find bar's field" >&2; FAILED=1; fi

# The start of a visited site's name: example.com was visited above. The field's text is read back as it is.
field_text() { post /window-text '{}' | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["string"])'; }
away() {
    scripts/headless.sh call navigate '{"url": "data:text/html,<title>elsewhere</title>"}' >/dev/null
    post /ui '{"command": "none"}' >/dev/null
    post /ui '{"command": "editCurrent"}' >/dev/null
    sleep 0.5
    key "exa" 0
    sleep 1
}
away
TEXT="$(field_text)"
if [[ "$TEXT" == "example.com" ]]; then echo "ok: the rest of the site's name was filled in"; else echo "FAIL: the field shows \"$TEXT\", not the filled-in name" >&2; FAILED=1; fi
key "m" 0
TEXT="$(field_text)"
if [[ "$TEXT" == "example.com" ]]; then echo "ok: a letter typed along the filled-in part replaced it"; else echo "FAIL: typing along the filled-in name left \"$TEXT\"" >&2; FAILED=1; fi
key '\r' 36
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *"https://example.com/"* ]]; then echo "ok: Return opened the site"; else echo "FAIL: Return did not open the site whose name was filled in" >&2; FAILED=1; fi

away
key '' 124   # →
key "x" 0
TEXT="$(field_text)"
if [[ "$TEXT" == "example.comx" ]]; then echo "ok: → kept the filled-in name"; else echo "FAIL: after → the field shows \"$TEXT\"" >&2; FAILED=1; fi

away
key '' 124   # →
key '\u007f' 51   # Delete
sleep 1
TEXT="$(field_text)"
if [[ "$TEXT" == "example.co" ]]; then echo "ok: after → Backspace took a letter off the kept name"; else echo "FAIL: after → and Backspace the field shows \"$TEXT\"" >&2; FAILED=1; fi

away
key '\u007f' 51   # Delete
TEXT="$(field_text)"
key '\r' 36
sleep 2
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$TEXT" == "exa" && "$FRONT" == *"q=exa"* ]]; then echo "ok: Delete took the filled-in name away and Return searched"; else echo "FAIL: after Delete the field showed \"$TEXT\" and Return did not search for it" >&2; FAILED=1; fi
exit $FAILED
