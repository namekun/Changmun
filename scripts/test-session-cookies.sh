#!/bin/bash
# Sign-ins that sites meant to end with the browser (session cookies), end to end: a local server sets six cookies (two plain session ones, an HttpOnly
# one, SameSite Lax and Strict ones, and two that last a day), and Changmun Headless.app is stopped in each way a browser ends, started again, and asked
# which cookies the server gets:
#   a quit right after signing in, SIGTERM and SIGKILL a few seconds later, closing the last window, in the default store and in a profile space's;
#   a sign-out the server asked for is not undone by the journal; with "Stay signed in after quitting" off, and by default in the headless apps, only
#   the day-long cookies (which WebKit keeps itself) are back and no journal file is left; with "Quit when the last window is closed" off the window closes and the app goes on, and a new window opens.
# The journal's files are checked to be private and to hold none of the values. Run in Changmun Headless.app, which it starts for each case (and stops
# after); it needs a fresh bundle (rm -rf build/Changmun.app && scripts/bundle.sh). Cleans up the cookies, the space and the settings it makes.
#
#   scripts/test-session-cookies.sh
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/headless-lib.sh
SUPPORT="$HOME/Library/Application Support/Changmun Headless"
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$SUPPORT/control.json}"
BUNDLE_ID=io.github.namekun.Changmun.headless
SPACE="cookie check $$"
WORK="$(mktemp -d)"
SERVER=""
FAILED=0
ALL="hpid,hsid,lax_sid,pid,sid,strict_sid"
DAY="hpid,pid"

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-session-cookies.sh" -H "Content-Type: application/json" --data-binary "$2"
}
call() { scripts/headless.sh call "$@"; }
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1" >&2; FAILED=1; }
expect() { # what expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (wanted '$2', got '$3')"; fi
}

running_pid() { pgrep -f "Changmun Headless[.]app/Contents/MacOS" | head -1; }
wait_gone() { # pid seconds
    for _ in $(seq $(( $2 * 10 ))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
    return 1
}
# Ends whatever runs: asked to quit first (so the session is saved without the tabs this test opened), then killed.
stop_app() {
    local pid
    pid="$(running_pid)"
    [[ -n "$pid" ]] || { rm -f "$ENDPOINT"; return 0; }
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
    wait_gone "$pid" 8 || { kill -9 "$pid" 2>/dev/null; wait_gone "$pid" 20; }
    rm -f "$ENDPOINT"
}
# The tabs this test opened (the ones on its server) closed, so none is left in the test copy's session.
close_local_tabs() {
    local id
    for id in $(call list_tabs | python3 -I -c 'import json, re, sys
for line in json.load(sys.stdin)["content"][0]["text"].splitlines():
    m = re.search(r"#(\d+)\b.*127\.0\.0\.1", line)
    if m: print(m.group(1))'); do call close_tab "{\"tab_id\": $id}" >/dev/null; done
}
start_app() {
    scripts/headless.sh start >/dev/null 2>&1 || { bad "the app didn't start"; return 1; }
    sleep 1.5
}
cleanup() {
    stop_app
    defaults delete "$BUNDLE_ID" keepSessionCookies >/dev/null 2>&1
    defaults delete "$BUNDLE_ID" quitWhenLastWindowCloses >/dev/null 2>&1
    [[ -z "$SERVER" ]] || { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
    rm -rf "$WORK"
}
trap cleanup EXIT

# The headless apps keep no sign-ins unless told to: this test tells the test copy to.
defaults write "$BUNDLE_ID" keepSessionCookies -bool true
if pgrep -f "Changmun Headless[.]app/Contents" >/dev/null; then echo "a Changmun Headless is running: stop it first (this test restarts it)" >&2; exit 2; fi
[[ -d build/Changmun.app ]] || scripts/bundle.sh >/dev/null || exit 1

# --- the server: /login sets the cookies, /logout takes them away, /whoami says which came back ---
cat > "$WORK/server.py" <<'EOF'
import http.server, sys
NAMES = ("sid", "hsid", "pid", "lax_sid", "strict_sid", "hpid")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        path = self.path.split("?")[0]
        cookies, body = [], "hi"
        if path == "/login":
            cookies = ["sid=ckj-secret-value-123; Path=/", "hsid=H1; Path=/; HttpOnly", "pid=P1; Path=/; Max-Age=86400",
                       "lax_sid=L1; Path=/; SameSite=Lax", "strict_sid=T1; Path=/; SameSite=Strict",
                       "hpid=HP1; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax"]
            body = "logged in"
        elif path == "/logout":
            cookies = [n + "=; Path=/; Max-Age=0" for n in NAMES]
            body = "logged out"
        elif path == "/whoami":
            got = sorted(p.split("=")[0].strip() for p in self.headers.get("Cookie", "").split(";") if p.strip())
            body = "COOKIES:" + ",".join(got) + ":END"
        self.send_response(200)
        for c in cookies: self.send_header("Set-Cookie", c)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(("<html><body>" + body + "</body></html>").encode())
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
EOF
python3 -I "$WORK/server.py" "$WORK/port" &
SERVER=$!
for _ in $(seq 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
PORT="$(cat "$WORK/port")"
URL="http://127.0.0.1:$PORT"

login() { call open_tab "{\"url\":\"$URL/login\"}" >/dev/null; sleep 1.5; }
# Which cookies the server gets, read in a new tab of the space in front.
cookies() {
    call open_tab "{\"url\":\"$URL/whoami\"}" >/dev/null
    sleep 1.5
    call read_page '{"max_chars":300}' | grep -o 'COOKIES:[^:]*:END' | head -1 | sed -e 's/^COOKIES://' -e 's/:END$//'
}
logout() { call open_tab "{\"url\":\"$URL/logout\"}" >/dev/null; sleep 1; }
# The journal's files: private, and with none of the values in them.
check_files() {
    local files=("$SUPPORT"/Cookies/*.journal) bad_mode="" leaked=""
    [[ -e "${files[0]}" ]] || { bad "$1: no journal file"; return; }
    for f in "${files[@]}"; do
        [[ "$(stat -f %Lp "$f")" == 600 ]] || bad_mode="$f"
        grep -qa "ckj-secret-value-123" "$f" && leaked="$f"
    done
    [[ "$(stat -f %Lp "$SUPPORT/Cookies")" == 700 ]] && [[ -z "$bad_mode" ]] && ok "$1: the journal is private (mode 0600 in a 0700 folder)" || bad "$1: the journal's files aren't private ($bad_mode)"
    [[ -z "$leaked" ]] && ok "$1: no cookie value is readable in the journal" || bad "$1: a cookie value is readable in $leaked"
}

# One case: start, sign in, let $2 seconds pass, end the app the way $1 says, start it again and see which cookies the server gets.
# $3 is "profile" to do it in a profile space.
case_in() { # how seconds store expected
    local how="$1" wait="$2" store="$3" expected="$4" pid
    stop_app
    start_app || return
    if [[ "$store" == profile ]]; then
        post /spaces "{\"action\":\"create\",\"name\":\"$SPACE\",\"profile\":true}" >/dev/null
        sleep 1
    fi
    login
    expect "$how, $store store: signed in" "$ALL" "$(cookies)"
    sleep "$wait"
    pid="$(field pid)"
    case "$how" in
        quit) osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 ;;
        term) kill -TERM "$pid" ;;
        kill) kill -9 "$pid" ;;
        close) post /window-close '{}' >/dev/null ;;
    esac
    wait_gone "$pid" 15 || { bad "$how: the app didn't end"; kill -9 "$pid"; wait_gone "$pid" 10; }
    rm -f "$ENDPOINT"
    start_app || return
    if [[ "$store" == profile ]]; then post /spaces "{\"action\":\"switch\",\"name\":\"$SPACE\"}" >/dev/null; sleep 1; fi
    expect "$how${wait:+ after ${wait}s}, $store store: after the restart" "$expected" "$(cookies)"
    check_files "$how, $store store"
    logout
    close_local_tabs
    if [[ "$store" == profile ]]; then post /spaces "{\"action\":\"delete\",\"name\":\"$SPACE\"}" >/dev/null; fi
    sleep 3
    stop_app
}

for store in default profile; do
    case_in quit 0 "$store" "$ALL"
    case_in term 3 "$store" "$ALL"
    case_in kill 3 "$store" "$ALL"
done
case_in close 0 default "$ALL"

# A sign-out the server asked for stays one: the journal follows the store, it doesn't hold on to what the store lost.
stop_app; start_app
login
sleep 3
logout
sleep 3
pid="$(field pid)"
kill -9 "$pid"; wait_gone "$pid" 15; rm -f "$ENDPOINT"
start_app
expect "signing out: after a kill, nothing comes back" "" "$(cookies)"
close_local_tabs
stop_app

# The switch off, and the headless apps' own default (off): only what lasts a day is back, and no file is left.
off_case() { # what
    start_app
    login
    close_local_tabs
    expect "$1: signed in" "$ALL" "$(cookies)"
    sleep 3
    local pid
    pid="$(field pid)"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1
    wait_gone "$pid" 15 || { kill -9 "$pid"; wait_gone "$pid" 10; }
    rm -f "$ENDPOINT"
    start_app
    expect "$1: only the cookies that last a day are back" "$DAY" "$(cookies)"
    [[ -z "$(ls "$SUPPORT"/Cookies/*.journal 2>/dev/null)" ]] && ok "$1: no journal file is left" || bad "$1: a journal file is left"
    logout
    close_local_tabs
    stop_app
}
defaults write "$BUNDLE_ID" keepSessionCookies -bool false
off_case "stay signed in off"
defaults delete "$BUNDLE_ID" keepSessionCookies
off_case "headless default (nothing set)"
defaults write "$BUNDLE_ID" keepSessionCookies -bool true

# Closing the last window with "Quit when the last window is closed" off: the app goes on, with no window, and opens one when asked.
defaults write "$BUNDLE_ID" quitWhenLastWindowCloses -bool false
start_app
pid="$(field pid)"
post /window-close '{}' >/dev/null
sleep 2
if kill -0 "$pid" 2>/dev/null; then ok "last window closed: the app is still running"; else bad "last window closed: the app quit"; fi
if kill -0 "$pid" 2>/dev/null; then
    [[ "$(call list_tabs)" == *"No tabs are open"* ]] && ok "last window closed: no window is left" || bad "last window closed: a window is still there"
    call open_tab "{\"url\":\"$URL/whoami\"}" >/dev/null
    sleep 1.5
    [[ "$(call read_page '{"max_chars":300}')" == *COOKIES* ]] && ok "last window closed: a new window opens and loads a page" || bad "last window closed: no window came back"
    kill -0 "$pid" 2>/dev/null && [[ "$(field pid)" == "$pid" ]] && ok "last window closed: it is the same process" || bad "last window closed: not the same process"
    # The Dock icon (the app asked to open again) and ⌘N with no window bring the session back as at a launch: the tab the last window had.
    post /window-close '{}' >/dev/null
    sleep 1.5
    TABS="$(post /reopen '{"how":"reopen"}')"
    [[ "$TABS" == *'"windows":1'* && "$TABS" != *'"tabs":0'* && "$(call list_tabs)" == *127.0.0.1* ]] && ok "the Dock icon opens a window with the last session's tab ($TABS)" || bad "the Dock icon didn't bring the session back ($TABS)"
    post /window-close '{}' >/dev/null
    sleep 1.5
    TABS="$(post /reopen '{"how":"newWindow"}')"
    [[ "$TABS" == *'"windows":1'* && "$TABS" != *'"tabs":0'* && "$(call list_tabs)" == *127.0.0.1* ]] && ok "⌘N with no window opens the last session's tab ($TABS)" || bad "⌘N with no window didn't bring the session back ($TABS)"
    TABS="$(post /reopen '{"how":"reopen"}')"
    [[ "$TABS" == *'"windows":1'* ]] && ok "the Dock icon with a window open opens no other" || bad "the Dock icon opened another window ($TABS)"
    close_local_tabs
fi
stop_app
defaults delete "$BUNDLE_ID" quitWhenLastWindowCloses

# Cleaned up: no cookie of this run is left in the test copy.
start_app
expect "clean up: nothing is left in the default store" "" "$(cookies)"
close_local_tabs
stop_app
rm -f "$SUPPORT"/Cookies/default.journal
echo
[[ $FAILED -eq 0 ]] && echo "all ok" || { echo "FAILED" >&2; exit 1; }
