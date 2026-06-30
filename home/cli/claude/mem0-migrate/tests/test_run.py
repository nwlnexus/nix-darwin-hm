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
        self.calls = 0

    def post(self, url, json):
        self.calls += 1
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


# ---- retry/backoff (Task A1) ------------------------------------------------

import time as _time  # noqa: E402

class FlakyHttpClient:
    """Raises a connection error `fail_times` times, then returns `response`."""

    def __init__(self, fail_times, response, exc=None):
        self.fail_times = fail_times
        self.response = response
        self.exc = exc or ConnectionError("connection refused")
        self.calls = 0

    def post(self, url, json):
        self.calls += 1
        if self.calls <= self.fail_times:
            raise self.exc
        return self.response

    def close(self):
        pass

class SequenceHttpClient:
    """Returns the given responses in order, one per call."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = 0

    def post(self, url, json):
        r = self.responses[self.calls]
        self.calls += 1
        return r

    def close(self):
        pass

def test_add_retries_transient_connection_error_then_succeeds():
    flaky = FlakyHttpClient(2, StubResponse(200, {"id": "ok"}))
    client = run.MemoryClient("http://x:8765", client=flaky,
                              max_attempts=5, sleep=lambda _d: None)
    ok, err = client.add("t", {})
    assert ok is True and err is None
    assert flaky.calls == 3  # 2 failures + 1 success

def test_add_gives_up_after_max_attempts():
    flaky = FlakyHttpClient(99, StubResponse(200, {"id": "never"}))
    client = run.MemoryClient("http://x:8765", client=flaky,
                              max_attempts=4, sleep=lambda _d: None)
    ok, err = client.add("t", {})
    assert ok is False
    assert flaky.calls == 4
    assert "request error" in err

def test_add_retries_5xx_then_succeeds():
    seq = SequenceHttpClient([
        StubResponse(503, None),
        StubResponse(503, None),
        StubResponse(200, {"id": "ok"}),
    ])
    client = run.MemoryClient("http://x:8765", client=seq,
                              max_attempts=5, sleep=lambda _d: None)
    ok, err = client.add("t", {})
    assert ok is True and err is None
    assert seq.calls == 3

def test_add_does_not_retry_4xx():
    stub = StubHttpClient(StubResponse(400, {"detail": "bad"}))
    client = run.MemoryClient("http://x:8765", client=stub,
                              max_attempts=5, sleep=lambda _d: None)
    ok, err = client.add("t", {})
    assert ok is False and "400" in err
    assert stub.calls == 1  # no retry on a 4xx

def test_retry_delay_uses_full_jitter_and_cap():
    client = run.MemoryClient("http://x:8765",
                              client=StubHttpClient(StubResponse(200, {"id": "x"})),
                              backoff_base=1.0, backoff_cap=30.0, rng=lambda: 1.0)
    assert client._retry_delay(1) == 1.0    # min(30, 1*2^0) * 1.0
    assert client._retry_delay(10) == 30.0  # min(30, 1*2^9) capped to 30
