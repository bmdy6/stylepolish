#!/usr/bin/env python3
"""Local synthetic SSE fixture. No external calls, credentials or user content."""
import http.server
import json
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        text = body['messages'][1]['content']
        print(json.dumps({'sentence': text}, ensure_ascii=False), flush=True)
        result = {'text': text.replace('的话', ''), 'edits': []}
        if '的话' in text:
            result['edits'] = [{'original': '的话', 'replacement': '', 'kind': 'filler', 'why': '删掉更干脆'}]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        chunk = {'choices': [{'delta': {'content': json.dumps(result, ensure_ascii=False)}}]}
        self.wfile.write(('data: ' + json.dumps(chunk, ensure_ascii=False) + '\n\ndata: [DONE]\n\n').encode())

server = http.server.HTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 18764), Handler)
server.serve_forever()
