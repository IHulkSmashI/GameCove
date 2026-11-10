"""Review 2, problem 1: a database past the app's unpack cap was published and
every device threw it away. The build must fail instead."""

import os

import pytest

from gamedb import build


def test_build_cap_matches_the_app():
    assert build.app_max_unpacked() == build.MAX_UNPACKED


def test_app_cap_parse(tmp_path):
    gd = tmp_path / "gamedb.gd"
    gd.write_text("extends Node\nconst MAX_UNPACKED := 3 * 1024 * 1024\n")
    assert build.app_max_unpacked(str(gd)) == 3 * 1024 * 1024
    assert build.app_max_unpacked(str(tmp_path / "missing.gd")) is None


def _doc(n):
    return build.document([{"title": f"Game {i}", "ids": {"steam": [str(i)]}} for i in range(n)], {})


def test_write_refuses_a_file_past_the_cap(tmp_path):
    out = tmp_path / "gamedb.json.gz"
    with pytest.raises(build.TooLarge):
        build.write(_doc(50), str(out), cap=200)
    assert not out.exists()
    assert build.write(_doc(1), str(out), cap=10_000) > 0


def test_main_fails_past_the_cap(tmp_path, monkeypatch):
    monkeypatch.setattr(build, "build", lambda *a, **k: _doc(50))
    monkeypatch.setattr(build, "MAX_UNPACKED", 200)
    out = tmp_path / "gamedb.json.gz"
    assert build.main(["--out", str(out)]) == 1
    assert not os.path.exists(out)
