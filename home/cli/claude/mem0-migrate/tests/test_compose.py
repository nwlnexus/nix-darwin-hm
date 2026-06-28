from mem0_migrate import compose, db


def _obs(mini_db, obs_id):
    return next(r for r in db.read_observations(mini_db) if r["id"] == obs_id)


def _sum(mini_db, sum_id):
    return next(r for r in db.read_session_summaries(mini_db) if r["id"] == sum_id)


def test_compose_observation_blob(mini_db):
    blob = compose.observation_blob(_obs(mini_db, 1))
    assert blob is not None
    assert blob.startswith("# Auth flow uses ODIN tokens")
    assert "ODIN issues short-lived JWTs verified by Hermes" in blob
    assert "The authentication subsystem mints ODIN tokens" in blob
    # facts rendered as a bullet list
    assert "Facts:" in blob
    assert "- ODIN mints JWTs" in blob
    assert "- Hermes validates them" in blob
    # concepts rendered as tags
    assert "Tags: how-it-works, auth" in blob
    # provenance footer is MCP-searchable (OpenMemory drops SQLite metadata)
    assert blob.rstrip().endswith(
        "---\nProject: olympus-sdk · Type: discovery · "
        "2026-02-17T23:51:01.000Z · src:claude-mem#1"
    )


def test_compose_skips_empty_blob(mini_db):
    # fixture row 4 has null title/subtitle/narrative/facts/concepts
    assert compose.observation_blob(_obs(mini_db, 4)) is None


def test_compose_session_summary_blob(mini_db):
    blob = compose.session_summary_blob(_sum(mini_db, 1))
    assert blob is not None
    assert "Remove Neon dependency" in blob
    assert "D1 is now the only database binding" in blob
    assert "Deleted Neon config and migrated tests to D1" in blob
    assert blob.rstrip().endswith("src:claude-mem#1")
    assert "Type: session_summary" in blob


def test_build_metadata_observation(mini_db):
    meta = compose.build_metadata(_obs(mini_db, 1), source_table="observations")
    assert meta == {
        "project": "olympus-sdk",
        "type": "discovery",
        "source": "claude-mem",
        "source_table": "observations",
        "source_id": 1,
        "original_created_at": "2026-02-17T23:51:01.000Z",
    }


def test_build_metadata_session_summary(mini_db):
    meta = compose.build_metadata(_sum(mini_db, 2), source_table="session_summaries")
    assert meta["type"] == "session_summary"
    assert meta["source_table"] == "session_summaries"
    assert meta["source_id"] == 2
    assert meta["project"] == "formcenter"


def test_compose_row_returns_text_and_metadata(mini_db):
    composed = compose.compose_row(_obs(mini_db, 2), source_table="observations")
    assert set(composed.keys()) == {"text", "metadata"}
    assert composed["text"].startswith("# D1 replaces Neon")
    assert composed["metadata"]["source_id"] == 2


def test_compose_row_returns_none_for_empty(mini_db):
    assert compose.compose_row(_obs(mini_db, 4), source_table="observations") is None
