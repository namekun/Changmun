#!/bin/bash
# Where a new tab goes and what the start page does when there is no page, end to end, in Changmun Headless.app (started if it isn't running,
# and stopped again then; it needs a fresh bundle: rm -rf build/Changmun.app && scripts/bundle.sh):
#   ⌘T with "New tabs open: start page" makes an empty start tab with the page's search field asked to take the focus, and no command bar; a second ⌘T
#   does not pile up another; typing in the field turns the tab into a page; the command bar setting keeps the old behaviour; blank opens about:blank; a
#   custom address loads (an invalid one falls back to the start page); a private window shows the start page whatever address is set and reads no
#   history; a window or a space with no tab shows the start page; closing the last tab leaves it; ⌘L on a start tab focuses the field;
#   the AI's list_tabs, read_page, read_structured, read_markdown, read_tabs and screenshot (and a click) on a start tab show nothing of the history the page would show; a start tab
#   (and the window of only one) comes back after a quit; a 12 MP photo is made the background off the main thread.
# Cleans up the settings, the history it seeded, its space and its windows. The control.json is shared with other agents' tests: only run it when
# no other Changmun Headless is in use.
#
#   scripts/test-start-page.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SUPPORT="$HOME/Library/Application Support/Changmun Headless"
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$SUPPORT/control.json}"
BUNDLE_ID=io.github.namekun.Changmun.headless
WORK="$(mktemp -d)"
SERVER=""
STARTED=""
FAILED=0
SPACE="start check $$"
SECRET_PAGE="https://secret-frequent.example/page"
SECRET_CLOSED="https://secret-frequent.example/closed"

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-start-page.sh" -H "Content-Type: application/json" --data-binary "$2"
}
sp() { post /start-page "$1"; }
# A value out of the JSON the last call answered: val '<json>' 'd["tabs"][0]["isStart"]' prints true/false/number/string.
val() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2], {"d": d, "len": len, "any": any, "all": all, "json": json})))' "$1" "$2"; }
# The same, as plain text (strings without quotes).
vs() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2], {"d": d, "len": len, "str": str}))' "$1" "$2"; }
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; FAILED=1; }
expect() { # what expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi
}
running_pid() { pgrep -f "Changmun Headless[.]app/Contents/MacOS" | head -1; }
wait_gone() { for _ in $(seq $(( $2 * 10 ))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }
quit_app() {
    local pid
    pid="$(running_pid)"
    [[ -n "$pid" ]] || { rm -f "$ENDPOINT"; return 0; }
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
    wait_gone "$pid" 8 || { kill -9 "$pid" 2>/dev/null; wait_gone "$pid" 20; }
    rm -f "$ENDPOINT"
}
start_app() {
    scripts/headless.sh start >/dev/null 2>&1 || { bad "the app didn't start"; return 1; }
    sleep 1.5
}
cleanup() {
    if running_pid >/dev/null && [[ -f "$ENDPOINT" ]]; then
        sp '{"reset": true, "unseed": ["'"$SECRET_PAGE"'"], "action": "closeAll"}' >/dev/null 2>&1
        post /spaces "{\"action\": \"delete\", \"name\": \"$SPACE\"}" >/dev/null 2>&1
    fi
    if [[ -n "$STARTED" ]]; then quit_app; defaults delete "$BUNDLE_ID" startPageSettings >/dev/null 2>&1; fi
    [[ -z "$SERVER" ]] || { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -f /tmp/claude-501/release.lock ]]; then echo "a release is under way (/tmp/claude-501/release.lock): wait for it" >&2; exit 2; fi
if running_pid >/dev/null; then
    [[ -f "$ENDPOINT" ]] || { echo "another Changmun Headless is running without an endpoint" >&2; exit 2; }
else
    [[ -d build/Changmun.app ]] || scripts/bundle.sh >/dev/null || exit 1
    start_app || exit 1
    STARTED=1
fi

# --- a page to open: a local server ---
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir "$WORK/www" && echo "<title>Local page</title><p>hello</p>" >"$WORK/www/index.html"
(cd "$WORK/www" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
sleep 0.5
PAGE="http://127.0.0.1:$PORT/"

# --- ⌘T with the start page as the setting ---
R="$(sp '{"reset": true, "action": "closeAll"}')"
expect "an empty window shows the start page, no bar" "true|none|0" "$(vs "$R" '"|".join([str(d["showsStartPage"]).lower(), d["commandBar"], str(len(d["tabs"]))])')"
BEFORE="$(val "$R" 'd["focusRequests"]')"
R="$(sp '{"action": "newTab"}')"
expect "⌘T makes a start tab" "true" "$(val "$R" 'd["activeTabIsStart"] and len(d["tabs"]) == 1')"
expect "…with no web view" "false" "$(val "$R" 'd["hasWebView"]')"
expect "…and no command bar" "none" "$(vs "$R" 'd["commandBar"]')"
expect "…and the field asked for the focus" "true" "$(val "$R" "d[\"focusRequests\"] > $BEFORE")"
expect "…titled New Tab, with no address" "true" "$(val "$R" 'd["tabs"][0]["url"] == "" and d["tabs"][0]["title"] in ("New Tab", "새 탭")')"
# The page is drawn for the start tab: its "Customize" control is in what VoiceOver sees (named in English or Korean, as the app is).
sleep 0.5
AX="$(post /accessibility '{}')"
expect "…and the page is on screen for it" "true" "$(val "$AX" '"Customize Start Page" in json.dumps(d, ensure_ascii=False) or "시작 페이지 맞춤 설정" in json.dumps(d, ensure_ascii=False)')"
BEFORE="$(val "$R" 'd["focusRequests"]')"
R="$(sp '{"action": "newTab"}')"
expect "a second ⌘T goes to the field of the same tab" "true" "$(val "$R" "len(d[\"tabs\"]) == 1 and d[\"focusRequests\"] > $BEFORE")"
BEFORE="$(val "$R" 'd["focusRequests"]')"
R="$(sp '{"action": "openLocation"}')"
expect "⌘L on a start tab focuses the field" "true" "$(val "$R" "d[\"focusRequests\"] > $BEFORE and d[\"commandBar\"] == \"none\"")"

# Typing in the field and pressing ↓ chooses the next suggestion: the page behind the list does not take the key.
chosen() { post /accessibility '{}' | python3 -I -c 'import json, sys
def walk(n):
    yield n
    for c in n.get("children", []): yield from walk(c)
labels = [n.get("label", "") for t in json.load(sys.stdin)["trees"] for n in walk(t["root"]) if n.get("selected") and "127" in n.get("label", "")]
print("|".join(labels))'; }
post /window-text '{"commit": true, "marked": "127"}' >/dev/null
FIRST="$(chosen)"
post /window-key '{"chars": "\uf701", "keyCode": 125}' >/dev/null
SECOND="$(chosen)"
expect "↓ with text in the field moves to the next suggestion" "true" "$([[ -n "$FIRST" && -n "$SECOND" && "$FIRST" != "$SECOND" ]] && echo true || echo "false ($FIRST / $SECOND)")"
post /window-key '{"chars": "\u001b", "keyCode": 53}' >/dev/null

# --- the AI on a start tab sees a blank page (the history the page would show is seeded first) ---
sp '{"seed": {"history": [["'"$SECRET_PAGE"'", "SECRET-RECENT-PAGE"]], "closed": [["'"$SECRET_CLOSED"'", "SECRET-CLOSED-TAB"]]}}' >/dev/null
TAB="$(val "$R" 'd["activeID"]')"
for tool in 'list_tabs {}' "read_page {\"tab_id\": $TAB}" "read_structured {\"tab_id\": $TAB}" "read_markdown {\"tab_id\": $TAB}" "read_tabs {\"tab_ids\": [$TAB]}" "screenshot {\"tab_id\": $TAB}" "click {\"tab_id\": $TAB, \"element_id\": 1}"; do
    OUT="$(scripts/headless.sh call ${tool%% *} "${tool#* }" 2>&1)"
    if [[ "$OUT" == *SECRET* || "$OUT" == *secret-frequent* ]]; then bad "${tool%% *} on a start tab showed the history"; else ok "${tool%% *} on a start tab shows none of the history"; fi
    case "${tool%% *}" in
        screenshot) expect "screenshot has no picture" "false" "$(val "$OUT" 'any(c.get("type") == "image" for c in d["content"])')" ;;
        list_tabs) [[ "$OUT" == *"#$TAB New Tab — about:blank"* || "$OUT" == *"#$TAB"*"about:blank"* ]] && ok "list_tabs names it a blank New Tab" || bad "list_tabs: $OUT" ;;
    esac
done
R="$(sp '{}')"
expect "…and it is still a start tab, nothing woken" "true|false" "$(vs "$R" 'str(d["activeTabIsStart"]).lower() + "|" + str(d["hasWebView"]).lower()')"
CLOSED="$(val "$R" 'd["closedTabs"]')"

# --- typing in the field opens the input in that tab ---
R="$(sp "{\"type\": \"127.0.0.1:$PORT\", \"wait\": 1500}")"
expect "typing turns the start tab into a page tab (same tab)" "true" "$(val "$R" 'len(d["tabs"]) == 1 and not d["tabs"][0]["isStart"] and "127.0.0.1" in d["tabs"][0]["url"]')"
sleep 1
R="$(sp '{"action": "openLocation"}')"
expect "⌘L on a page is not the start page's field" "false" "$(val "$R" 'd["showsStartPage"]')"

# --- a start tab closed leaves nothing to reopen; the last tab closed leaves the start page ---
sp '{"action": "newTab"}' >/dev/null
CLOSED="$(val "$(sp '{}')" 'd["closedTabs"]')"
R="$(sp '{"action": "closeActive"}')"
expect "closing a start tab adds nothing to the closed tabs" "$CLOSED" "$(val "$R" 'd["closedTabs"]')"
R="$(sp '{"action": "closeAll"}')"
expect "closing the last tab leaves the start page, no bar" "true|none" "$(vs "$R" 'str(d["showsStartPage"]).lower() + "|" + d["commandBar"]')"

# --- the other settings ---
R="$(sp '{"newTab": "commandBar", "action": "newTab"}')"
expect "commandBar: ⌘T opens the bar and makes no tab" "true" "$(val "$R" 'd["commandBar"] == "newTab" and len(d["tabs"]) == 0 and not d["showsStartPage"]')"
R="$(sp '{"newTab": "blank", "action": "newTab"}')"
expect "blank: ⌘T opens about:blank as an ordinary tab" "true" "$(val "$R" 'd["tabs"][-1]["url"].startswith("about:blank") and not d["activeTabIsStart"] and d["commandBar"] == "none"')"
R="$(sp "{\"newTab\": \"address\", \"address\": \"$PAGE\", \"action\": \"newTab\", \"wait\": 1500}")"
expect "address: ⌘T loads the address" "true" "$(val "$R" "d[\"tabs\"][-1][\"url\"].startswith(\"$PAGE\") and not d[\"activeTabIsStart\"]")"
R="$(sp '{"address": "not an address", "action": "closeAll"}')"
R="$(sp '{"action": "newTab"}')"
expect "an invalid address falls back to the start page" "true" "$(val "$R" 'd["activeTabIsStart"]')"
R="$(sp '{"address": "", "action": "closeAll"}')"
R="$(sp '{"action": "newTab"}')"
expect "an empty address falls back to the start page" "true" "$(val "$R" 'd["activeTabIsStart"]')"

# --- a private window ignores the address and reads no history ---
sp "{\"address\": \"$PAGE\", \"action\": \"closeAll\"}" >/dev/null
sp '{"newTab": "address"}' >/dev/null
R="$(sp '{"window": "private"}')"
expect "a private window shows the start page, not the address" "true" "$(val "$R" 'd["private"] and d["showsStartPage"] and len(d["tabs"]) == 0')"
expect "…and may show no history" "false" "$(val "$R" 'd["mayShowHistory"]')"
R="$(sp '{"action": "newTab"}')"
expect "⌘T in it makes a start tab with no address" "true" "$(val "$R" 'd["private"] and d["activeTabIsStart"] and d["tabs"][0]["url"] == ""')"
post /window-close '{}' >/dev/null
sleep 1

# --- a new window and a space with no tab ---
sp '{"newTab": "startPage"}' >/dev/null
R="$(sp '{"window": "new"}')"
expect "a new window with no tab shows the start page, no bar" "true" "$(val "$R" 'd["showsStartPage"] and len(d["tabs"]) == 0 and d["commandBar"] == "none" and not d["private"]')"
post /window-close '{}' >/dev/null
sleep 1
sp '{"action": "newTab"}' >/dev/null
post /spaces "{\"action\": \"create\", \"name\": \"$SPACE\", \"symbol\": \"briefcase\", \"tint\": \"blue\"}" >/dev/null
sleep 0.5
R="$(sp '{}')"
expect "a space with no tab shows the start page, no bar" "true" "$(val "$R" 'd["showsStartPage"] and len(d["tabs"]) == 0 and d["commandBar"] == "none"')"
sp '{"newTab": "commandBar"}' >/dev/null
post /spaces "{\"action\": \"delete\", \"name\": \"$SPACE\"}" >/dev/null
sleep 0.5
sp '{"newTab": "startPage"}' >/dev/null

# --- a start tab survives a quit ---
sp '{"action": "closeAll"}' >/dev/null
sp '{"action": "newTab"}' >/dev/null
if [[ -n "$STARTED" ]]; then
    quit_app
    start_app || exit 1
    R="$(sp '{}')"
    expect "a window whose only tab was a start tab comes back as one" "true" "$(val "$R" 'len(d["tabs"]) == 1 and d["tabs"][0]["isStart"] and d["activeTabIsStart"] and d["commandBar"] == "none"')"
    expect "…and shows the start page without a web view" "true|false" "$(vs "$R" 'str(d["showsStartPage"]).lower() + "|" + str(d["hasWebView"]).lower()')"
else
    echo "skip: the app was running already, so it is not quit and started here"
fi

# --- the background picture: a 12 MP photo, off the main thread ---
PHOTO="$(ls /System/Library/Desktop\ Pictures/*.heic 2>/dev/null | head -1)"
if [[ -n "$PHOTO" ]]; then
    R="$(sp "{\"image\": \"$PHOTO\", \"wait\": 100}")"
    expect "a system photo can be made the background" "true" "$(val "$R" 'd["imageOK"]')"
    echo "info: $(basename "$PHOTO") imported in $(val "$R" 'd["imageMs"]') ms"
    FILE="$(val "$R" 'd["imageFile"]' | tr -d '"')"
    IMG="$SUPPORT/StartPage/$FILE"
    [[ -f "$IMG" ]] && expect "the copy is private (0600) in a private folder (0700)" "600 700" "$(stat -f '%Lp' "$IMG") $(stat -f '%Lp' "$SUPPORT/StartPage")" || bad "no copy at $IMG"
    [[ -f "$IMG" ]] && expect "its long edge is at most 3840" "true" "$(sips -g pixelWidth -g pixelHeight "$IMG" | awk '/pixel/ {if ($2 > m) m = $2} END {print (m <= 3840) ? "true" : "false"}')"
    sp '{"reset": true}' >/dev/null
fi

exit "$FAILED"
