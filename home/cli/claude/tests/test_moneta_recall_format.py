import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import moneta_recall_format as f


def test_header_count_and_insight():
    data = {
        "ok": True,
        "results": [
            {"content": "alpha", "score": 91.2},
            {"content": "beta", "score": 88.0},
            {"content": "gamma", "score": 70.1},
            {"content": "delta", "score": 61.0},
        ],
        "insight": "mostly build-system decisions",
    }
    block = f.format_block(data, "/Users/x/projects/olympus-sdk", top_k=3)
    assert block is not None
    lines = block.splitlines()
    assert lines[0] == "Recalled 4 memories for olympus-sdk — top 3:"
    assert lines[1].startswith("1. alpha")
    assert len(lines) == 5  # header + 3 items + insight
    assert lines[-1] == "insight: mostly build-system decisions"


def test_empty_results_returns_none():
    assert f.format_block({"ok": True, "results": []}, "/repo") is None
    assert f.format_block({"ok": True}, "/repo") is None


def test_no_insight_line_when_absent():
    data = {"ok": True, "results": [{"content": "alpha"}], "insight": None}
    block = f.format_block(data, "/repo")
    assert block is not None
    assert "insight" not in block


def test_truncation_is_single_line():
    data = {"ok": True, "results": [{"content": "x " * 300}]}
    block = f.format_block(data, "/repo", width=50)
    assert block is not None
    item = block.splitlines()[1]
    assert len(item) <= 55
    assert item.endswith("…")


def test_unavailable_message_names_endpoint():
    msg = f.format_unavailable("https://mem.nwlnexus.io")
    assert "mem.nwlnexus.io" in msg and "not empty" in msg
