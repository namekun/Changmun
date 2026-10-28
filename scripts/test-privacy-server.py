#!/usr/bin/env python3
"""A small web server for scripts/test-privacy-navigation.sh, over http or https. Standard library only; nothing is written anywhere.

    test-privacy-server.py http  <port> [plain-port]
    test-privacy-server.py https <port> <cert.pem> <key.pem> [plain-port]

Every request is printed on its own line ("GET /path?query") so the script can see what reached the server. Paths:
  /echo           a page titled with its own query string
  /redir?to=U     a 302 to U
  /sticky         a 302 to /sticky?utm_source=again (a site that puts a tracking parameter back); /sticky?... is a page titled "sticky"
  /setcookie      sets a SameSite=Strict cookie "sid=1"; /whoami is a page whose request line in the log also says the Cookie and Sec-Fetch-Site it came with
  /xlink?to=U     a page that is one link (id=l) to U covering the whole window; with &csp=1 under a content security policy that allows nothing
  /bounce         over https: a 302 to http://localhost:<plain-port>/bounce (a secure address that sends you back to http); over http: a page titled "bounce-plain"
  /links          a page with a link (id=l) to /echo?utm_source=a&keep=1&fbclid=z
  anything else   a page titled "ok"
"""
import http.server, socketserver, ssl, sys, urllib.parse

kind, port = sys.argv[1], int(sys.argv[2])
if kind == "https":
    cert, key = sys.argv[3], sys.argv[4]
    plain_port = int(sys.argv[5]) if len(sys.argv) > 5 else 0
else:
    cert = key = None
    plain_port = int(sys.argv[3]) if len(sys.argv) > 3 else 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def page(self, title, body="", headers=()):
        data = ("<title>%s</title>%s" % (title, body)).encode()
        self.send_response(200)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == "/whoami":
            print("GET %s cookie=[%s] site=[%s]" % (self.path, self.headers.get("Cookie", ""), self.headers.get("Sec-Fetch-Site", "")), flush=True)
        else:
            print("GET " + self.path, flush=True)
        if url.path == "/setcookie":
            self.page("cookie-set", headers=[("Set-Cookie", "sid=1; Path=/; SameSite=Strict")])
        elif url.path == "/whoami":
            self.page("whoami")
        elif url.path == "/xlink":
            query = urllib.parse.parse_qs(url.query)
            target = query["to"][0].replace("&", "&amp;").replace("'", "&#39;")
            headers = [("Content-Security-Policy", "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'")] if "csp" in query else []
            self.page("xlink", "<a id=l href='%s' style='position:fixed;inset:0;display:block'>go</a>" % target, headers)
        elif url.path == "/echo":
            self.page("q:" + url.query, "<script>document.title = 'q:' + location.search.slice(1)</script>")
        elif url.path == "/redir":
            self.redirect(urllib.parse.parse_qs(url.query)["to"][0])
        elif url.path == "/sticky":
            if "utm_source" in url.query:
                self.page("sticky")
            else:
                self.redirect("/sticky?utm_source=again")
        elif url.path == "/bounce":
            if kind == "https":
                self.redirect("http://localhost:%d/bounce" % plain_port)
            else:
                self.page("bounce-plain")
        elif url.path == "/links":
            self.page("links", "<a id=l href='http://127.0.0.1:%d/echo?utm_source=a&keep=1&fbclid=z'>go</a>" % int(sys.argv[2]))
        else:
            self.page("ok")

    def do_POST(self):
        print("POST " + self.path, flush=True)
        self.page("posted")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


server = Server(("127.0.0.1", port), Handler)
if cert:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
