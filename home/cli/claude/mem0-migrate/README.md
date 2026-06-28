# mem0-migrate

One-shot, resumable migration of **claude-mem** SQLite memory
(`observations` + `session_summaries`) into the self-hosted **Mem0 / OpenMemory**
platform via its REST API. Part of epic #123 (P3 in
`docs/superpowers/plans/2026-06-27-mem0-memory-platform.md`).

## What it does

For every non-empty row, oldest first, it composes a Markdown blob and POSTs it
to `POST {url}/api/v1/memories/` with `infer=false` (no LLM re-summarization —
the rows are already distilled). Provenance is written **twice**:

- into a footer appended to the blob (`src:claude-mem#<id>`), because OpenMemory's
  MCP `search_memory` returns only the stored text, not the SQLite metadata; and
- into the `metadata` object, used by the REST `/filter` recall path and for
  idempotent re-runs.

### Safety properties

- **Success = HTTP 200 _and_ a JSON body with no `error` key.** The API returns
  200 even on failure, so that combination is the only success signal
  (`run.classify_response`).
- **Only successful rows are checkpointed** (`.mem0-migrate-checkpoint.json`,
  written atomically). A re-run resends exactly the rows that failed or never
  ran — `infer=false` does no server-side dedup, so the checkpoint is the sole
  dedup mechanism. The full run is therefore safe to re-run / resume.
- Reads the source DB **read-only** (`mode=ro`); the backup file is never mutated.

## Modules

| Module | Responsibility |
|--------|----------------|
| `db.py` | Read-only row reads, oldest-first. |
| `compose.py` | Row → `{text, metadata}`; skips empty blobs. |
| `checkpoint.py` | Resumable, idempotent per-table `source_id` set. |
| `run.py` | REST client (`MemoryClient`), response classifier, concurrent driver, CLI. |

## Usage

```bash
cd tools/mem0-migrate

# Smoke test — first 20 rows (the P3.6 visibility gate)
uv run --with httpx python -m mem0_migrate.run \
  --db ~/.claude-mem/claude-mem.db.premem0-20260627 \
  --url http://openmemory.raptor-mimosa.ts.net:8765 \
  --mode smoke

# Full run (~11,689 rows; resumable — safe to re-run)
uv run --with httpx python -m mem0_migrate.run \
  --db ~/.claude-mem/claude-mem.db.premem0-20260627 \
  --url http://openmemory.raptor-mimosa.ts.net:8765 \
  --mode full --concurrency 6
```

Flags: `--limit N` (cap rows), `--concurrency 4-8` (in-flight POSTs, default 4),
`--user-id` (default `mnemosyne`), `--app` (default `claude-mem-import`),
`--checkpoint PATH`.

## Pre-run requirement (human-gated)

REST `add` **404s on a missing user**. Before the first run, pre-create the
`mnemosyne` user once via the MCP path (it auto-creates): from a Claude Code
session with the `mem0` MCP configured (P2 Task 2.3), call `add_memories` once
with a throwaway sentinel. See the plan's Task 3.5.

## Tests

```bash
uv run --with pytest pytest
```

All unit tests are offline — the network is injected (`MemoryClient(client=...)`)
and the fixture DB is built deterministically by `tests/conftest.py` with the
real claude-mem schema.
