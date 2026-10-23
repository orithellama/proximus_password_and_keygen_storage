"""Loopback-only HTTP Digest fixture. No blockchain, wallet, or real credentials."""
import hashlib
import http.server
import json
import re


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= 8192:
            self.send_error(400)
            return
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization", "")
        fields = {}
        for key, quoted, plain in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]+))', auth):
            fields[key] = quoted or plain
        md5 = lambda s: hashlib.md5(s.encode()).hexdigest()  # Monero-compatible test challenge only.
        ha1 = md5("fixture:Proximus fixture:fixture")
        ha2 = md5("POST:" + fields.get("uri", ""))
        expected = md5(":".join([ha1, "fixture-nonce", fields.get("nc", ""), fields.get("cnonce", ""), "auth", ha2]))
        if (not auth.startswith("Digest ") or fields.get("username") != "fixture"
                or fields.get("uri") != self.path or fields.get("nonce") != "fixture-nonce"
                or fields.get("qop") != "auth" or fields.get("response") != expected):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Digest realm="Proximus fixture", nonce="fixture-nonce", algorithm=MD5, qop="auth"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        request = json.loads(body)
        if request["method"] != "get_version" or request.get("params") != {}:
            self.send_error(400)
            return
        response = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"version": 65536}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
