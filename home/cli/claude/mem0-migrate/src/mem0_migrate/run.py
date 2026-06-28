"""REST client + batch driver for the claude-mem -> OpenMemory migration.

Safety properties:
  * A row counts as migrated only on HTTP 200 *with no* ``error`` key — the
    handler returns 200 even on failure, so that combination is the only
    success signal (``classify_response``).
  * Only successful rows are checkpointed, so a re-run resends exactly the rows
    that failed or never ran (``infer=false`` does no server-side dedup).
"""

from __future__ import annotations

import argparse
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import compose, db
from .checkpoint import Checkpoint

DEFAULT_USER_ID = "mnemosyne"
DEFAULT_APP = "claude-mem-import"
DEFAULT_CHECKPOINT = ".mem0-migrate-checkpoint.json"

# add_fn(text, metadata) -> (ok, error)
AddFn = Callable[[str, dict], tuple[bool, str | None]]


def classify_response(status_code: int, body) -> tuple[bool, str | None]:
    """Success iff HTTP 200 AND a dict body without an ``error`` key."""
    if status_code != 200:
        return False, f"http {status_code}"
    if not isinstance(body, dict):
        return False, "non-JSON or empty response body"
    if body.get("error"):
        return False, str(body["error"])
    return True, None


class MemoryClient:
    """Thin httpx wrapper that POSTs one composed memory and classifies the reply."""

    def __init__(self, base_url: str, *, user_id: str = DEFAULT_USER_ID,
                 app: str = DEFAULT_APP, timeout: float = 30.0, client=None) -> None:
        self.base_url = base_url.rstrip("/")
        self.user_id = user_id
        self.app = app
        if client is None:
            import httpx  # imported lazily so unit tests need no network dep

            client = httpx.Client(timeout=timeout)
        self._client = client

    def add(self, text: str, metadata: dict) -> tuple[bool, str | None]:
        payload = {
            "user_id": self.user_id,
            "app": self.app,
            "infer": False,
            "text": text,
            "metadata": metadata,
        }
        try:
            resp = self._client.post(f"{self.base_url}/api/v1/memories/", json=payload)
        except Exception as exc:  # network/timeout -> treat as a failed row
            return False, f"request error: {exc}"
        try:
            body = resp.json()
        except ValueError:
            body = None
        return classify_response(resp.status_code, body)

    def close(self) -> None:
        self._client.close()


@dataclass
class MigrateResult:
    total: int = 0
    succeeded: int = 0
    skipped: int = 0
    failed: list[tuple[str, int, str | None]] = field(default_factory=list)


def iter_composed(db_path: str | Path, *, limit: int | None = None):
    """Yield ``(table, source_id, composed)`` for every non-empty row.

    Observations first, then session summaries, each oldest-first. Empty blobs
    are dropped here so they never count against ``limit`` or the totals.
    """
    count = 0
    readers = (
        ("observations", db.read_observations),
        ("session_summaries", db.read_session_summaries),
    )
    for table, reader in readers:
        for row in reader(db_path):
            composed = compose.compose_row(row, source_table=table)
            if composed is None:
                continue
            yield table, row["id"], composed
            count += 1
            if limit is not None and count >= limit:
                return


def migrate(db_path: str | Path, add_fn: AddFn, checkpoint: Checkpoint, *,
            limit: int | None = None, concurrency: int = 4,
            log: Callable[[str], None] | None = None) -> MigrateResult:
    items = list(iter_composed(db_path, limit=limit))
    pending = [(t, sid, c) for (t, sid, c) in items if not checkpoint.is_done(t, sid)]

    result = MigrateResult(total=len(items), skipped=len(items) - len(pending))
    if log:
        log(f"{result.total} composed, {result.skipped} already migrated, "
            f"{len(pending)} to send (concurrency={concurrency})")

    if not pending:
        return result

    with ThreadPoolExecutor(max_workers=max(1, concurrency)) as ex:
        futures = {
            ex.submit(add_fn, c["text"], c["metadata"]): (t, sid)
            for (t, sid, c) in pending
        }
        done = 0
        for fut in as_completed(futures):
            table, sid = futures[fut]
            ok, error = fut.result()
            if ok:
                checkpoint.mark(table, sid)
                result.succeeded += 1
            else:
                result.failed.append((table, sid, error))
            done += 1
            if log and done % 100 == 0:
                log(f"  {done}/{len(pending)} sent "
                    f"({result.succeeded} ok, {len(result.failed)} failed)")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="mem0-migrate",
        description="Migrate claude-mem SQLite memory into OpenMemory via REST.",
    )
    parser.add_argument("--db", required=True, help="Path to claude-mem.db (backup).")
    parser.add_argument("--url", required=True, help="OpenMemory base URL.")
    parser.add_argument("--mode", choices=["smoke", "full"], default="smoke")
    parser.add_argument("--limit", type=int, default=None,
                        help="Cap rows sent (defaults to 20 in smoke mode).")
    parser.add_argument("--concurrency", type=int, default=2,
                        help="In-flight POSTs. Keep low (1-2) — server-side "
                             "Ollama embedding serializes and is the bottleneck.")
    parser.add_argument("--timeout", type=float, default=120.0,
                        help="Per-request HTTP timeout in seconds (default 120; "
                             "embedding can be slow, esp. on cold model load).")
    parser.add_argument("--user-id", default=DEFAULT_USER_ID)
    parser.add_argument("--app", default=DEFAULT_APP)
    parser.add_argument("--checkpoint", default=DEFAULT_CHECKPOINT)
    args = parser.parse_args(argv)

    limit = args.limit
    if args.mode == "smoke" and limit is None:
        limit = 20

    client = MemoryClient(args.url, user_id=args.user_id, app=args.app,
                          timeout=args.timeout)
    checkpoint = Checkpoint(args.checkpoint)
    try:
        result = migrate(
            args.db, client.add, checkpoint,
            limit=limit, concurrency=args.concurrency, log=lambda m: print(m, flush=True),
        )
    finally:
        client.close()

    print(f"\nDONE: {result.succeeded} migrated, {result.skipped} skipped, "
          f"{len(result.failed)} failed (of {result.total} composed).")
    if result.failed:
        print("Failures (table, source_id, error):", flush=True)
        for table, sid, err in result.failed[:50]:
            print(f"  {table}#{sid}: {err}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
