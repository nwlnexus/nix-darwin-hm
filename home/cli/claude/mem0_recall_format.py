"""Format OpenMemory /filter responses into a compact SessionStart block.

Pure + importable so formatting is unit-testable. The bash hook pipes raw API
JSON to __main__, which prints the SessionStart hookSpecificOutput JSON, or
{"continue": true} on any empty/error path (fail-open).
"""
from __future__ import annotations

import json
import os
import sys

TOP_K = int(os.environ.get("MEM0_TOP_K", "5"))
WIDTH = int(os.environ.get("MEM0_LINE_WIDTH", "200"))


def _truncate(text: str, width: int) -> str:
    one_line = " ".join(text.split())
    if len(one_line) <= width:
        return one_line
    return one_line[: width - 1].rstrip() + "…"


def format_block(data: dict, cwd: str, top_k: int = TOP_K, width: int = WIDTH) -> str | None:
    """Return a compact markdown block, or None when there is nothing to show."""
    items = data.get("items") or []
    total = data.get("total", len(items)) or 0
    if not items or total == 0:
        return None
    project = os.path.basename(cwd.rstrip("/")) or cwd or "this project"
    shown = min(top_k, len(items))
    lines = [f"Recalled {total} memories for {project} — top {shown}:"]
    for i, item in enumerate(items[:top_k], 1):
        memory = (item.get("content") or item.get("memory") or item.get("text") or "").strip()
        if memory:
            lines.append(f"{i}. {_truncate(memory, width)}")
    return "\n".join(lines) if len(lines) > 1 else None


def format_unavailable(url: str) -> str:
    """A short SessionStart note for when the endpoint could not be reached.

    Distinct from the silent fail-open used for a genuinely empty result: this
    is surfaced so the session knows memories *exist but did not load*, rather
    than wrongly assuming there are none.
    """
    where = url.strip() if url and url.strip() else "endpoint"
    return (
        f"⚠️ openmemory recall unavailable — {where} unreachable; "
        "memories were not loaded this session (recall failed, not empty)."
    )


def _emit(context: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": context,
        }
    }))


def main(argv):
    # `--unavailable URL`: bypass stdin parsing and emit the unreachable note.
    if len(argv) > 1 and argv[1] == "--unavailable":
        _emit(format_unavailable(argv[2] if len(argv) > 2 else ""))
        return 0
    cwd = argv[1] if len(argv) > 1 else os.getcwd()
    try:
        # strict=False: the OpenMemory /filter API embeds literal newline/tab
        # control characters inside JSON string values, which strict parsing rejects.
        data = json.loads(sys.stdin.read(), strict=False)
    except Exception:
        print(json.dumps({"continue": True}))
        return 0
    block = format_block(data, cwd)
    if not block:
        print(json.dumps({"continue": True}))
        return 0
    _emit(block)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
