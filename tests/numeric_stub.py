"""Deterministic numeric policy fixture for the ordinary MiniGrid player socket."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert len(body["values"]) == 1295
        assert len(body["action_mask"]) == 180
        assert body["action_mask"][3]
        with open(sys.argv[2], "a", encoding="utf-8") as output:
            output.write(json.dumps({"choice": 3}) + "\n")
        response = b'{"choice":3}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format, *_args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
