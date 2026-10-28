#!/bin/bash
# A site whose own certificate can't be verified, end to end: local openssl servers with a self-signed certificate and with a certificate of a
# private CA the Mac doesn't trust, loaded in Changmun Headless.app as the user does (the test copy stands in for Touch ID):
#   the page fails with -1202 and the app's warning says why (self-signed, unknown authority, other name);
#   "Visit This Website" with a refused confirmation changes nothing, with an accepted one loads the page and marks the address bar;
#   a second tab to the site loads without the warning, a page the AI drives does not load, a swapped certificate is blocked again (as changed),
#   and an exception taken away blocks the page again.
# Nothing outside a temporary folder and the headless app is touched: no keychain, no trust setting. Starts the headless app if it isn't
# running (and stops it again then).
#
#   scripts/test-server-trust.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
WORK="$(mktemp -d)"
STARTED=""
PIDS=()

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-server-trust.sh" -H "Content-Type: application/json" --data-binary "$2"
}
# trust '<json>' <field>: what the tab in front shows after the request ("failure.reason" and so on).
trust() { post /server-trust "$1" | python3 -I -c 'import json, sys; d = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    d = d.get(part) if isinstance(d, dict) else None
print("" if d is None else json.dumps(d) if isinstance(d, (dict, list)) else str(d).lower() if isinstance(d, bool) else d)' "$2"; }

cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
    post /server-trust '{"exceptions": "clear"}' >/dev/null 2>&1
    [[ -z "$STARTED" ]] || scripts/headless.sh stop >/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
serve() { openssl s_server -accept "$1" -cert "$2" -key "$3" -www >"$WORK/server-$1.log" 2>&1 & PIDS+=($!); }

# Two self-signed certificates for localhost, and a server certificate of a CA that no Mac trusts.
for name in selfA selfB; do
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/$name.key" -out "$WORK/$name.pem" -days 30 -subj "/CN=localhost" \
        -addext "subjectAltName=DNS:localhost" -addext "extendedKeyUsage=serverAuth" 2>/dev/null || { echo "openssl failed" >&2; exit 2; }
done
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -days 30 -subj "/CN=Changmun Test Private CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/leaf.key" -out "$WORK/leaf.csr" -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n" > "$WORK/leaf.ext"
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial -days 10 -extfile "$WORK/leaf.ext" -out "$WORK/leaf.pem" 2>/dev/null

SELF=$(port); PRIVATE=$(port)
serve "$SELF" "$WORK/selfA.pem" "$WORK/selfA.key"; SELF_PID=$!
serve "$PRIVATE" "$WORK/leaf.pem" "$WORK/leaf.key"
# Keep-alive HTTPS servers (HTTP/1.1, WebSocket) with the first self-signed certificate: s_server closes after each page, which hides connection reuse.
KA1=$(port); KA2=$(port)
for p in "$KA1" "$KA2"; do python3 -I scripts/test-https-server.py "$p" "$WORK/selfA.pem" "$WORK/selfA.key" & PIDS+=($!); done
sleep 1

if pgrep -f "Changmun Headless[.]app/Contents" >/dev/null && [[ ! -f "$ENDPOINT" ]]; then echo "another Changmun Headless is running without an endpoint" >&2; exit 2; fi
if ! scripts/headless.sh call list_tabs >/dev/null 2>&1; then
    scripts/headless.sh start >/dev/null || exit 1
    STARTED=1
fi

FAILED=0
expect() { # what, got, wanted
    if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', wanted '$3')" >&2; FAILED=1; fi
}
# What was seen where nothing is asserted: WebKit behaviour that can't be changed, reported as it is.
info() { echo "info: $1: $2"; }

post /server-trust '{"exceptions": "clear", "auth": true}' >/dev/null || { echo "no /server-trust: is the headless app of this build?" >&2; exit 2; }

R="$(trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3000}" failure.reason)"
expect "a self-signed certificate is said to be self-signed" "$R" selfSigned
expect "the error is -1202" "$(trust '{}' failure.code)" -1202
R="$(trust "{\"open\": \"https://localhost:$PRIVATE/\", \"wait\": 3000}" failure.reason)"
expect "a certificate of an authority the Mac doesn't trust says so" "$R" unknownAuthority
R="$(trust "{\"open\": \"https://127.0.0.1:$SELF/\", \"wait\": 3000}" failure.reason)"
expect "a certificate for another name says so" "$R" nameMismatch

trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3000, \"auth\": false}" failure.reason >/dev/null
R="$(trust '{"action": "visit"}' failure.reason)"
expect "a refused confirmation keeps the warning" "$R" selfSigned
expect "and makes no exception" "$(trust '{}' usesException)" false

R="$(trust '{"auth": true, "action": "visit"}' failure)"
expect "an accepted confirmation takes the warning away" "$R" ""
expect "the address bar marks the exception" "$(trust '{}' usesException)" true
expect "the page is the site's" "$(trust '{}' url)" "https://localhost:$SELF/"

trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3500}" failure >/dev/null
expect "a second tab to the site loads with no warning" "$(trust '{}' failure)$(trust '{}' url)" "https://localhost:$SELF/"

# The AI's tools mark their tab as the AI's: the exception does not apply to it, and it is offered none.
scripts/headless.sh call navigate "{\"url\": \"https://localhost:$SELF/\"}" >/dev/null
sleep 2
expect "a page the AI drives is not let through" "$(trust '{}' url)" "about:blank"
expect "and gets no warning to go on from" "$(trust '{}' failure)" ""

# The same address with another certificate.
kill "$SELF_PID" 2>/dev/null; wait "$SELF_PID" 2>/dev/null; sleep 0.5
serve "$SELF" "$WORK/selfB.pem" "$WORK/selfB.key"; SELF_PID=$!; sleep 1
R="$(trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3500}" failure.changed)"
expect "another certificate for the same site is blocked, as changed" "$R" true
kill "$SELF_PID" 2>/dev/null; wait "$SELF_PID" 2>/dev/null; sleep 0.5
serve "$SELF" "$WORK/selfA.pem" "$WORK/selfA.key"; SELF_PID=$!; sleep 1
trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3500}" failure >/dev/null
expect "the certificate that was accepted loads again" "$(trust '{}' failure)$(trust '{}' url)" "https://localhost:$SELF/"

R="$(trust '{"action": "revoke"}' failure.reason)"
expect "an exception taken away blocks the page again" "$R" selfSigned
expect "and the address bar stops marking it" "$(trust '{}' usesException)" false

# A subresource of a page that is fine, from a host the user went on with earlier and no longer has an exception for: it fails, and the page gets no warning
# (the warning is for the page being loaded, not for what it pulls in).
post /load-html "{\"html\": \"<title>waiting</title><script>fetch('https://localhost:$SELF/x', {mode: 'no-cors'}).then(() => document.title = 'loaded', () => document.title = 'failed')</script>\", \"base\": \"https://lab.test/\"}" >/dev/null
sleep 3
expect "a subresource from a host that has no exception now fails" "$(trust '{}' title)" failed
expect "and brings no warning over the page" "$(trust '{}' failure)" ""

# Another store: WebKit keeps what it was told to go on with for the whole run, so what was accepted in the default store must not carry over to a profile.
trust '{"auth": true}' failure >/dev/null
trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3000}" failure >/dev/null
trust '{"auth": true, "action": "visit"}' failure >/dev/null
expect "the exception is made in the default store" "$(trust '{}' usesException)" true
post /spaces '{"action": "create", "name": "Trust test", "profile": true}' >/dev/null
R="$(trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3500}" failure.reason)"
expect "a profile space is warned though another store went on" "$R" selfSigned
expect "and has no exception" "$(trust '{}' usesException)" false
post /spaces '{"action": "delete", "name": "Trust test"}' >/dev/null

# ---- Keep-alive HTTPS (what WebKit does with a connection it was let through on), and the places an exception must not reach ----
trust '{"exceptions": "clear", "auth": true}' failure >/dev/null
R="$(trust "{\"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3000}" failure.reason)"
expect "a keep-alive server with a self-signed certificate is warned about" "$R" selfSigned
expect "the warning names the host and port, not trimmed" "$(trust '{}' failure.hostAndPort)" "localhost:$KA1"
expect "and the whole address" "$(trust '{}' failure.address)" "https://localhost:$KA1/conn-page"
trust '{"action": "visit", "wait": 3500}' failure >/dev/null
CONN_FIRST="$(trust '{}' title)"
expect "it loads after Visit This Website" "${CONN_FIRST%%:*}" conn
trust "{\"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3500}" failure >/dev/null
CONN_SECOND="$(trust '{}' title)"
info "the connection a second tab gets (first $CONN_FIRST)" "$CONN_SECOND"

# Taken away while the connection is warm: the reload has to be judged again.
R="$(trust '{"action": "revoke", "wait": 3500}' failure.reason)"
expect "an exception taken away blocks a reload though the connection was kept alive" "$R" selfSigned
info "the page left running behind that warning (should be empty)" "$(trust '{"eval": "document.body ? document.body.innerText.length : 0"}' result)"
info "address of the page behind it" "$(trust '{}' webViewURL)"
info "can go back" "$(trust '{}' canGoBack)"

# Same host, another port; the same address by another name.
trust '{"auth": true, "action": "visit", "wait": 3500}' failure >/dev/null
R="$(trust "{\"open\": \"https://localhost:$KA2/conn-page\", \"wait\": 3000}" failure.reason)"
expect "the same host on another port is warned about" "$R" selfSigned
R="$(trust "{\"open\": \"https://127.0.0.1:$KA1/conn-page\", \"wait\": 3000}" failure.reason)"
expect "the same address by another name (127.0.0.1) is warned about, for its name" "$R" nameMismatch

# A private window has its own exceptions and its own WebKit session.
trust '{"private": "open", "wait": 1500}' failure >/dev/null
R="$(trust "{\"in\": \"private\", \"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3500}" failure.reason)"
expect "a private window is warned about a site another window went on with" "$R" selfSigned
expect "and has no exception of its own" "$(trust '{"in": "private"}' usesException)" false
trust '{"in": "private", "auth": true, "action": "visit", "wait": 3500}' failure >/dev/null
expect "going on in the private window loads the page there" "$(trust '{"in": "private"}' usesException)" true
trust '{"private": "close", "wait": 1000}' failure >/dev/null

# Subresources, workers and WebSockets to the excepted host and to another port, from a page of another origin.
cat > "$WORK/probe.html" <<'HTML'
<title>waiting</title><script>
const out = {};
const show = () => document.title = Object.entries(out).map(([k, v]) => k + ':' + v).join(' ');
fetch('https://localhost:@/conn', {mode: 'no-cors'}).then(() => out.fetch = 'ok', () => out.fetch = 'failed').then(show);
try {
  const w = new Worker(URL.createObjectURL(new Blob(["fetch('https://localhost:@/conn', {mode: 'no-cors'}).then(() => postMessage('ok'), () => postMessage('failed'))"])));
  w.onmessage = e => { out.worker = e.data; show(); };
  w.onerror = () => { out.worker = 'failed'; show(); };
} catch (e) { out.worker = 'failed'; show(); }
try {
  const s = new WebSocket('wss://localhost:@/ws');
  s.onopen = () => { out.ws = 'ok'; show(); s.close(); };
  s.onerror = () => { out.ws = 'failed'; show(); };
} catch (e) { out.ws = 'failed'; show(); }
</script>
HTML
# Loads a page of another origin (https://lab.test/) with the file's text, "@" standing for the port.
FROM_LAB() { post /load-html "$(python3 -I -c 'import json, sys; print(json.dumps({"html": open(sys.argv[1]).read().replace("@", sys.argv[2]), "base": "https://lab.test/"}))' "$1" "$2")" >/dev/null; sleep 4.5; }
FROM_LAB "$WORK/probe.html" "$KA1"
info "from another origin, to the excepted host: fetch, worker and wss" "$(trust '{}' title)"
FROM_LAB "$WORK/probe.html" "$KA2"
T="$(trust '{}' title)"
info "from another origin, to the same host on a port with no exception" "$T"
expect "none of fetch, worker and wss reaches a port with no exception" "$(grep -c ok <<<"${T// /$'\n'}")" 0
trust "{\"open\": \"https://localhost:$KA1/page\", \"wait\": 4500}" failure >/dev/null
info "the excepted site's own page: fetch, its worker and wss" "$(trust '{}' title)"

# A page of the AI's, when the connection is warm.
scripts/headless.sh call navigate "{\"url\": \"https://localhost:$KA1/conn-page\"}" >/dev/null
sleep 2
expect "a page the AI drives is still not let through when the connection is warm" "$(trust '{}' webViewURL)" "about:blank"

# Into an excepted host by a link and by a redirect: the address bar and the page's rules follow the page that committed, not the one before it.
trust '{"auth": true, "exceptions": "clear"}' failure >/dev/null
R="$(trust "{\"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3000}" failure.reason)"
expect "with its exception cleared the site is warned about again, though WebKit has a connection kept alive for it" "$R" selfSigned
trust '{"action": "visit", "wait": 3500}' failure >/dev/null
trust "{\"open\": \"https://localhost:$KA2/conn-page\", \"wait\": 3000}" failure >/dev/null
trust '{"action": "visit", "wait": 3500}' failure >/dev/null
post /load-html "{\"html\": \"<a id=l href='https://localhost:$KA1/conn-page'>go</a>\", \"base\": \"https://lab.test/\"}" >/dev/null
expect "the page before is not an exception" "$(trust '{}' usesException)" false
trust '{"eval": "document.getElementById(\"l\").click()", "wait": 3500}' failure >/dev/null
expect "a click on a link into an excepted host marks the address bar" "$(trust '{}' usesException)" true
expect "and the page is that host's" "$(trust '{}' webViewURL)" "https://localhost:$KA1/conn-page"
# The warning over a page that was live: nothing runs under it, and Go Back is one step.
trust '{"action": "revoke", "wait": 3000}' failure >/dev/null
expect "an exception taken away puts the warning over the page" "$(trust '{}' failure.host)" localhost
expect "and nothing is left running under it" "$(trust '{}' webViewURL)" "about:blank"
expect "Go Back from it is one step, to the page before (the page it replaced is not in the history)" "$(trust '{"action": "back", "wait": 2500}' webViewURL)" "https://localhost:$KA2/conn-page"
trust "{\"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3000}" failure >/dev/null
trust '{"action": "visit", "wait": 3500}' failure >/dev/null
trust "{\"open\": \"https://localhost:$KA1/redir?to=https://localhost:$KA2/conn-page\", \"wait\": 3500}" failure >/dev/null
expect "a redirect into another excepted host lands on its page" "$(trust '{}' webViewURL)" "https://localhost:$KA2/conn-page"
expect "and marks the address bar" "$(trust '{}' usesException)" true
expect "the lock is not shown (the page is unverified)" "$(trust '{}' unverified)" true
post /load-html "{\"html\": \"<a id=l href='https://localhost:$KA2/conn-page'>go</a>\", \"base\": \"https://lab.test/\"}" >/dev/null
expect "a page with no exception is not marked" "$(trust '{}' unverified)" false

# One question at a time: a second press while the Mac's owner is asked does not ask again.
trust '{"exceptions": "clear"}' failure >/dev/null
trust "{\"open\": \"https://localhost:$SELF/\", \"wait\": 3000}" failure >/dev/null
BEFORE="$(trust '{}' authAsked)"
trust '{"auth": true, "authDelay": 1500, "action": "visit", "visits": 3, "wait": 3000}' failure >/dev/null
expect "three presses ask once" "$(( $(trust '{}' authAsked) - BEFORE ))" 1
trust '{"authDelay": 0}' failure >/dev/null

# A certificate that was fine and is not: this host is also "trusted earlier" for the Mac; the policy itself is unit-tested (ServerTrustPolicyTests).

# A frame in a page: the same stop as for a page (a connection kept alive would otherwise carry it), and a frame that is let through makes the page unverified.
cat > "$WORK/frame.html" <<'HTML'
<title>waiting</title><script>
window.onmessage = e => document.title = String(e.data);
</script>
<iframe src="https://localhost:@/frame-page"></iframe>
HTML
trust '{"auth": true, "exceptions": "clear"}' failure >/dev/null
trust "{\"open\": \"https://localhost:$KA1/conn-page\", \"wait\": 3000}" failure >/dev/null
trust '{"action": "visit", "wait": 3500}' failure >/dev/null
FROM_LAB "$WORK/frame.html" "$KA1"
expect "a frame on a host with an exception loads" "$(trust '{}' title)" framed
expect "and makes the page unverified (no saved login, no remembered permission, the AI asks first)" "$(trust '{}' unverified)" true
trust '{"exceptions": "clear"}' failure >/dev/null
FROM_LAB "$WORK/frame.html" "$KA1"
expect "with the exception gone the frame is stopped, though the connection is kept alive" "$(trust '{}' title)" waiting
expect "silently: no warning over the page" "$(trust '{}' failure)" ""
expect "and the page is not unverified for a frame that never loaded" "$(trust '{}' unverified)" false

[[ $FAILED -eq 0 ]] && echo "all passed" || { echo "FAILED" >&2; exit 1; }
