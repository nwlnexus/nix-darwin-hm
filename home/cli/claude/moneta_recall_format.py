"""Format moneta GET /recall responses into a compact SessionStart block.

Pure + importable so formatting is unit-testable. The bash hook pipes raw API
JSON to __main__, which prints the SessionStart hookSpecificOutput JSON, or
{"continue": true} on any empty/error path (fail-open).

moneta response shape: {"ok": true, "results": [{"content", "score", "tags",
"source", "created_at", "metadata"}...], "insight": str|null}
"""
from __future__ import annotations

import json
import os
import sys

TOP_K = int(os.environ.get("MONETA_TOP_K", "5"))
WIDTH = int(os.environ.get("MONETA_LINE_WIDTH", "200"))


def _truncate(text: str, width: int) -> str:
    one_line = " ".join(text.split())
    if len(one_line) <= width:
        return one_line
    return one_line[: width - 1].rstrip() + "…"


def format_block(data: dict, cwd: str, top_k: int = TOP_K, width: int = WIDTH) -> str | None:
    """Return a compact markdown block, or None when there is nothing to show."""
    results = data.get("results") or []
    if not results:
        return None
    project = os.path.basename(cwd.rstrip("/")) or cwd or "this project"
    shown = min(top_k, len(results))
    lines = [f"Recalled {len(results)} memories for {project} — top {shown}:"]
    for i, item in enumerate(results[:top_k], 1):
        memory = (item.get("content") or "").strip()
        if memory:
            lines.append(f"{i}. {_truncate(memory, width)}")
    if len(lines) == 1:
        return None
    insight = (data.get("insight") or "").strip()
    if insight:
        lines.append(f"insight: {_truncate(insight, width)}")
    return "\n".join(lines)


def format_unavailable(url: str) -> str:
    """A short SessionStart note for when the endpoint could not be reached.

    Distinct from the silent fail-open used for a genuinely empty result: this
    is surfaced so the session knows memories *exist but did not load*, rather
    than wrongly assuming there are none.
    """
    where = url.strip() if url and url.strip() else "endpoint"
    return (
        f"⚠️ moneta recall unavailable — {where} unreachable; "
        "memories were not loaded this session (recall failed, not empty)."
    )


def _emit(context: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--unavailable":
        _emit(format_unavailable(sys.argv[2]))
        return 0
    cwd = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
    except Exception:
        print(json.dumps({"continue": True}))
        return 0
    block = format_block(data, cwd)
    if block is None:
        print(json.dumps({"continue": True}))
        return 0
    _emit(block)
    return 0


if __name__ == "__main__":
    sys.exit(main())
