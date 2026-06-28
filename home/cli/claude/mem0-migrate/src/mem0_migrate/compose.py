"""Turn claude-mem rows into the ``text`` + ``metadata`` an OpenMemory POST needs.

OpenMemory's MCP search returns only the stored ``text`` — it does NOT surface
the SQLite-side metadata. So provenance is duplicated into a footer appended to
the blob (searchable) *and* into ``metadata`` (used by the REST ``/filter``
recall path and for idempotent re-runs).
"""

from __future__ import annotations

import json


def _loads_list(raw) -> list[str]:
    """Parse a JSON-array TEXT column into a list of non-empty strings."""
    if not raw:
        return []
    try:
        val = json.loads(raw)
    except (TypeError, ValueError):
        return []
    if not isinstance(val, list):
        return []
    return [str(x).strip() for x in val if str(x).strip()]


def _footer(row: dict, *, type_: str) -> str:
    return (
        "---\n"
        f"Project: {row['project']} · Type: {type_} · "
        f"{row['created_at']} · src:claude-mem#{row['id']}"
    )


def observation_blob(row: dict) -> str | None:
    """Markdown blob for one observation, or None if it carries no content."""
    title = (row.get("title") or "").strip()
    subtitle = (row.get("subtitle") or "").strip()
    narrative = (row.get("narrative") or "").strip()
    facts = _loads_list(row.get("facts"))
    concepts = _loads_list(row.get("concepts"))

    if not (title or subtitle or narrative or facts):
        return None

    parts: list[str] = []
    if title:
        parts.append(f"# {title}")
    if subtitle:
        parts.append(subtitle)
    if narrative:
        parts.append(f"\n{narrative}")
    if facts:
        parts.append("\nFacts:\n" + "\n".join(f"- {f}" for f in facts))
    if concepts:
        parts.append("\nTags: " + ", ".join(concepts))

    body = "\n".join(parts).strip()
    return f"{body}\n\n{_footer(row, type_=row['type'])}"


def session_summary_blob(row: dict) -> str | None:
    """Markdown blob for one session summary, or None if empty."""
    sections = [
        ("Request", row.get("request")),
        ("Investigated", row.get("investigated")),
        ("Learned", row.get("learned")),
        ("Completed", row.get("completed")),
        ("Next steps", row.get("next_steps")),
        ("Notes", row.get("notes")),
    ]
    rendered = [(label, (val or "").strip()) for label, val in sections]
    rendered = [(label, val) for label, val in rendered if val]
    if not rendered:
        return None

    title = rendered[0][1]
    parts = [f"# {title}"]
    for label, val in rendered:
        parts.append(f"\n{label}: {val}")

    body = "\n".join(parts).strip()
    return f"{body}\n\n{_footer(row, type_='session_summary')}"


def build_metadata(row: dict, *, source_table: str) -> dict:
    """Provenance metadata stored alongside the memory (SQLite + /filter recall)."""
    type_ = "session_summary" if source_table == "session_summaries" else row["type"]
    return {
        "project": row["project"],
        "type": type_,
        "source": "claude-mem",
        "source_table": source_table,
        "source_id": row["id"],
        "original_created_at": row["created_at"],
    }


def compose_row(row: dict, *, source_table: str) -> dict | None:
    """Full ``{text, metadata}`` payload for a row, or None to skip an empty blob."""
    if source_table == "session_summaries":
        blob = session_summary_blob(row)
    else:
        blob = observation_blob(row)
    if blob is None:
        return None
    return {"text": blob, "metadata": build_metadata(row, source_table=source_table)}
