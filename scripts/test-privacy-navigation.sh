#!/bin/bash
# Removing tracking from links and preferring secure connections, end to end: local servers (python, scripts/test-privacy-server.py) loaded in
# Changmun Headless.app as the user does:
#   tracking parameters are taken out of a typed address, a link opened in a new tab and the AI's navigate; everything else in the address stays;
#   nothing with a tracking parameter reaches the server from those; what the page does itself (a link pressed in it, a script's click, a redirect, a
#   form) is loaded as the site wrote it, and a pressed cross-site link is what it would be without the feature (no SameSite=Strict cookie,
#   Sec-Fetch-Site: cross-site, rel=noreferrer and target=_blank working); the setting and a site's switch turn it off;
#   an http address of a loopback host stays http; a host standing in for a public one (the test copy's override) is tried over https first,
#   falls back to http when nothing answers there (and is not tried again), and when the secure server's certificate can't be verified shows
#   the certificate warning and NEVER loads the page over http; a secure address that redirects to http is the site's own redirect and loads;
#   the AI's read_markdown hands over a page's links without tracking parameters, and read_structured its meta data.
# Nothing outside a temporary folder and the headless app is touched. Starts the headless app if it isn't running (and stops it again then).
#
#   scripts/test-privacy-navigation.sh
set -uo pipefail
cd "$(dirname "$0")/.."
ENDPOINT="${CHANGMUN_HEADLESS_ENDPOINT:-$HOME/Library/Application Support/Changmun Headless/control.json}"
WORK="$(mktemp -d)"
STARTED=""
PIDS=()

field() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ENDPOINT" "$1"; }
post() {
    curl -sf -X POST "http://127.0.0.1:$(field port)$1" -H "Authorization: Bearer $(field token)" \
        -H "X-Changmun-Caller: test-privacy-navigation.sh" -H "Content-Type: application/json" --data-binary "$2"
}
# jget '<json>' <field>: a field of an answer ("failure.reason" and so on), empty when there is none.
jget() { python3 -I -c 'import json, sys; d = json.loads(sys.argv[1])
for part in sys.argv[2].split("."):
    d = d.get(part) if isinstance(d, dict) else None
print("" if d is None else json.dumps(d) if isinstance(d, (dict, list)) else str(d).lower() if isinstance(d, bool) else d)' "$1" "$2"; }
# open <address> [wait ms]: loads the address in a new tab as the user does, and answers what the tab shows.
open_tab() { post /server-trust "{\"open\": \"$1\", \"wait\": ${2:-2500}}"; }
state() { post /server-trust '{}'; }
privacy() { post /privacy "$1" >/dev/null; }

cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
    post /privacy '{"tracking": true, "https": true, "keptHosts": [], "override": null, "forgetPlainHosts": true}' >/dev/null 2>&1
    post /server-trust '{"exceptions": "clear"}' >/dev/null 2>&1
    [[ -z "$STARTED" ]] || scripts/headless.sh stop >/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

port() { python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# A CA and a certificate for localhost it signed (the test copy trusts that CA for one port), and a self-signed certificate for localhost.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" -days 30 -subj "/CN=Changmun Privacy Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null || { echo "openssl failed" >&2; exit 2; }
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/leaf.key" -out "$WORK/leaf.csr" -subj "/CN=localhost" 2>/dev/null
printf "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n" > "$WORK/leaf.ext"
openssl x509 -req -in "$WORK/leaf.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" -CAcreateserial -days 10 -extfile "$WORK/leaf.ext" -out "$WORK/leaf.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/self.key" -out "$WORK/self.pem" -days 30 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost" -addext "extendedKeyUsage=serverAuth" 2>/dev/null

HTTP=$(port); HTTP2=$(port); GOOD=$(port); SELF=$(port); CLOSED=$(port)
python3 -I scripts/test-privacy-server.py http "$HTTP" "$HTTP" > "$WORK/http.log" & PIDS+=($!)
python3 -I scripts/test-privacy-server.py http "$HTTP2" "$HTTP2" > "$WORK/http2.log" & PIDS+=($!)
python3 -I scripts/test-privacy-server.py https "$GOOD" "$WORK/leaf.pem" "$WORK/leaf.key" "$HTTP" > "$WORK/good.log" & PIDS+=($!)
python3 -I scripts/test-privacy-server.py https "$SELF" "$WORK/self.pem" "$WORK/self.key" "$HTTP" > "$WORK/self.log" & PIDS+=($!)
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
requests() { grep -c "$2" "$WORK/$1.log"; }

privacy '{"tracking": true, "https": true, "keptHosts": [], "override": null, "forgetPlainHosts": true}' || { echo "no /privacy: is the headless app of this build?" >&2; exit 2; }
post /client-cert "{\"trust\": {\"host\": \"localhost\", \"ports\": [$GOOD], \"anchors\": [\"$WORK/ca.pem\"]}}" >/dev/null
post /server-trust '{"exceptions": "clear", "auth": true}' >/dev/null

L="http://127.0.0.1:$HTTP"

# A real click on the page's one link (it covers the window), as the window server would deliver it.
# The headless window is never key, so the events go straight to the view under the point (as a click in a window that is key would).
click_link() {
    post /window-event '{"type": "down", "x": 500, "y": 200, "direct": true}' >/dev/null
    post /window-event '{"type": "up", "x": 500, "y": 200, "direct": true}' >/dev/null
    sleep "${1:-2.5}"
}
# The last request line the server saw for a path, and the part of it after the path.
last() { grep "GET $2" "$WORK/$1.log" | tail -1; }
XSITE="http://localhost:$HTTP"      # a page on 127.0.0.1 linking here is a cross-site link

echo "-- Remove tracking from links"
R="$(open_tab "$L/echo?utm_source=a&keep=1&fbclid=z&utm_medium=m&Q=%20x#frag")"
expect "a typed address loses its tracking parameters, the rest stays as it was written" "$(jget "$R" webViewURL)" "$L/echo?keep=1&Q=%20x#frag"
expect "and the page was asked for without them" "$(requests http 'utm_source')" 0
expect "a loopback address stays http" "$(jget "$R" webViewURL | cut -c1-5)" "http:"

R="$(open_tab "$L/echo?gclid=1&utm_campaign=c")"
expect "an address with only tracking parameters loses its question mark" "$(jget "$R" webViewURL)" "$L/echo"
R="$(open_tab "$L/echo?keep=1&sub=2")"
expect "an address with none is left alone" "$(jget "$R" webViewURL)" "$L/echo?keep=1&sub=2"

R="$(open_tab "$L/echo?utm_source=a&n=1" 2500)"
expect "a link opened in a new tab is cleaned" "$(jget "$R" webViewURL)" "$L/echo?n=1"

# The AI's tools load an address the same way.
scripts/headless.sh call navigate "{\"url\": \"$L/echo?ttclid=1&ai=1\"}" >/dev/null
sleep 1.5
expect "an address the AI opens is cleaned" "$(jget "$(state)" webViewURL)" "$L/echo?ai=1"

# The AI's reading tools hand the page's links over without tracking parameters (the app's own list), and its facts as JSON.
HTML="<title>Reads</title><head><meta name='description' content='E2E description'><script type='application/ld+json'>{\"@type\":\"Product\",\"name\":\"E2E teapot\"}</script></head><body><main><h1>Heading</h1><p>See <a href='/docs?utm_source=a&amp;keep=1&amp;fbclid=z#top'>the docs</a> and this table.</p><table><tr><th>K</th><th>V</th></tr><tr><td>a</td><td>1</td></tr></table></main></body>"
post /load-html "$(python3 -I -c 'import json, sys; print(json.dumps({"html": sys.argv[1], "base": "https://lab.test/"}))' "$HTML")" >/dev/null
sleep 1.5
answer() { scripts/headless.sh call "$1" '{}' | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["content"][0]["text"])'; }
MD="$(answer read_markdown)"
expect "read_markdown gives a link without its tracking parameters, with the rest and the fragment" "$(grep -c -F '[the docs](https://lab.test/docs?keep=1#top)' <<<"$MD")" 1
expect "read_markdown leaves no tracking parameter in the answer" "$(grep -c -E 'utm_source|fbclid' <<<"$MD")" 0
expect "read_markdown gives a table as a pipe table and a heading as a heading" "$(grep -c -E '^(# Heading|\| K \| V \|)$' <<<"$MD")" 2
SD="$(answer read_structured)"
expect "read_structured gives the page's meta data and JSON-LD as JSON" "$(grep -c -F -e '"description":"E2E description"' -e 'E2E teapot' <<<"$SD")" 1

# What the page does itself is the page's: a redirect and a script's navigation are loaded as they are.
R="$(open_tab "$L/redir?to=$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$L/echo?msclkid=9&k=2")" 3500)"
expect "a redirect is loaded as the site sent it" "$(jget "$R" webViewURL)" "$L/echo?msclkid=9&k=2"
BEFORE="$(requests http 'GET /sticky')"
R="$(open_tab "$L/sticky" 3500)"
expect "a site that puts the parameter back is not fought over (it loads)" "$(jget "$R" title)" sticky
expect "with two requests" "$(( $(requests http 'GET /sticky') - BEFORE ))" 2
# A page whose own script clicks its link as it loads (a click with no user behind it) is not the user's: that link is loaded as it is.
post /load-html "{\"html\": \"<a id=l href='$XSITE/echo?utm_source=a&s=1'>go</a><script>window.onload = () => document.getElementById('l').click()</script>\", \"base\": \"https://lab.test/\"}" >/dev/null
sleep 2.5
R="$(state)"
expect "a click the page's own script makes is loaded as it is" "$(jget "$R" webViewURL)" "$XSITE/echo?utm_source=a&s=1"
R="$(open_tab "$L/xlink?to=x" 1000)"
R="$(post /server-trust "{\"eval\": \"location.href = '$L/echo?fbclid=1&s=2'\", \"wait\": 2500}")"
expect "and so is a script's navigation" "$(jget "$R" webViewURL)" "$L/echo?fbclid=1&s=2"

# A link the user presses in a page is the page's: it is loaded as the site wrote it, so it is exactly what it would be without the feature (the site
# sees a cross-site navigation: no SameSite=Strict cookie, Sec-Fetch-Site: cross-site; rel=noreferrer and target=_blank work).
enc() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
open_tab "$XSITE/setcookie" 1500 >/dev/null
expect "(a SameSite=Strict cookie is set for the site)" "$(jget "$(state)" title)" cookie-set
open_tab "$XSITE/whoami" 1500 >/dev/null
expect "(typed by the user, the site gets its Strict cookie, and no initiator)" "$(last http '/whoami' | cut -d' ' -f1-4)" "GET /whoami cookie=[sid=1] site=[none]"
N=0
for extra in "" "&csp=1" "&noref=1" "&blank=1"; do
    N=$((N + 1))
    open_tab "$L/xlink?to=$(enc "$XSITE/whoami?utm_source=a&k=$N")$extra" 1500 >/dev/null
    TABS="$(jget "$(state)" tabs)"
    click_link
    LINE="$(last http "/whoami?utm_source=a&k=$N")"
    expect "a pressed cross-site link${extra:+ ($extra)} is loaded as the site wrote it, cross-site, with no Strict cookie" "$(cut -d' ' -f1-4 <<<"$LINE")" "GET /whoami?utm_source=a&k=$N cookie=[] site=[cross-site]"
    case "$extra" in
        "&noref=1") expect "rel=noreferrer keeps the Referer away" "${LINE##* }" "referer=[]" ;;
        "&blank=1") expect "target=_blank opens the page in a new tab" "$(( $(jget "$(state)" tabs) - TABS ))" 1 ;;
        *) expect "the Referer is the page's, as it would be" "${LINE##* }" "referer=[$L/]" ;;
    esac
done

privacy '{"tracking": false}'
R="$(open_tab "$L/echo?utm_source=a&keep=1")"
expect "with the setting off nothing is taken out" "$(jget "$R" webViewURL)" "$L/echo?utm_source=a&keep=1"
privacy '{"tracking": true, "keptHosts": ["127.0.0.1"]}'
R="$(open_tab "$L/echo?utm_source=a&keep=1")"
expect "a site that keeps its parameters keeps them" "$(jget "$R" webViewURL)" "$L/echo?utm_source=a&keep=1"
privacy '{"keptHosts": []}'
R="$(open_tab "$L/echo?utm_source=a&keep=1")"
expect "and is cleaned again when the switch is on" "$(jget "$R" webViewURL)" "$L/echo?keep=1"

# A form is not changed: a POST is not loaded twice, and a form's own parameters are the form's.
R="$(post /load-html "{\"html\": \"<form id=f method=post action='$L/echo?utm_source=a'><input name=x value=1></form><script>document.getElementById('f').submit()</script>\", \"base\": \"https://lab.test/\"}")"
sleep 2
expect "a form that sends data is sent once" "$(requests http 'POST /echo')" 1
expect "and its address is as the page wrote it" "$(grep 'POST /echo' "$WORK/http.log")" "POST /echo?utm_source=a"

echo "-- Prefer secure connections"
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $GOOD}, \"forgetPlainHosts\": true}"
R="$(open_tab "http://localhost:$HTTP/echo?x=1" 3500)"
expect "an http address of a public host is tried over https first" "$(jget "$R" webViewURL)" "https://localhost:$GOOD/echo?x=1"
expect "the page is the secure server's, with no warning and a lock" "$(jget "$R" failure)$(jget "$R" unverified)" "false"
expect "the plain server was not asked" "$(requests http 'GET /echo?x=1')" 0

R="$(open_tab "http://localhost:$HTTP/echo?utm_source=a&x=2" 3500)"
expect "tracking and https together: both" "$(jget "$R" webViewURL)" "https://localhost:$GOOD/echo?x=2"

R="$(open_tab "http://127.0.0.1:$HTTP/echo?x=3" 3000)"
expect "a loopback address stays http though a host stands in for a public one" "$(jget "$R" webViewURL)" "http://127.0.0.1:$HTTP/echo?x=3"
R="$(open_tab "http://localhost:$HTTP2/echo?x=4" 3000)"
expect "an address with another port is left as it is" "$(jget "$R" webViewURL)" "http://localhost:$HTTP2/echo?x=4"

privacy '{"https": false}'
R="$(open_tab "http://localhost:$HTTP/echo?x=5" 3000)"
expect "with the setting off an http address stays http" "$(jget "$R" webViewURL)" "http://localhost:$HTTP/echo?x=5"
privacy '{"https": true}'

# Nothing answers over https: http, once, and not tried again for the host.
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $CLOSED}, \"forgetPlainHosts\": true}"
R="$(open_tab "http://localhost:$HTTP/echo?utm_source=a&x=6" 4000)"
expect "a site that isn't there over https loads over http" "$(jget "$R" webViewURL)" "http://localhost:$HTTP/echo?x=6"
expect "with no error page" "$(jget "$R" title)" "q:x=6"
expect "and the host is remembered for the run" "$(jget "$(post /privacy '{}')" plainHosts)" '["localhost"]'
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $GOOD}}"
R="$(open_tab "http://localhost:$HTTP/echo?x=7" 3000)"
expect "a host that was found not to speak https is not tried again" "$(jget "$R" webViewURL)" "http://localhost:$HTTP/echo?x=7"
expect "and the address bar does not show a lock" "$(jget "$R" webViewURL | cut -c1-5)" "http:"
privacy '{"forgetPlainHosts": true}'

# A certificate that can't be verified: the warning, never the page over http.
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $SELF}}"
BEFORE="$(requests http 'GET /echo?x=8')"
R="$(open_tab "http://localhost:$HTTP/echo?x=8" 4000)"
expect "a certificate that can't be verified shows the warning" "$(jget "$R" failure.reason)" selfSigned
expect "for the secure address" "$(jget "$R" failure.address)" "https://localhost:$SELF/echo?x=8"
expect "the page is not loaded over http" "$(( $(requests http 'GET /echo?x=8') - BEFORE ))" 0
expect "and the host is not remembered as plain" "$(jget "$(post /privacy '{}')" plainHosts)" '[]'
sleep 6
R="$(state)"
expect "not later either" "$(( $(requests http 'GET /echo?x=8') - BEFORE ))" 0
expect "and the warning is still up" "$(jget "$R" failure.reason)" selfSigned

# A link pressed in a page is the page's: an http link stays http (no cancel and load again by the app, which would lose what the site sees of the click).
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $GOOD}, \"forgetPlainHosts\": true}"
open_tab "$L/xlink?to=$(enc "http://localhost:$HTTP/echo?utm_source=a&c=1")" 1500 >/dev/null
click_link 3
expect "a pressed http link is loaded as the page wrote it" "$(jget "$(state)" webViewURL)" "http://localhost:$HTTP/echo?utm_source=a&c=1"

# A secure address that redirects to http is the site's own redirect: it loads (the app does not send the page back to https behind the site's back).
privacy "{\"override\": {\"hosts\": [\"localhost\"], \"plain\": $HTTP, \"secure\": $GOOD}, \"forgetPlainHosts\": true}"
R="$(open_tab "http://localhost:$HTTP/bounce" 4500)"
expect "a redirect from https to http is loaded as the site sent it" "$(jget "$R" title)" "bounce-plain"

[[ $FAILED -eq 0 ]] && echo "all passed" || { echo "FAILED" >&2; exit 1; }
