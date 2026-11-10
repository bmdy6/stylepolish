#!/usr/bin/env python3
"""Loopback-only synthetic model; does not log source text or call external services."""
import http.server
import json
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{}')
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        source = request['messages'][1]['content']
        replacements = [('非长', '非常'), ('在讨论', '再讨论')]
        output = source
        edits = []
        for old, new in replacements:
            if old in output:
                output = output.replace(old, new)
                edits.append(dict(original=old, replacement=new, why='合成验收'))
        if request['model'] == 'whole' and edits:
            output = '这个方案很好，明天我们再一起讨论。'
            edits = []
        result = dict(text=output, edits=edits, unclear=False)
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        chunk = {'choices': [{'delta': {'content': json.dumps(result, ensure_ascii=False)}}]}
        self.wfile.write(('data: '+json.dumps(chunk)+'\n\ndata: [DONE]\n\n').encode())

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as file:
    file.write(str(server.server_port))
server.serve_forever()
