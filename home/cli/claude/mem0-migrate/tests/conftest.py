"""Shared pytest fixtures.

Builds a tiny `tests/fixtures/mini.db` with the *real* claude-mem schema
(subset: the columns the migrator reads) and a handful of seed rows across
two projects, including one empty-content observation to exercise skip logic.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

FIXTURE_DIR = Path(__file__).parent / "fixtures"
MINI_DB = FIXTURE_DIR / "mini.db"

# Real schema, verbatim columns from claude-mem.db (FK clause dropped — the
# migrator opens read-only and never joins sdk_sessions).
_OBS_DDL = """
CREATE TABLE observations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_session_id TEXT NOT NULL,
  project TEXT NOT NULL,
  text TEXT,
  type TEXT NOT NULL,
  title TEXT,
  subtitle TEXT,
  facts TEXT,
  narrative TEXT,
  concepts TEXT,
  files_read TEXT,
  files_modified TEXT,
  prompt_number INTEGER,
  discovery_tokens INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  created_at_epoch INTEGER NOT NULL,
  content_hash TEXT
);
"""

_SUM_DDL = """
CREATE TABLE session_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  memory_session_id TEXT NOT NULL,
  project TEXT NOT NULL,
  request TEXT,
  investigated TEXT,
  learned TEXT,
  completed TEXT,
  next_steps TEXT,
  files_read TEXT,
  files_edited TEXT,
  notes TEXT,
  prompt_number INTEGER,
  discovery_tokens INTEGER DEFAULT 0,
  created_at TEXT NOT NULL,
  created_at_epoch INTEGER NOT NULL
);
"""


def _obs(id_, project, ts, *, title, subtitle, narrative, facts, concepts,
         type_="discovery", files_modified=None):
    return (
        id_,
        f"sess-{id_}",
        project,
        None,  # text
        type_,
        title,
        subtitle,
        json.dumps(facts) if facts is not None else None,
        narrative,
        json.dumps(concepts) if concepts is not None else None,
        json.dumps([]),  # files_read
        json.dumps(files_modified or []),
        1,  # prompt_number
        100,  # discovery_tokens
        f"2026-02-17T23:51:{id_:02d}.000Z",
        ts,
        f"HASH{id_:04d}",
    )


def _build(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    try:
        conn.executescript(_OBS_DDL + _SUM_DDL)

        observations = [
            # 3 in olympus-sdk, 2 in formcenter; ordered by epoch ascending below
            _obs(1, "olympus-sdk", 1771372305001,
                 title="Auth flow uses ODIN tokens",
                 subtitle="ODIN issues short-lived JWTs verified by Hermes",
                 narrative="The authentication subsystem mints ODIN tokens that "
                           "Hermes validates on every request.",
                 facts=["ODIN mints JWTs", "Hermes validates them"],
                 concepts=["how-it-works", "auth"],
                 files_modified=["src/auth.ts"]),
            _obs(2, "olympus-sdk", 1771372305002,
                 title="D1 replaces Neon",
                 subtitle="Migrated database layer to Cloudflare D1",
                 narrative="Neon Postgres was fully removed in favor of D1.",
                 facts=["Neon removed", "D1 is sole DB"],
                 concepts=["migration"]),
            _obs(3, "formcenter", 1771372305003,
                 title="Submission trends span layers",
                 subtitle="Feature touches db, api, views, templates",
                 narrative="Submission trends is integrated across the stack.",
                 facts=["8 files involved", "documented in docs/plans"],
                 concepts=["pattern"]),
            # Empty-content observation: every blob field null -> compose must skip.
            _obs(4, "formcenter", 1771372305004,
                 title=None, subtitle=None, narrative=None,
                 facts=None, concepts=None, type_="discovery"),
            _obs(5, "olympus-sdk", 1771372305005,
                 title="microVM test harness",
                 subtitle="mvm boots throwaway aarch64 VMs for atlas tests",
                 narrative="vm-test boots a fresh VM and execs each suite.",
                 facts=["uses mvmctl", "cross-compiles to musl"],
                 concepts=["testing", "how-it-works"]),
        ]
        conn.executemany(
            "INSERT INTO observations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            observations,
        )

        summaries = [
            (1, "sess-s1", "olympus-sdk",
             "Remove Neon dependency",
             "Searched for Neon references across the codebase",
             "D1 is now the only database binding",
             "Deleted Neon config and migrated tests to D1",
             "Verify CI passes",
             json.dumps(["wrangler.toml"]),
             json.dumps(["src/db.ts"]),
             "Clean migration",
             3, 200,
             "2026-02-18T01:00:00.000Z", 1771376400001),
            (2, "sess-s2", "formcenter",
             "Add submission trends widget",
             "Reviewed existing dashboard code",
             "Widget pattern reusable across pages",
             "Implemented trends widget end to end",
             "Add tests",
             json.dumps(["dashboard.go"]),
             json.dumps(["dashboard_widgets.templ"]),
             None,
             5, 250,
             "2026-02-18T02:00:00.000Z", 1771380000002),
        ]
        conn.executemany(
            "INSERT INTO session_summaries VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            summaries,
        )
        conn.commit()
    finally:
        conn.close()


@pytest.fixture(scope="session")
def mini_db() -> Path:
    """Path to a freshly built fixture DB with the real claude-mem schema."""
    _build(MINI_DB)
    return MINI_DB


if __name__ == "__main__":
    _build(MINI_DB)
    print(f"wrote {MINI_DB}")
