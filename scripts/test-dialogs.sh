#!/bin/bash
# The app's one dialog, end to end, in Changmun Headless.app (started if it isn't running, and stopped again then; it needs a fresh bundle:
# rm -rf build/Changmun.app && scripts/bundle.sh). Each dialog is shown on the front window through the test copy's /dialog, as the code that asks
# builds it, and keys are pressed in its sheet:
#   Return presses the safe choice (Cancel on a delete, an app link or an extension, Block on the camera) and Esc the Cancel; on the sign-in, Return
#   presses Sign In with what was typed in both fields; a window with a sheet up refuses what a page can start (a second question is answered no and
#   nothing is stacked); names a page chose are cut and cleaned in the title; a question of the AI's, held, is a sheet that the stop button
#   (`/approvals` release) ends from elsewhere.
# The control.json is shared with other agents' tests: only run it when no other Changmun Headless is in use.
#
#   scripts/test-dialogs.sh
set -uo pipefail
cd "$(dirname "$0")/.."
SUPPORT="$HOME/Library/Application Support/Changmun Headless"
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$SUPPORT/control.json}"
BUNDLE_ID=io.github.namekun.Changmun.headless
WORK="$(mktemp -d)"
SERVER=""
STARTED=""
FAILED=0

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-dialogs.sh" -H "Content-Type: application/json" --data-binary "$2"
}
dlg() { post /dialog "$1"; }
val() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1]); r = eval(sys.argv[2], {"d": d, "len": len, "any": any, "all": all}); print(r if isinstance(r, str) else json.dumps(r))' "$1" "$2"; }
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; FAILED=1; }
expect() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi; }
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
cleanup() {
    if running_pid >/dev/null && [[ -f "$ENDPOINT" ]]; then
        post /approvals '{"release": "deny", "hold": false}' >/dev/null 2>&1
        for _ in 1 2 3; do dlg '{"key": {"chars": "\u001b", "keyCode": 53}}' >/dev/null 2>&1; done
    fi
    if [[ -n "$STARTED" ]]; then quit_app; fi
    [[ -z "$SERVER" ]] || { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
    rm -rf "$WORK"
}
trap cleanup EXIT
RETURN='{"key": {"chars": "\r", "keyCode": 36}}'
ESCAPE='{"key": {"chars": "\u001b", "keyCode": 53}}'

if [[ -f /tmp/claude-501/release.lock ]]; then echo "a release is under way (/tmp/claude-501/release.lock): wait for it" >&2; exit 2; fi
if running_pid >/dev/null; then
    [[ -f "$ENDPOINT" ]] || { echo "another Changmun Headless is running without an endpoint" >&2; exit 2; }
else
    [[ -d build/Changmun.app ]] || scripts/bundle.sh >/dev/null || exit 1
    scripts/headless.sh start >/dev/null 2>&1 || { echo "the app didn't start" >&2; exit 1; }
    STARTED=1
    sleep 1.5
fi
PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
mkdir "$WORK/www" && echo "<title>Dialog page</title><button>Pay now</button>" >"$WORK/www/index.html"
(cd "$WORK/www" && exec python3 -I -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
sleep 0.5
scripts/headless.sh call open_tab "{\"url\": \"http://127.0.0.1:$PORT/\"}" >/dev/null
sleep 1.5
dlg '{"clear": true}' >/dev/null

# --- Return and Esc on the dialogs that ask to be answered with care ---
for NAME in delete-folder delete-source delete-space app-link camera microphone camera-microphone extension-turn-on extension-update extension-ask chat-link; do
    R="$(dlg "{\"show\": \"$NAME\"}")"
    expect "$NAME: a sheet is up, with Cancel/Block/Deny as the button Return presses" "true|true" "$(val "$R" 'str(d["sheet"]).lower() + "|" + str(d["default"] == 0 and d["cancel"] == 0).lower()')"
    R="$(dlg "$RETURN")"
    expect "$NAME: Return answers with the first button and ends the sheet" "false|$NAME: button 0" "$(val "$R" 'str(d["sheet"]).lower() + "|" + d["answers"][-1]')"
    dlg "{\"show\": \"$NAME\"}" >/dev/null
    R="$(dlg "$ESCAPE")"
    expect "$NAME: Esc answers with the same button" "false|$NAME: button 0" "$(val "$R" 'str(d["sheet"]).lower() + "|" + d["answers"][-1]')"
done

# --- the login: typed into both fields, Return signs in; Esc cancels ---
dlg '{"show": "sign-in"}' >/dev/null
dlg '{"type": "bob"}' >/dev/null
dlg '{"key": {"chars": "\t", "keyCode": 48}}' >/dev/null
R="$(dlg '{"type": "secret"}')"
expect "sign-in: the sheet is still up while typing" "true" "$(val "$R" 'd["sheet"]')"
R="$(dlg "$RETURN")"
expect "sign-in: Return signs in with both fields" "sign-in: button 1 fields 2" "$(val "$R" 'd["answers"][-1]')"
dlg '{"show": "sign-in-failed"}' >/dev/null
R="$(dlg "$ESCAPE")"
expect "sign-in: Esc cancels" "sign-in-failed: button 0 fields 2" "$(val "$R" 'd["answers"][-1]')"

# --- a window with a sheet up refuses what a page can start ---
R="$(dlg '{"show": "camera"}')"
CAMERA_TITLE="$(val "$R" 'd["sheetTitle"]')"
R="$(dlg '{"show": "app-link"}')"
expect "busy: the app link is not stacked on the camera question" "true|$CAMERA_TITLE" "$(val "$R" 'str(d["sheet"]).lower() + "|" + d["sheetTitle"]')"
expect "busy: …and was answered no" "app-link: none" "$(val "$R" 'd["answers"][-1]')"
R="$(dlg '{"show": "sign-in"}')"
expect "busy: nor the login" "sign-in: none" "$(val "$R" 'd["answers"][-1]')"
dlg "$ESCAPE" >/dev/null

# --- names a page chose ---
R="$(dlg '{"show": "hostile"}')"
expect "hostile: the title is short and has no right-to-left override" "true" "$(val "$R" 'len(d["title"]) < 120 and "‮" not in d["title"] and "‮" not in d["message"]')"
dlg "$ESCAPE" >/dev/null

# --- the AI's question as a sheet, ended from elsewhere ---
dlg '{"show": "approval-sheet"}' >/dev/null
R="$(dlg '{}')"
expect "approval: a held question of the high tier is a sheet" "true" "$(val "$R" 'd["sheet"]')"
post /approvals '{"release": "deny"}' >/dev/null
sleep 0.5
R="$(dlg '{}')"
expect "approval: releasing it (the stop button) ends the sheet" "false" "$(val "$R" 'd["sheet"]')"
dlg '{"show": "approval-sheet"}' >/dev/null
dlg "$RETURN" >/dev/null
R="$(dlg '{}')"
expect "approval: Return answers it (Don't Allow) and ends the sheet" "false" "$(val "$R" 'd["sheet"]')"
post /approvals '{"hold": false}' >/dev/null

if (( FAILED )); then echo "FAILED" >&2; exit 1; fi
echo "all dialog checks passed"
