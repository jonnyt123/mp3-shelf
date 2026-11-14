#!/usr/bin/env python3
"""Serve one AAC fixture to the isolated Simulator proof on loopback."""
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sys
import uuid


def write_atomically(path, text):
    pending = path.with_suffix(".tmp")
    pending.write_text(text)
    pending.replace(path)


def serve(fixture, output, run_id):
    run_id = str(uuid.UUID(run_id))
    payload = Path(fixture).read_bytes()
    if not 8 < len(payload) <= 1024 * 1024 or payload[4:8] != b"ftyp":
        raise ValueError("Expected a small AAC fixture in an MP4 container")
    output = Path(output)
    endpoint = f"/{run_id}/fixture.m4a"
    digest = hashlib.sha256(payload).hexdigest()

    class FixtureHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != endpoint:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "audio/mp4")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            write_atomically(output / "fixture-served.json", json.dumps({
                "runID": run_id,
                "url": f"http://127.0.0.1:{self.server.server_port}{endpoint}",
                "sha256": digest,
                "bytes": len(payload),
            }))

    with HTTPServer(("127.0.0.1", 0), FixtureHandler) as server:
        write_atomically(output / "fixture-port", str(server.server_port))
        server.serve_forever()


if __name__ == "__main__":
    serve(*sys.argv[1:])
