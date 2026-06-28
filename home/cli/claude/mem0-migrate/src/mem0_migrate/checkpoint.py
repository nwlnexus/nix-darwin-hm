"""Resumable, idempotent migration checkpoint.

``infer=false`` POSTs do no server-side dedup, so re-running safely depends
entirely on this file: it records every successfully-migrated ``source_id`` per
source table. Persisted atomically (temp + rename) after each mark so a crash
mid-run never corrupts the record.
"""

from __future__ import annotations

import json
import os
from pathlib import Path


class Checkpoint:
    def __init__(self, path: str | Path) -> None:
        self._path = Path(path)
        self._seen: dict[str, set[int]] = {}
        self._load()

    def _load(self) -> None:
        if not self._path.exists():
            return
        data = json.loads(self._path.read_text())
        self._seen = {table: set(ids) for table, ids in data.items()}

    def _save(self) -> None:
        data = {table: sorted(ids) for table, ids in self._seen.items()}
        tmp = self._path.with_suffix(self._path.suffix + ".tmp")
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(data))
        os.replace(tmp, self._path)

    def seen(self, table: str) -> set[int]:
        return set(self._seen.get(table, set()))

    def is_done(self, table: str, source_id: int) -> bool:
        return source_id in self._seen.get(table, set())

    def mark(self, table: str, source_id: int) -> None:
        bucket = self._seen.setdefault(table, set())
        if source_id in bucket:
            return
        bucket.add(source_id)
        self._save()
