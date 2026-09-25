"""Deterministic local System One fixture for MiniGrid's player-side Jev test."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/v1/systemone"
        assert self.headers["Authorization"] == "Bearer mock"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        observation = json.loads(body["state"].split("\n", 1)[1])
        assert observation["lane"] == 0
        assert len(observation["known"]) == 13
        choices = body["questions"]["decision"]["criteria"]
        assert "forward" in choices
        probabilities = {name: float(name == "forward") for name in choices}
        with open(sys.argv[2], "a", encoding="utf-8") as output:
            output.write(json.dumps({"lane": observation["lane"], "choice": "forward"}) + "\n")
        response = json.dumps({
            "model": body["model"],
            "answers": {"decision": {"type": "choice", "confidence": 1.0,
                                     "probabilities": probabilities}},
            "usage": {"input_tokens": 1, "output_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, _format, *_args):
        pass


HTTPServer((sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1",
            int(sys.argv[1])), Handler).serve_forever()
