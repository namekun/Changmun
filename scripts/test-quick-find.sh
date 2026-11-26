#!/bin/bash
# What the ⌘K list (find tabs and commands) does in the real app:
#   Return    opens the highlighted row: the tab typed for, and with the arrow key the row below it, not the first;
#   Esc       closes the list;
#   a Korean syllable still being composed  is part of what the list goes by: "zz위" with "키" composing finds the tab "zz위키백과", not "zz위치",
#             which "zz위" alone would put first (it was opened later)
#             (a real input method's Return only settles the syllable; this test's synthetic one submits, as in test-command-bar.sh);
#   words a bookmark was found for  are the only words its row is shown for: once more is typed, Return opens nothing of the earlier ones.
# The list is opened through the test hook (the headless app's key events carry no modifiers, so no ⌘K); everything after that is typed.
# Uses Changmun Headless.app, starting it if it isn't running (and stopping it again then).
#
#   scripts/test-quick-find.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
STARTED=""
FOLDER="Quick find check"
MARK="https://zzmark.test/"

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-quick-find.sh" -H "Content-Type: application/json" --data-binary "$2"
}
key() { post /window-key "{\"chars\": \"$1\", \"keyCode\": $2}" >/dev/null; }
open_list() { post /ui '{"command": "none"}' >/dev/null; post /ui '{"command": "quickFind"}' >/dev/null; sleep 0.5; }
list_is_open() { post /ui '{}' | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["quickFind"])'; }
front_tab() { scripts/headless.sh call list_tabs | python3 -I -c 'import json, sys; print("\n".join(l for l in json.load(sys.stdin)["content"][0]["text"].splitlines() if l.startswith("*")))'; }
tab_count() { scripts/headless.sh call list_tabs | python3 -I -c 'import json, sys; print(len([l for l in json.load(sys.stdin)["content"][0]["text"].splitlines() if l.strip()]))'; }

cleanup() {
    post /ui '{"command": "none"}' >/dev/null 2>&1
    post /ui "{\"folder\": {\"name\": \"$FOLDER\", \"remove\": true, \"pages\": [[\"$MARK\", \"zzmark\"]]}}" >/dev/null 2>&1
    for name in zzalpha zzbravo zzcharlie zz위키백과 zz위치; do
        ID="$(post /ui '{}' | python3 -I -c 'import json, sys; print(next((t["id"] for t in json.load(sys.stdin)["tabs"] if t["title"] == sys.argv[1]), ""))' "$name" 2>/dev/null)"
        [[ -z "$ID" ]] || scripts/headless.sh call close_tab "{\"tab_id\": $ID}" >/dev/null 2>&1
    done
    [[ -z "$STARTED" ]] || scripts/headless.sh stop >/dev/null
}
trap cleanup EXIT

if pgrep -f "Changmun Headless[.]app/Contents" >/dev/null && [[ ! -f "$ENDPOINT" ]]; then echo "another Changmun Headless is running without an endpoint" >&2; exit 2; fi
if ! scripts/headless.sh call list_tabs >/dev/null 2>&1; then
    scripts/headless.sh start >/dev/null || exit 1
    STARTED=1
fi

FAILED=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; FAILED=1; }

post /ui "{\"folder\": {\"name\": \"$FOLDER\", \"pages\": [[\"$MARK\", \"zzmark\"]]}}" >/dev/null
# Nothing answers at the address, and the page the tab shows is the html given: its title is what the list searches.
for name in zzalpha zzbravo zzcharlie zz위키백과 zz위치; do
    scripts/headless.sh call open_tab '{"url": "http://127.0.0.1:9/"}' >/dev/null
    sleep 0.5
    post /load-html "{\"html\": \"<title>$name</title><p>$name</p>\", \"base\": \"https://lab.test/$name\"}" >/dev/null
done
sleep 1
# zzcharlie is in front now (the last one opened).

# Return opens the row typed for.
open_list
key "zzbravo" 0
sleep 1.5
key '\r' 36
sleep 1
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *zzbravo* ]]; then ok "Return opened the tab typed for"; else fail "Return did not open zzbravo"; fi
if [[ "$(list_is_open)" == "False" ]]; then ok "the list closed"; else fail "the list stayed open after Return"; fi

# The arrow key moves the highlight: the same words open the first row with Return alone, and the row below with one arrow down.
open_list
key "zz" 0
sleep 1.5
key '\r' 36
sleep 1
FIRST="$(front_tab)"
scripts/headless.sh call switch_tab "{\"tab_id\": $(post /ui '{}' | python3 -I -c 'import json, sys; print(next(t["id"] for t in json.load(sys.stdin)["tabs"] if t["title"] == "zzcharlie"))')}" >/dev/null
sleep 0.5
open_list
key "zz" 0
sleep 1.5
key '' 125   # down
key '\r' 36
sleep 1
SECOND="$(front_tab)"
echo "first row: $FIRST"; echo "second row: $SECOND"
if [[ "$FIRST" == *zz* && "$SECOND" == *zz* && "$FIRST" != "$SECOND" ]]; then ok "an arrow key moved the highlight to another row"; else fail "the arrow key did not change what Return opens"; fi

# Esc closes it.
open_list
key "zz" 0
sleep 0.5
key '\u001b' 53
sleep 0.5
if [[ "$(list_is_open)" == "False" ]]; then ok "Esc closed the list"; else fail "Esc left the list open"; fi

# A syllable still being composed is part of the words the list is for, as the field shows it.
open_list
key "zz위" 0
post /window-text '{"marked": "키"}' >/dev/null
sleep 1.5
key '\r' 36
sleep 1
FRONT="$(front_tab)"; echo "$FRONT"
if [[ "$FRONT" == *zz위키백과* ]]; then ok "the list went by the composing syllable too"; else fail "the list ignored the syllable being composed"; fi

# A bookmark found for "zzmark" is not a row for "zzmarkq": nothing is opened by a Return after one more letter.
open_list
key "zzmark" 0
sleep 1.5
key "q" 0
BEFORE="$(tab_count)"
key '\r' 36
sleep 1
if [[ "$(tab_count)" == "$BEFORE" && "$(list_is_open)" == "True" ]]; then ok "no row of the earlier words was opened"; else fail "a row found for earlier words was opened"; fi
post /ui '{"command": "none"}' >/dev/null

exit $FAILED
