"""Read-only access to a claude-mem SQLite database.

Rows come back as plain dicts ordered oldest-first (``created_at_epoch ASC``)
so migration preserves chronological order and checkpoints advance monotonically.
"""

from __future__ import annotations

import sqlite3
from pathlib import Path

_OBS_QUERY = """
SELECT id, memory_session_id, project, type, title, subtitle,
       facts, narrative, concepts, files_modified,
       created_at, created_at_epoch
FROM observations
ORDER BY created_at_epoch ASC, id ASC
"""

_SUM_QUERY = """
SELECT id, memory_session_id, project, request, investigated,
       learned, completed, next_steps, notes,
       created_at, created_at_epoch
FROM session_summaries
ORDER BY created_at_epoch ASC, id ASC
"""


def _connect_ro(path: str | Path) -> sqlite3.Connection:
    # Open immutable/read-only so a live claude-mem writer can't be disturbed
    # and the backup file is never mutated.
    uri = f"file:{Path(path).resolve()}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def _query(path: str | Path, sql: str) -> list[dict]:
    conn = _connect_ro(path)
    try:
        return [dict(row) for row in conn.execute(sql)]
    finally:
        conn.close()


def read_observations(path: str | Path) -> list[dict]:
    """All observation rows, oldest first."""
    return _query(path, _OBS_QUERY)


def read_session_summaries(path: str | Path) -> list[dict]:
    """All session-summary rows, oldest first."""
    return _query(path, _SUM_QUERY)
