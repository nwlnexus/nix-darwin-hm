import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import mem0_recall_format as f


def test_header_and_count():
    data = {"total": 12, "items": [{"memory": "alpha"}, {"memory": "beta"},
                                   {"memory": "gamma"}, {"memory": "delta"}]}
    block = f.format_block(data, "/Users/x/projects/olympus-sdk", top_k=3)
    assert block is not None
    lines = block.splitlines()
    assert lines[0] == "Recalled 12 memories for olympus-sdk — top 3:"
    assert len(lines) == 4          # header + 3 items (top_k caps at 3)
    assert lines[1].startswith("1. ")


def test_truncation():
    block = f.format_block({"total": 1, "items": [{"memory": "x" * 500}]},
                           "/tmp/proj", width=200)
    item_line = block.splitlines()[1]
    assert len(item_line) <= 3 + 200        # "1. " prefix + width
    assert item_line.endswith("…")


def test_empty_response_returns_none():
    assert f.format_block({"total": 0, "items": []}, "/tmp/proj") is None


def test_main_fail_open_on_bad_json():
    proc = subprocess.run([sys.executable, str(Path(f.__file__)), "/tmp/proj"],
                          input="not json", capture_output=True, text=True)
    assert json.loads(proc.stdout) == {"continue": True}


def test_content_key_is_read():
    # The real OpenMemory /filter API returns memory text under "content",
    # not "memory"/"text".
    data = {"total": 5, "items": [{"content": "alpha mem"}, {"content": "beta mem"}]}
    block = f.format_block(data, "/Users/x/projects/olympus-sdk", top_k=3)
    assert block is not None
    lines = block.splitlines()
    assert lines[0] == "Recalled 5 memories for olympus-sdk — top 2:"
    assert lines[1] == "1. alpha mem"


def test_main_parses_content_with_literal_control_chars():
    # The API emits raw newlines/tabs inside JSON string values; the main path
    # must parse them (strict=False) and surface the content as a memory.
    raw = '{"total": 1, "items": [{"content": "# Title\nRequest: do thing\twith tab"}]}'
    proc = subprocess.run([sys.executable, str(Path(f.__file__)),
                           "/Users/x/projects/olympus-sdk"],
                          input=raw, capture_output=True, text=True)
    out = json.loads(proc.stdout)
    ctx = out["hookSpecificOutput"]["additionalContext"]
    assert ctx.startswith("Recalled 1 memories for olympus-sdk — top 1:")
    assert "# Title Request: do thing with tab" in ctx
