import email.utils
import io
import urllib.error

import pytest

from gamedb import net


class Clock:
    def __init__(self):
        self.t = 1000.0
        self.sleeps = []

    def __call__(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


class Resp(io.BytesIO):
    pass


def http_error(code, retry_after=None):
    hdrs = {"Retry-After": retry_after} if retry_after is not None else {}
    return urllib.error.HTTPError("https://x", code, "err", hdrs, None)


def opener_from(script, seen):
    """script: list of bytes (success) or exceptions, consumed in order."""
    def opener(req, timeout):
        seen.append((req.full_url, timeout))
        item = script.pop(0)
        if isinstance(item, Exception):
            raise item
        return Resp(item)
    return opener


def client(script, seen, clock, seconds=600, **kw):
    return net.Client(net.Budget(seconds, clock), opener=opener_from(script, seen), sleep=clock.sleep, **kw)


def test_honours_retry_after_seconds_and_keeps_that_pace():
    clock, seen = Clock(), []
    c = client([http_error(429, "60"), b"one", b"two"], seen, clock)
    assert c.get("https://q") == b"one"
    assert clock.sleeps == [60]
    assert c.get("https://q") == b"two"
    assert clock.sleeps == [60, 60]  # second request spaced by the 1 req/min the server asked for


def test_retry_after_http_date():
    now = 1_700_000_000
    date = email.utils.formatdate(now + 30, usegmt=True)
    assert net.retry_after(date, now=now) == pytest.approx(30)
    assert net.retry_after("garbage") is None
    assert net.retry_after(None) is None


def test_exponential_backoff_without_retry_after():
    clock, seen = Clock(), []
    err = urllib.error.URLError("reset")
    c = client([http_error(503), err, http_error(502), b"ok"], seen, clock, backoff=5, max_backoff=12)
    assert c.get("https://q") == b"ok"
    assert clock.sleeps == [5, 10, 12]


def test_gives_up_when_retry_after_exceeds_budget():
    clock, seen = Clock(), []
    c = client([http_error(429, "3600")], seen, clock, seconds=300)
    with pytest.raises(net.GiveUp, match="time budget"):
        c.get("https://q")
    assert clock.sleeps == [] and len(seen) == 1


def test_non_retryable_status_fails_fast():
    clock, seen = Clock(), []
    c = client([http_error(404)], seen, clock)
    with pytest.raises(net.GiveUp, match="404"):
        c.get("https://q")
    assert clock.sleeps == []


def test_gives_up_after_attempts():
    clock, seen = Clock(), []
    c = client([http_error(500)] * 3, seen, clock, attempts=3, backoff=1)
    with pytest.raises(net.GiveUp, match="3 attempts"):
        c.get("https://q")
    assert len(seen) == 3 and clock.sleeps == [1, 2]


def test_request_timeout_never_exceeds_remaining_budget():
    clock, seen = Clock(), []
    c = client([b"ok"], seen, clock, seconds=30, timeout=120)
    c.get("https://q")
    assert seen[0][1] == 30


def test_child_budget_capped_by_parent():
    clock = Clock()
    parent = net.Budget(100, clock)
    assert parent.child(500).remaining() == 100
    assert parent.child(20).remaining() == 20


def test_errors_never_include_query_strings():
    clock, seen = Clock(), []
    c = client([http_error(401)], seen, clock)
    with pytest.raises(net.GiveUp) as e:
        c.get("https://id.example/token?client_secret=hunter2")
    assert "hunter2" not in str(e.value)
