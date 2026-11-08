"""HTTP with retries, Retry-After, backoff and a time budget (stdlib only).

Every source goes through `Client.get`. It retries 429, 5xx and network errors,
waits for the server's Retry-After when one is sent (seconds or an HTTP date),
otherwise backs off exponentially, and remembers the slowest pace a server has
asked for so the next request doesn't trip the limit again. It never waits past
the `Budget`: when the next wait wouldn't fit it raises `GiveUp` straight away,
so a source that's down costs minutes, not the whole nightly job.

Tests pass a fake `opener`, `sleep` and `clock`; nothing here touches the
network unless the default opener is used.
"""

from __future__ import annotations

import email.utils
import time
import urllib.error
import urllib.request
from typing import Callable

USER_AGENT = "GameCove-gamedb/0.2 (https://github.com/IHulkSmashI/GameCove)"
RETRY_STATUS = {429, 500, 502, 503, 504}


class GiveUp(Exception):
    """A source could not be fetched within its attempts or time budget."""


class NotFound(GiveUp):
    """HTTP 404: there is nothing to retry."""


class Budget:
    """Wall-clock allowance shared by every request a source makes."""

    def __init__(self, seconds: float, clock: Callable[[], float] = time.monotonic):
        self.clock = clock
        self.deadline = clock() + seconds

    def remaining(self) -> float:
        return max(0.0, self.deadline - self.clock())

    def child(self, seconds: float) -> "Budget":
        """A smaller budget that also ends no later than this one."""
        return Budget(min(seconds, self.remaining()), self.clock)


def retry_after(value: str | None, now: float | None = None) -> float | None:
    """Seconds to wait from a Retry-After header, or None if absent/unreadable."""
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return float(value)
    try:
        when = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if when is None:
        return None
    now = time.time() if now is None else now
    return max(0.0, when.timestamp() - now)


def _urlopen(req: urllib.request.Request, timeout: float):
    return urllib.request.urlopen(req, timeout=timeout)


class Client:
    def __init__(
        self,
        budget: Budget,
        *,
        opener: Callable = _urlopen,
        sleep: Callable[[float], None] = time.sleep,
        attempts: int = 6,
        backoff: float = 5.0,
        max_backoff: float = 120.0,
        min_interval: float = 0.0,
        timeout: float = 120.0,
    ):
        self.budget = budget
        self.opener = opener
        self.sleep = sleep
        self.attempts = attempts
        self.backoff = backoff
        self.max_backoff = max_backoff
        self.min_interval = min_interval  # grows when a server asks us to slow down
        self.timeout = timeout
        self._last: float | None = None

    def _wait(self, seconds: float, why: str) -> None:
        if seconds <= 0:
            return
        if seconds > self.budget.remaining():
            raise GiveUp(f"{why}; next try in {seconds:.0f}s would pass the time budget")
        self.sleep(seconds)

    def _pace(self) -> None:
        if self._last is not None and self.min_interval > 0:
            gap = self._last + self.min_interval - self.budget.clock()
            self._wait(gap, "rate limited")
        self._last = self.budget.clock()

    def get(self, url: str, headers: dict | None = None, data: bytes | None = None,
            method: str | None = None) -> bytes:
        hdrs = {"User-Agent": USER_AGENT, **(headers or {})}
        where = url.split("?", 1)[0]  # never echo query strings (they can hold secrets)
        last_err = "no attempts made"
        for attempt in range(self.attempts):
            if self.budget.remaining() <= 0:
                raise GiveUp(f"time budget used up ({last_err})")
            self._pace()
            req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
            wait = None
            try:
                with self.opener(req, min(self.timeout, max(1.0, self.budget.remaining()))) as r:
                    return r.read()
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    raise NotFound(f"HTTP 404 from {where}") from e
                if e.code not in RETRY_STATUS:
                    raise GiveUp(f"HTTP {e.code} from {where}") from e
                last_err = f"HTTP {e.code}"
                wait = retry_after(e.headers.get("Retry-After") if e.headers else None)
                if wait is not None:
                    self.min_interval = max(self.min_interval, wait)
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
                last_err = f"{type(e).__name__}: {e}"
            if attempt == self.attempts - 1:
                break
            if wait is None:
                wait = min(self.max_backoff, self.backoff * 2 ** attempt)
            self._wait(wait, last_err)
        raise GiveUp(f"gave up on {where} after {self.attempts} attempts ({last_err})")
