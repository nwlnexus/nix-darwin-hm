from mem0_migrate import db

OBS_COLUMNS = {
    "id", "memory_session_id", "project", "type", "title", "subtitle",
    "facts", "narrative", "concepts", "files_modified",
    "created_at", "created_at_epoch",
}

SUM_COLUMNS = {
    "id", "memory_session_id", "project", "request", "investigated",
    "learned", "completed", "next_steps", "notes",
    "created_at", "created_at_epoch",
}


def test_read_observations_returns_rows_with_expected_columns(mini_db):
    rows = db.read_observations(mini_db)
    assert len(rows) == 5
    first = rows[0]
    assert OBS_COLUMNS <= set(first.keys())


def test_read_observations_ordered_by_epoch_ascending(mini_db):
    rows = db.read_observations(mini_db)
    epochs = [r["created_at_epoch"] for r in rows]
    assert epochs == sorted(epochs)
    assert rows[0]["id"] == 1  # earliest seed row


def test_read_session_summaries(mini_db):
    rows = db.read_session_summaries(mini_db)
    assert len(rows) == 2
    assert SUM_COLUMNS <= set(rows[0].keys())
    epochs = [r["created_at_epoch"] for r in rows]
    assert epochs == sorted(epochs)
