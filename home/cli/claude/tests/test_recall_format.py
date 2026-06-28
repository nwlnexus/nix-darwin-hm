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
