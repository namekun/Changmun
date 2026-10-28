#!/bin/bash
# TLS client certificates, end to end: local openssl servers that demand a client certificate (naming the CA, naming none, naming only an
# intermediate, TLS 1.2), identities in a keychain FILE of the test copy's own (SecKeychainCreate: never in the search list, never the user's keychain,
# deleted afterwards), a test CA trusted for the servers by the test copy, and the chooser answered by the test or, for the sheet cases, the real
# sheet ended as the user's Continue would. Run in Changmun Headless.app, which it starts for each case (and stops after).
#   RSA and EC identities directly below the CA the server names load the page; one below an intermediate does when the intermediate is beside it
#   (it is sent with it); a list that matches nothing still offers the valid identities; the real sheet comes up, is ended by OK and remembered, goes
#   when its tab does, and an untrusted server's warning comes before the sheet.
#
#   scripts/test-client-cert.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
WORK="$(mktemp -d)"
PIDS=()
LIST_BEFORE="$(security list-keychains -d user 2>/dev/null)"

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-client-cert.sh" -H "Content-Type: application/json" --data-binary "$2"
}
# jget '<json>' key.path
jget() { python3 -I -c 'import json, sys
d = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    d = d.get(part) if isinstance(d, dict) else None
print("" if d is None else json.dumps(d) if isinstance(d, (dict, list)) else str(d).lower() if isinstance(d, bool) else d)' "$1" "$2"; }
# The different lists the chooser was given (WebKit may ask more than once for one visit, and again when the site refuses what it got).
asked() { python3 -I -c 'import json, sys
seen = []
for names in json.loads(sys.argv[1])["asked"]:
    if names not in seen: seen.append(names)
print(json.dumps(seen))' "$1"; }
cleanup() {
    post /client-cert '{"reset": true}' >/dev/null 2>&1
    scripts/headless.sh stop >/dev/null 2>&1
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

if pgrep -f "Changmun Headless[.]app/Contents" >/dev/null; then echo "a Changmun Headless is running: stop it first (this test restarts it)" >&2; exit 2; fi

# --- the PKI: a server CA, a client root, an intermediate below it, and clients ---
cd "$WORK"
ca() { # name [issuer]
    openssl genrsa -out "$1.key" 2048 2>/dev/null
    openssl req -new -key "$1.key" -subj "/O=Changmun Test/CN=$1" -out "$1.csr"
    printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n" > "$1.ext"
    if [[ -z "${2:-}" ]]; then openssl x509 -req -in "$1.csr" -signkey "$1.key" -days 30 -extfile "$1.ext" -out "$1.pem" 2>/dev/null
    else openssl x509 -req -in "$1.csr" -CA "$2.pem" -CAkey "$2.key" -CAcreateserial -days 30 -extfile "$1.ext" -out "$1.pem" 2>/dev/null; fi
}
client() { # name rsa|ec issuer
    if [[ $2 == ec ]]; then openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"; else openssl genrsa -out "$1.key" 2048 2>/dev/null; fi
    openssl req -new -key "$1.key" -subj "/O=Changmun Test/CN=$1" -out "$1.csr"
    printf "extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n" > "$1.ext"
    openssl x509 -req -in "$1.csr" -CA "$3.pem" -CAkey "$3.key" -CAcreateserial -days 30 -extfile "$1.ext" -out "$1.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$1.key" -in "$1.pem" -name "$1" -passout pass:pw -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out "$1.p12"
}
ca ServerRoot; ca ClientRoot; ca ClientInter ClientRoot
openssl genrsa -out server.key 2048 2>/dev/null
openssl req -new -key server.key -subj "/CN=localhost" -out server.csr
printf "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n" > server.ext
openssl x509 -req -in server.csr -CA ServerRoot.pem -CAkey ServerRoot.key -CAcreateserial -days 30 -extfile server.ext -out server.pem 2>/dev/null
client rsaDirect rsa ClientRoot; client ecDirect ec ClientRoot; client rsaViaInter rsa ClientInter
[[ -f rsaViaInter.p12 ]] || { echo "openssl failed" >&2; exit 2; }
cd - >/dev/null

port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
SERVE=(openssl s_server -cert "$WORK/server.pem" -key "$WORK/server.key" -Verify 2 -verify_return_error -www)
serve() { local p=$1; shift; "${SERVE[@]}" -accept "$p" "$@" >"$WORK/server-$p.log" 2>&1 & PIDS+=($!); }
NAMED=$(port); UNNAMED=$(port); INTER_ONLY=$(port); TLS12=$(port); UNTRUSTED=$(port)
serve "$NAMED" -CAfile "$WORK/ClientRoot.pem"                                        # names the client root
serve "$UNNAMED" -verifyCAfile "$WORK/ClientRoot.pem"                                # names nobody
serve "$INTER_ONLY" -CAfile "$WORK/ClientInter.pem" -verifyCAfile "$WORK/ClientRoot.pem"   # names only the intermediate
serve "$TLS12" -CAfile "$WORK/ClientRoot.pem" -tls1_2
serve "$UNTRUSTED" -CAfile "$WORK/ClientRoot.pem"                                    # its certificate is of a CA nobody trusts (not given to the app)
sleep 1

FAILED=0
expect() { if [[ "$2" == "$3" ]]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', wanted '$3')" >&2; FAILED=1; fi; }

# fresh <identity files...> [-- certificate files...]: a headless app with a keychain file holding those, trusting the servers but the untrusted one.
fresh() {
    post /client-cert '{"reset": true}' >/dev/null 2>&1
    scripts/headless.sh stop >/dev/null 2>&1
    scripts/headless.sh start >/dev/null 2>&1 || { echo "headless did not start" >&2; exit 1; }
    local ids="" certs="" in_certs=""
    for n in "$@"; do
        if [[ "$n" == -- ]]; then in_certs=1; continue; fi
        if [[ -n "$in_certs" ]]; then certs="$certs\"$WORK/$n.pem\","; else ids="$ids[\"$WORK/$n.p12\",\"pw\"],"; fi
    done
    local problem
    problem="$(post /client-cert "{\"keychain\": {\"path\": \"$WORK/test-$RANDOM.keychain\", \"identities\": [${ids%,}], \"certificates\": [${certs%,}]},
        \"trust\": {\"host\": \"localhost\", \"ports\": [$NAMED, $UNNAMED, $INTER_ONLY, $TLS12], \"anchors\": [\"$WORK/ServerRoot.pem\"]}, \"choose\": \"first\"}")"
    expect "the keychain file is made" "$(jget "$problem" problem)" ""
}
# visit <port> <choice>: opens the address as the user does; the answer says what the tab shows.
visit() {
    post /client-cert "{\"choose\": \"$2\"}" >/dev/null
    VISIT="$(post /server-trust "{\"open\": \"https://localhost:$1/\", \"wait\": ${3:-4000}, \"auth\": true}")"
    EVENTS="$(post /client-cert '{}')"
}
loaded() { [[ "$(jget "$VISIT" url)" == "https://localhost:$1/" && "$(jget "$VISIT" failure)" == "" ]] && echo loaded || echo "not loaded"; }

fresh rsaDirect ecDirect
visit "$NAMED" rsaDirect
expect "an RSA identity below the CA the server names loads the page" "$(loaded "$NAMED")" loaded
expect "the chooser offered both identities of that CA" "$(asked "$EVENTS")" '[["ecDirect", "rsaDirect"]]'
fresh rsaDirect ecDirect
visit "$NAMED" ecDirect
expect "an EC identity loads the page" "$(loaded "$NAMED")" loaded
fresh ecDirect
visit "$TLS12" first
expect "an EC identity over TLS 1.2 loads the page" "$(loaded "$TLS12")" loaded

fresh rsaViaInter -- ClientInter
visit "$NAMED" first
expect "an identity below an intermediate loads for a server that names the root, with the intermediate beside it" "$(loaded "$NAMED")" loaded
expect "which is offered" "$(asked "$EVENTS")" '[["rsaViaInter"]]'
fresh rsaViaInter -- ClientInter
visit "$UNNAMED" first
expect "and for a server that names nobody (the intermediate is sent with it)" "$(loaded "$UNNAMED")" loaded

fresh rsaViaInter
visit "$NAMED" first
expect "an identity whose intermediate is nowhere is still offered to a site that names the root" "$(asked "$EVENTS")" '[["rsaViaInter"]]'

fresh rsaDirect
visit "$INTER_ONLY" first
expect "a list that matches nothing still offers the valid identity" "$(asked "$EVENTS")" '[["rsaDirect"]]'
expect "and the site, which accepts it, loads" "$(loaded "$INTER_ONLY")" loaded

fresh rsaDirect
visit "$NAMED" cancel
expect "cancelling gives the site no certificate, so a site that insists fails" "$(loaded "$NAMED")" "not loaded"

# The real chooser sheet (SFChooseIdentityPanel) on the window, ended as the user's Continue would.
fresh rsaDirect ecDirect
post /client-cert '{"choose": null}' >/dev/null
post /server-trust "{\"open\": \"https://localhost:$NAMED/\", \"auth\": true}" >/dev/null
sleep 5
expect "the sheet comes up on the window" "$(jget "$(post /client-cert '{}')" sheetUp)" true
END="$(post /client-cert '{"sheet": "ok"}')"
sleep 3
VISIT="$(post /server-trust '{}')"; EVENTS="$(post /client-cert '{}')"
expect "Continue answers with the chosen identity and the page loads" "$(loaded "$NAMED")" loaded
expect "the choice is remembered: no second sheet" "$(jget "$EVENTS" sheetUp)" false

fresh rsaDirect ecDirect
post /client-cert '{"choose": null}' >/dev/null
post /server-trust "{\"open\": \"https://localhost:$NAMED/\", \"auth\": true}" >/dev/null
sleep 5
TAB="$(jget "$(post /ui '{}')" active)"
scripts/headless.sh call close_tab "{\"tab_id\": $TAB}" >/dev/null
sleep 2
expect "the sheet goes when its tab is closed" "$(jget "$(post /client-cert '{}')" sheetUp)" false
post /server-trust "{\"open\": \"https://localhost:$NAMED/\", \"auth\": true}" >/dev/null
sleep 5
expect "and the next visit gets a sheet again" "$(jget "$(post /client-cert '{}')" sheetUp)" true

# A server that is untrusted and wants a client certificate: its certificate is judged first, the sheet only after "Visit This Website".
fresh rsaDirect
post /client-cert '{"choose": "first"}' >/dev/null
VISIT="$(post /server-trust "{\"open\": \"https://localhost:$UNTRUSTED/\", \"wait\": 4000, \"auth\": true}")"
expect "an untrusted server shows the warning before any certificate is asked for" "$(jget "$VISIT" failure.reason)" unknownAuthority
expect "and no identity was asked for yet" "$(jget "$(post /client-cert '{}')" asked)" '[]'
VISIT="$(post /server-trust '{"action": "visit", "wait": 4000}')"
expect "after Visit This Website the page loads with the identity" "$(loaded "$UNTRUSTED")" loaded

LIST_AFTER="$(security list-keychains -d user 2>/dev/null)"
expect "the user's keychain search list was not touched" "$LIST_AFTER" "$LIST_BEFORE"
[[ $FAILED -eq 0 ]] && echo "all passed" || { echo "FAILED" >&2; exit 1; }
