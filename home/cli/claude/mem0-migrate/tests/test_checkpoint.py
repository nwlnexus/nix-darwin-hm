from mem0_migrate.checkpoint import Checkpoint


def test_checkpoint_roundtrip(tmp_path):
    path = tmp_path / "ckpt.json"
    cp = Checkpoint(path)
    cp.mark("observations", 1)
    cp.mark("observations", 2)
    cp.mark("session_summaries", 7)

    # a fresh instance reads back persisted state
    cp2 = Checkpoint(path)
    assert cp2.seen("observations") == {1, 2}
    assert cp2.seen("session_summaries") == {7}


def test_skip_already_migrated(tmp_path):
    path = tmp_path / "ckpt.json"
    cp = Checkpoint(path)
    cp.mark("observations", 5)

    assert cp.is_done("observations", 5) is True
    assert cp.is_done("observations", 6) is False
    # a table never seen returns an empty set, not an error
    assert cp.is_done("session_summaries", 5) is False
    assert cp.seen("session_summaries") == set()


def test_mark_is_idempotent(tmp_path):
    path = tmp_path / "ckpt.json"
    cp = Checkpoint(path)
    cp.mark("observations", 3)
    cp.mark("observations", 3)
    assert cp.seen("observations") == {3}


def test_missing_file_starts_empty(tmp_path):
    cp = Checkpoint(tmp_path / "does-not-exist.json")
    assert cp.seen("observations") == set()
