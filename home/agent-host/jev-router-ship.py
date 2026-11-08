"""Ship jev-router's routing decisions as OTLP logs (olympus-sdk#647).

jev-router appends one JSON line per event to its log file (rotated to <file>.1 when it grows past its size limit).
This tails that file and POSTs one OTLP/HTTP JSON log record per `route` event to <endpoint> (a /v1/logs URL).

Privacy: attributes are an allowlist of the fields of a route line (tier, reason, model, session hash, request kind,
upstream host, Jev's choice and probabilities). Nothing that can carry request text is sent: no warning or error
events, and Jev's error message is reduced to "timeout" or "error".

Reliability: a separate process that only reads the file, so it never blocks the router. The offset (file inode and
byte position) is saved after each successful POST, so a restart resumes where it stopped; a rotation is followed
by reading the rest of the old file (now <file>.1) before the new one. A failed POST keeps the batch and retries
with backoff; at most MAX_PENDING records wait, older ones are dropped and counted on stderr.

Stdlib only; run with `python3 -I`.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

MAX_PENDING = 5000
BATCH = 200
POLL_S = 2.0
STR_MAX = 120

STRING_FIELDS = ("tier", "reason", "model", "session", "kind", "upstream", "path", "key_source")
JEV_STRING_FIELDS = ("channel", "model", "choice", "requestId")
JEV_NUMBER_FIELDS = ("ms", "inputTokens", "sensitive", "claim")


def log(msg):
    print(f"jev-router-ship: {msg}", file=sys.stderr, flush=True)


def attr(key, value):
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    if isinstance(value, float):
        return {"key": key, "value": {"doubleValue": value}}
    return {"key": key, "value": {"stringValue": str(value)[:STR_MAX]}}


def classifier(jev):
    if not isinstance(jev, dict):
        # Decided by the router's own rules (side call, subagent, sticky tier, tag...), with no Jev call. Not "local":
        # that name is the dispatch point's local classifier (olympus-sdk config/routing-policy.yaml).
        return "rules"
    return "jev" if jev.get("ok") else "fallback"


def record(entry):
    """The OTLP log record for one route line, or None for any other event."""
    if not isinstance(entry, dict) or entry.get("event") != "route":
        return None
    attrs = [attr("event", "route")]
    for k in STRING_FIELDS:
        v = entry.get(k)
        if isinstance(v, str) and v:
            attrs.append(attr(k, v))
    if isinstance(entry.get("req"), int):
        attrs.append(attr("req", entry["req"]))
    if isinstance(entry.get("secrets"), int):
        attrs.append(attr("secrets", entry["secrets"]))
    if entry.get("trusted_only") is True:
        attrs.append(attr("trusted_only", True))
    jev = entry.get("jev")
    attrs.append(attr("classifier", classifier(jev)))
    if isinstance(jev, dict):
        attrs.append(attr("jev.ok", bool(jev.get("ok"))))
        for k in JEV_STRING_FIELDS:
            v = jev.get(k)
            if isinstance(v, str) and v:
                attrs.append(attr(f"jev.{k}", v))
        for k in JEV_NUMBER_FIELDS:
            v = jev.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                attrs.append(attr(f"jev.{k}", v))
        if jev.get("hardened") is True:
            attrs.append(attr("jev.hardened", True))
        for group, prefix in (("probabilities", "jev.p"), ("tiers", "jev.tier_p")):
            probs = jev.get(group)
            if isinstance(probs, dict):
                for name, p in probs.items():
                    if isinstance(name, str) and name.isidentifier() and isinstance(p, (int, float)):
                        attrs.append(attr(f"{prefix}.{name[:40]}", float(p)))
        if not jev.get("ok") and isinstance(jev.get("error"), str):
            attrs.append(attr("jev.error_kind", "timeout" if "timeout" in jev["error"] else "error"))
    ts = entry.get("ts")
    try:
        nanos = int(datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp() * 1e9)
    except ValueError:
        nanos = time.time_ns()
    return {
        "timeUnixNano": str(nanos),
        "observedTimeUnixNano": str(time.time_ns()),
        "severityNumber": 9,
        "severityText": "INFO",
        "body": {"stringValue": "route"},
        "attributes": attrs,
    }


class Tail:
    """Reads complete lines from the log, following <file>.1 rotation, with a durable offset."""

    def __init__(self, path, state):
        self.path, self.state = path, state
        self.fh = None
        self.inode = None
        self.pos = 0
        self.buf = b""

    def load(self):
        try:
            with open(self.state) as f:
                saved = json.load(f)
            inode, pos = int(saved["inode"]), int(saved["offset"])
        except (OSError, ValueError, KeyError, TypeError):
            return
        for candidate in (self.path, self.path + ".1"):
            try:
                st = os.stat(candidate)
            except OSError:
                continue
            if st.st_ino == inode:
                self.open(candidate, pos if pos <= st.st_size else 0)
                return

    def open(self, name, pos=0):
        if self.fh:
            self.fh.close()
        self.fh = open(name, "rb")
        self.inode = os.fstat(self.fh.fileno()).st_ino
        self.fh.seek(pos)
        self.pos = pos
        self.buf = b""

    def save(self, inode, pos):
        tmp = self.state + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"inode": inode, "offset": pos}, f)
        os.replace(tmp, self.state)

    def read(self):
        """New complete lines as (inode, end offset, text) tuples."""
        out = []
        if self.fh is None:
            try:
                self.open(self.path)
            except OSError:
                return out
        while True:
            out += self._drain()
            try:
                st = os.stat(self.path)
            except OSError:
                return out  # rotated and not recreated yet
            if st.st_ino != self.inode:
                out += self._drain()  # the rest of the old file (now <file>.1)
                self.open(self.path)
                continue
            if st.st_size < self.pos:  # truncated in place
                self.open(self.path)
                continue
            return out

    def _drain(self):
        out = []
        chunk = self.fh.read()
        if not chunk:
            return out
        data = self.buf + chunk
        start = self.pos - len(self.buf)
        lines = data.split(b"\n")
        self.buf = lines.pop()
        for line in lines:
            start += len(line) + 1
            out.append((self.inode, start, line))
        self.pos = start + len(self.buf)
        return out


def post(endpoint, resource, records, timeout):
    body = {
        "resourceLogs": [
            {
                "resource": {"attributes": [attr(k, v) for k, v in resource.items()]},
                "scopeLogs": [{"scope": {"name": "jev-router-ship"}, "logRecords": records}],
            }
        ]
    }
    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as res:
        res.read()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--log", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--resource", action="append", default=[], help="key=value, repeatable")
    ap.add_argument("--poll", type=float, default=POLL_S)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--once", action="store_true", help="ship what is there, then exit (tests)")
    args = ap.parse_args(argv)
    resource = dict(r.split("=", 1) for r in args.resource)

    tail = Tail(args.log, args.state)
    tail.load()
    pending = []  # (inode, offset, record)
    backoff = args.poll
    dropped = 0
    while True:
        for inode, offset, line in tail.read():
            try:
                rec = record(json.loads(line))
            except ValueError:
                rec = None
            pending.append((inode, offset, rec))
        if len(pending) > MAX_PENDING:
            over = len(pending) - MAX_PENDING
            dropped += sum(1 for p in pending[:over] if p[2] is not None)
            pending = pending[over:]
            log(f"collector unreachable; dropped {dropped} route record(s) so far")
        failed = False
        while pending:
            batch = pending[:BATCH]
            records = [p[2] for p in batch if p[2] is not None]
            try:
                if records:
                    post(args.endpoint, resource, records, args.timeout)
            except (urllib.error.URLError, OSError, ValueError) as err:
                log(f"POST {args.endpoint} failed: {err}")
                failed = True
                break
            pending = pending[len(batch) :]
            last = batch[-1]
            tail.save(last[0], last[1])
        if failed:
            backoff = min(backoff * 2, 60.0)
        else:
            backoff = args.poll
        if args.once and (not pending or failed):
            return 1 if failed else 0
        time.sleep(backoff)


if __name__ == "__main__":
    sys.exit(main())
