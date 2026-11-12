"""Loopback-only App contract fixture. No imports/network calls to any upstream."""
import http.server
import json
import time

ERRORS = {
    "AAAA": (401, "invite_invalid"), "BBBB": (403, "invite_exhausted"),
    "CCCC": (403, "monthly_cap_reached"), "DDDD": (429, "rate_limited"),
    "EEEE": (413, "input_too_long"), "FFFF": (502, "upstream_error"),
}

class Handler(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def check(self):
        auth = self.headers.get("Authorization", "")
        device = self.headers.get("X-StylePolish-Device", "")
        import uuid
        try:
            uuid.UUID(device)
        except ValueError:
            self.reply(400, {"error": {"code": "bad_device"}})
            return None
        if not auth.startswith("Bearer SP-"):
            self.reply(400, {"error": {"code": "author_key_must_never_arrive"}})
            return None
        mode = auth.split("-")[1]
        self.requests.append({"method": self.command, "path": self.path, "authorization": auth, "device": device})
        return mode

    def error(self, mode):
        if mode not in ERRORS:
            return False
        status, code = ERRORS[mode]
        self.reply(status, {"error": {"code": code, "message": "UNTRUSTED server body " + self.headers["Authorization"]}})
        return True

    def do_GET(self):
        if self.path == "/stats":
            self.reply(200, self.requests)
            return
        mode = self.check()
        if mode is None:
            return
        if not self.path.endswith("/v1/invite"):
            self.reply(404, {})
            return
        if self.path.startswith("/slow/"):
            time.sleep(.3)
        if not self.path.startswith("/post/") and self.error(mode):
            return
        if mode == "MMMM":
            self.reply(200, {"status": "active", "remaining_percent": 101})
        elif mode == "KKKK":
            self.reply(200, {"status": "revoked", "remaining_percent": 92})
        elif mode == "JJJJ":
            self.reply(200, {"status": "exhausted", "remaining_percent": 0})
        else:
            self.reply(200, {"status": "active", "remaining_percent": 9 if mode == "HHHH" else 92})

    def do_POST(self):
        mode = self.check()
        if mode is None:
            return
        if not self.path.endswith("/v1/chat/completions"):
            self.reply(404, {})
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        # Keep the input and successful output in sync with InviteTests. The local
        # fallback only corrects 因该 after a standalone personal pronoun.
        if body.get("stream") is not True or body["messages"][-1]["content"] != "我因该回复。":
            self.reply(400, {})
            return
        if self.error(mode):
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        text = json.dumps({"text": "我应该回复。", "edits": [{"original": "因该", "replacement": "应该", "kind": "typo", "why": "错字"}]}, ensure_ascii=False)
        for part in [text[:15], text[15:]]:
            chunk = {"choices": [{"delta": {"content": part}}]}
            self.wfile.write(("data: " + json.dumps(chunk, ensure_ascii=False) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":8,"total_tokens":20}}\n\ndata: [DONE]\n\n')
        self.wfile.flush()

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
