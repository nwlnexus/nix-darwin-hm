import threading

from mem0_migrate import run
from mem0_migrate.checkpoint import Checkpoint


# ---- classify_response: the handler returns HTTP 200 even on failure --------

def test_classify_success():
    assert run.classify_response(200, {"id": "abc", "user_id": "mnemosyne"}) == (True, None)


def test_classify_error_key_is_failure():
    ok, err = run.classify_response(200, {"error": "embedding failed"})
    assert ok is False
    assert "embedding failed" in err


def test_classify_non_200_is_failure():
    ok, err = run.classify_response(500, None)
    assert ok is False
    assert "500" in err


def test_classify_unparseable_body_is_failure():
    ok, err = run.classify_response(200, None)
    assert ok is False


# ---- driver: checkpoint only on real success --------------------------------

class FakeAdder:
    """Stands in for MemoryClient.add; records every source_id it is called with."""

    def __init__(self, fail_ids=None):
        self.fail_ids = set(fail_ids or [])
        self.calls: list[int] = []
        self._lock = threading.Lock()

    def __call__(self, text, metadata):
        sid = metadata["source_id"]
        with self._lock:
            self.calls.append(sid)
        if sid in self.fail_ids:
            return (False, "boom")
        return (True, None)


def test_successful_rows_are_checkpointed(mini_db, tmp_path):
    cp = Checkpoint(tmp_path / "c.json")
    adder = FakeAdder()
    result = run.migrate(mini_db, adder, cp, concurrency=2)

    # 4 non-empty observations (id 4 is skipped as empty) + 2 summaries = 6
    assert result.succeeded == 6
    assert result.skipped == 0
    assert not result.failed
    # the empty observation (id 4) was never composed, never sent
    assert 4 not in adder.calls
    assert cp.seen("observations") == {1, 2, 3, 5}
    assert cp.seen("session_summaries") == {1, 2}


def test_failed_row_not_checkpointed(mini_db, tmp_path):
    cp = Checkpoint(tmp_path / "c.json")
    adder = FakeAdder(fail_ids={2})  # observation id 2 returns an error body
    result = run.migrate(mini_db, adder, cp, concurrency=1)

    assert any(sid == 2 for (_t, sid, _e) in result.failed)
    assert 2 not in cp.seen("observations")
    # the others still succeed and checkpoint
    assert cp.seen("observations") == {1, 3, 5}


def test_rerun_skips_already_migrated(mini_db, tmp_path):
    cp_path = tmp_path / "c.json"
    first = run.migrate(mini_db, FakeAdder(), Checkpoint(cp_path), concurrency=2)
    assert first.succeeded == 6

    # second run on a fresh checkpoint instance reading the same file
    second_adder = FakeAdder()
    second = run.migrate(mini_db, second_adder, Checkpoint(cp_path), concurrency=2)
    assert second.succeeded == 0
    assert second.skipped == 6
    assert second_adder.calls == []  # nothing re-sent


def test_smoke_limit_caps_attempts(mini_db, tmp_path):
    cp = Checkpoint(tmp_path / "c.json")
    adder = FakeAdder()
    result = run.migrate(mini_db, adder, cp, limit=2, concurrency=1)
    assert len(adder.calls) == 2
    assert result.succeeded == 2


class StubResponse:
    def __init__(self, status_code, body):
        self.status_code = status_code
        self._body = body

    def json(self):
        if self._body is None:
            raise ValueError("no json")
        return self._body


class StubHttpClient:
    """Captures the POST so we can assert the exact REST contract shape."""

    def __init__(self, response):
        self._response = response
        self.last_url = None
        self.last_json = None

    def post(self, url, json):
        self.last_url = url
        self.last_json = json
        return self._response

    def close(self):
        pass


def test_memory_client_posts_expected_contract():
    stub = StubHttpClient(StubResponse(200, {"id": "x"}))
    client = run.MemoryClient("http://openmemory.example:8765/", client=stub)
    ok, err = client.add("blob text", {"source_id": 9, "project": "p"})

    assert ok is True and err is None
    assert stub.last_url == "http://openmemory.example:8765/api/v1/memories/"
    assert stub.last_json == {
        "user_id": "mnemosyne",
        "app": "claude-mem-import",
        "infer": False,
        "text": "blob text",
        "metadata": {"source_id": 9, "project": "p"},
    }


def test_memory_client_flags_error_body_as_failure():
    stub = StubHttpClient(StubResponse(200, {"error": "boom"}))
    client = run.MemoryClient("http://x:8765", client=stub)
    ok, err = client.add("t", {})
    assert ok is False and "boom" in err
