"""No network in the helper's tests: the signed index, cosign and every download are faked per test."""
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import mirror  # noqa: E402


@pytest.fixture(autouse=True)
def _no_network(monkeypatch):
    def offline(url, limit, timeout):
        raise OSError(f"no network in tests: {url}")
    monkeypatch.setattr(mirror, "_fetch", offline)
    monkeypatch.delenv("GAMECOVE_COSIGN", raising=False)
    mirror._memo.clear()


@pytest.fixture(autouse=True)
def _no_downloads(monkeypatch):
    """downloads.download fails unless a test fakes it (it used to reach the real upstream when a fixture lacked a
    file)."""
    from gamecove_upscale import downloads

    def offline(url, dest, timeout=60.0):
        raise OSError(f"no network in tests: {url}")
    monkeypatch.setattr(downloads, "download", offline)
