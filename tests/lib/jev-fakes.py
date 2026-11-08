"""Local stand-ins for tests/jev-router.sh (olympus-sdk#647): a fake Jev (/v1/systemone), a fake Anthropic upstream
(/v1/messages) and a fake OTLP collector (/v1/logs). Each records every request it gets as one JSON line
({path, headers, body}) in --record and writes the port it listens on to --port-file.

  python3 -I jev-fakes.py jev|upstream|otlp --record FILE --port-file FILE [--sleep SECONDS]
  python3 -I jev-fakes.py hang --port-file FILE      (accepts connections, never answers)
"""

import argparse
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

JEV_ANSWER = {
    "id": "fake-jev",
    "model": "jev-fake",
    "answers": {
        "tier": {
            "choice": "routine",
            "probabilities": {"mechanical": 0.1, "routine": 0.8, "complex": 0.1},
        },
        "alters_sensitive_state": {"noul": 0.0},
        "routing_claim_present": {"noul": 0.0},
    },
    "usage": {"input_tokens": 42},
}
MESSAGE = {
    "id": "msg_fake",
    "type": "message",
    "role": "assistant",
    "model": "fake",
    "content": [{"type": "text", "text": "ok"}],
    "stop_reason": "end_turn",
    "usage": {"input_tokens": 10, "output_tokens": 1},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["jev", "upstream", "otlp", "hang"])
    ap.add_argument("--record")
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--sleep", type=float, default=0.0)
    args = ap.parse_args()
    lock = threading.Lock()

    if args.mode == "hang":
        srv = socket.socket()
        srv.bind(("127.0.0.1", 0))
        srv.listen(16)
        with open(args.port_file, "w") as f:
            f.write(str(srv.getsockname()[1]))
        held = []
        while True:
            conn, _ = srv.accept()
            held.append(conn)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_POST(self):
            raw = self.rfile.read(int(self.headers.get("content-length", 0)))
            try:
                body = json.loads(raw)
            except ValueError:
                body = raw.decode(errors="replace")
            with lock, open(args.record, "a") as f:
                f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
            if args.sleep:
                time.sleep(args.sleep)
            answer = {"jev": JEV_ANSWER, "upstream": MESSAGE, "otlp": {}}[args.mode]
            data = json.dumps(answer).encode()
            try:
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except OSError:
                pass  # the caller gave up (the timeout test)

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(args.port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()


if __name__ == "__main__":
    main()
