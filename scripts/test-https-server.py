#!/usr/bin/env python3
"""A small HTTPS server for scripts/test-server-trust.sh: unlike `openssl s_server -www` it keeps connections alive (HTTP/1.1), so it shows whether
WebKit reuses a connection it was let through on, and it speaks WebSocket over TLS. Standard library only; nothing is written anywhere.

    test-https-server.py <port> <cert.pem> <key.pem>

Every response carries X-Conn, the number of the connection it came on. Paths:
  /            a page titled "ok"
  /conn        the connection number, as text (CORS open)
  /conn-page   a page whose title becomes "conn:<number>" once it has fetched /conn
  /page        a page that fetches /conn, starts a dedicated worker that fetches it too, and opens wss://host/ws; its title ends up "fetch:ok worker:ok ws:ok"
  /worker.js   the worker
  /redir?to=U  a 302 to U
  /hsts        a page sent with Strict-Transport-Security
  /ws          a WebSocket that answers a message with "echo:<message>"
"""
import base64, hashlib, http.server, socketserver, ssl, struct, sys, threading, urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
counter = 0
lock = threading.Lock()

PAGE = b"""<title>waiting</title><script>
const parts = {};
const show = () => document.title = Object.entries(parts).map(([k, v]) => k + ':' + v).join(' ');
fetch('/conn').then(r => r.text()).then(() => { parts.fetch = 'ok'; show(); }, () => { parts.fetch = 'failed'; show(); });
try {
  const w = new Worker('/worker.js');
  w.onmessage = e => { parts.worker = e.data; show(); };
  w.onerror = () => { parts.worker = 'failed'; show(); };
} catch (e) { parts.worker = 'failed'; show(); }
try {
  const s = new WebSocket('wss://' + location.host + '/ws');
  s.onopen = () => s.send('hi');
  s.onmessage = e => { parts.ws = e.data === 'echo:hi' ? 'ok' : 'wrong'; show(); s.close(); };
  s.onerror = () => { if (!parts.ws) parts.ws = 'failed'; show(); };
} catch (e) { parts.ws = 'failed'; show(); }
</script>"""
WORKER = b"fetch('/conn').then(r => r.text()).then(() => postMessage('ok'), () => postMessage('failed'));"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        global counter
        super().setup()
        with lock:
            counter += 1
            self.conn = counter

    def log_message(self, *args):
        pass

    def reply(self, body, kind="text/html", status=200, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Conn", str(self.conn))
        self.send_header("Access-Control-Allow-Origin", "*")
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket()
        if url.path == "/conn":
            return self.reply(str(self.conn).encode(), "text/plain")
        if url.path == "/conn-page":
            return self.reply(b"<title>waiting</title><script>fetch('/conn').then(r => r.text()).then(t => document.title = 'conn:' + t)</script>")
        if url.path == "/page":
            return self.reply(PAGE)
        if url.path == "/worker.js":
            return self.reply(WORKER, "text/javascript")
        if url.path == "/redir":
            target = urllib.parse.parse_qs(url.query).get("to", ["/"])[0]
            return self.reply(b"", "text/plain", 302, [("Location", target)])
        if url.path == "/hsts":
            return self.reply(b"<title>hsts</title>", extra=[("Strict-Transport-Security", "max-age=31536000")])
        return self.reply(b"<title>ok</title>served")

    def websocket(self):
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"] + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        self.close_connection = True
        try:
            head = self.rfile.read(2)
            length = head[1] & 0x7F
            mask = self.rfile.read(4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(self.rfile.read(length)))
            answer = b"echo:" + data
            self.wfile.write(bytes([0x81, len(answer)]) + answer)
            self.wfile.flush()
            self.rfile.read(2)
        except Exception:
            pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    server = Server(("127.0.0.1", port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()
