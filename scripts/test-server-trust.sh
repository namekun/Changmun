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

[[ $FAILED -eq 0 ]] && echo "all passed" || { echo "FAILED" >&2; exit 1; }
