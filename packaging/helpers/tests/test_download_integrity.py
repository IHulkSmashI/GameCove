"""Integrity rules for everything the helper downloads (review H7, L36): every versions.json download is pinned by
sha256, fetch() refuses a pinned entry without one and never falls back to a same-origin digest for the pinned tag,
and archives may not carry links."""
import json
import os
import sys
import tarfile
import zipfile

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from gamecove_upscale import downloads  # noqa: E402

VERSIONS = os.path.join(os.path.dirname(__file__), "..", "gamecove_upscale", "data", "versions.json")
HEX64 = set("0123456789abcdef")


def _hex(s):
    return isinstance(s, str) and len(s) == 64 and set(s) <= HEX64


def _evil_zip(path):
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("xess-xmx-linux-20261104/install.sh", "#!/bin/bash\necho ATTACKER\n")
    return path


def _fake_download(src):
    def dl(url, dest, timeout=60.0):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(src, "rb") as i, open(dest, "wb") as o:
            o.write(i.read())
        return dest
    return dl


def test_every_versions_entry_is_hash_pinned():
    v = json.load(open(VERSIONS, encoding="utf-8"))
    for key, e in v.items():
        if key.startswith("_"):
            continue
        if "files" in e and "base" in e:                     # raw files pinned by commit, one hash each
            assert e["files"] and all(_hex(h) for h in e["files"].values()), key
            continue
        assert _hex(e.get("sha256")), f"{key} has no sha256 pin"
        for x in e.get("extras", []):
            assert _hex(x.get("sha256")), f"{key}/{x.get('name')} has no sha256 pin"


# The tested OptiPatcher build is only published upstream on a rolling tag (no immutable release carries the same
# bytes; the official optiscaler/OptiPatcher v0.20-v0.42 assets all differ). Its "mirror" (GameCove's own release,
# immutable name, mirror.py) is tried first; the rolling upstream URL is only the second source, and the hash still
# protects it: when upstream rolls, that source answers "does not match" instead of running something else.
ROLLING_ALLOWED = {"https://github.com/xXJSONDeruloXx/OptiScaler-Bleeding-Edge/releases/download/"
                   "bins-for-optipatcher-rolling/OptiPatcher_rolling.asi"}


def test_downloads_use_immutable_urls():
    """A hash on a rolling URL breaks at the next upstream roll (L36): no 'rolling'/'latest' URLs beyond the known one."""
    v = json.load(open(VERSIONS, encoding="utf-8"))
    urls = []
    for key, e in v.items():
        if isinstance(e, dict):
            urls += [e.get("url", "")] + [x.get("url", "") for x in e.get("extras", [])]
    for u in filter(None, urls):
        assert u.startswith("https://"), u
        assert u in ROLLING_ALLOWED or ("rolling" not in u and "/latest/" not in u), u


def test_xess_entry_pins_the_tested_zip():
    e = json.load(open(VERSIONS, encoding="utf-8"))["xess_xmx_linux"]
    assert e["tag"] == "20261104"
    assert e["sha256"] == "4d97b77e44f22235a567d0b5317421e65566089dc08a6a0caf9fa16549433173"


def test_fetch_refuses_pinned_entry_without_sha256(tmp_path, monkeypatch):
    """The review's proof2.py: an entry with a tag but no sha256 and a release answer without a digest used to be
    unpacked with no check at all."""
    monkeypatch.setattr(downloads, "download", _fake_download(_evil_zip(tmp_path / "evil.zip")))
    entry = {"repo": "HHHHanasak1/xess-xmx-linux", "tag": "20261104", "asset_glob": "xess-xmx-linux-*.zip"}
    rel = {"tag_name": "20261104", "assets": [{"name": "xess-xmx-linux-20261104.zip",
                                                "browser_download_url": "https://example.invalid/x.zip"}]}
    with pytest.raises(PermissionError):
        downloads.fetch(entry, str(tmp_path / "w"), rel=rel)
    # a same-origin digest is not a substitute for the pin
    rel["assets"][0]["digest"] = "sha256:" + downloads.sha256_of(str(tmp_path / "evil.zip"))
    with pytest.raises(PermissionError):
        downloads.fetch(entry, str(tmp_path / "w2"), rel=rel)
    assert not (tmp_path / "w" / "xess-xmx-linux-20261104").exists()


def test_fetch_rejects_wrong_hash_and_accepts_right_one(tmp_path, monkeypatch):
    z = _evil_zip(tmp_path / "pkg.zip")
    monkeypatch.setattr(downloads, "download", _fake_download(z))
    rel = {"tag_name": "t1", "assets": [{"name": "pkg.zip", "browser_download_url": "https://example.invalid/p.zip"}]}
    bad = {"repo": "a/b", "tag": "t1", "asset_glob": "*.zip", "sha256": "0" * 64}
    with pytest.raises(ValueError):
        downloads.fetch(bad, str(tmp_path / "w"), rel=rel)
    good = dict(bad, sha256=downloads.sha256_of(str(z)))
    assert os.path.isdir(downloads.fetch(good, str(tmp_path / "w"), rel=rel)["dir"])


def test_fetch_untested_latest_needs_a_digest(tmp_path, monkeypatch):
    """'latest (untested)' has no pin by definition: it needs at least GitHub's recorded digest, never nothing."""
    z = _evil_zip(tmp_path / "pkg.zip")
    monkeypatch.setattr(downloads, "download", _fake_download(z))
    entry = {"repo": "a/b", "tag": "t1", "asset_glob": "*.zip", "sha256": "0" * 64}
    rel = {"tag_name": "t2", "assets": [{"name": "pkg.zip", "browser_download_url": "https://example.invalid/p.zip"}]}
    with pytest.raises(PermissionError):
        downloads.fetch(entry, str(tmp_path / "w"), allow_unpinned=True, rel=rel)
    rel["assets"][0]["digest"] = "sha256:" + downloads.sha256_of(str(z))
    assert downloads.fetch(entry, str(tmp_path / "w"), allow_unpinned=True, rel=rel)["tag"] == "t2"


def test_extract_rejects_links(tmp_path):
    t = tmp_path / "l.tar"
    with tarfile.open(t, "w") as tf:
        info = tarfile.TarInfo("pkg/link")
        info.type = tarfile.SYMTYPE
        info.linkname = "inside"
        tf.addfile(info)
    with pytest.raises(ValueError):
        downloads.extract(str(t), str(tmp_path / "o"))
    zl = tmp_path / "l.zip"
    with zipfile.ZipFile(zl, "w") as z:
        zi = zipfile.ZipInfo("pkg/link")
        zi.external_attr = (0o120777 << 16)
        z.writestr(zi, "/etc/passwd")
    with pytest.raises(ValueError):
        downloads.extract(str(zl), str(tmp_path / "o2"))


def test_fetch_pinned_entry_refuses_another_tag(tmp_path, monkeypatch):
    """Review problem 9: a pinned entry whose release answer names another tag fell back to GitHub's digest."""
    z = _evil_zip(tmp_path / "pkg.zip")
    monkeypatch.setattr(downloads, "download", _fake_download(z))
    entry = {"repo": "a/b", "tag": "t1", "asset_glob": "*.zip", "sha256": "0" * 64}
    rel = {"tag_name": "t2", "assets": [{"name": "pkg.zip", "browser_download_url": "https://example.invalid/p.zip",
                                         "digest": "sha256:" + downloads.sha256_of(str(z))}]}
    with pytest.raises(PermissionError):
        downloads.fetch(entry, str(tmp_path / "w"), rel=rel)
    assert not (tmp_path / "w" / "b-t2").exists()


@pytest.mark.parametrize("field,value", [("name", "../../evil.zip"), ("name", "ABS"), ("name", ".."),
                                         ("tag", "../x"), ("tag", "a/b")])
def test_fetch_refuses_unsafe_asset_names_and_tags(tmp_path, monkeypatch, field, value):
    z = _evil_zip(tmp_path / "pkg.zip")
    monkeypatch.setattr(downloads, "download", _fake_download(z))
    entry = {"repo": "a/b", "tag": "latest", "asset_glob": "*"}
    asset = {"name": "pkg.zip", "browser_download_url": "https://example.invalid/p.zip",
             "digest": "sha256:" + downloads.sha256_of(str(z))}
    rel = {"tag_name": "t1", "assets": [asset]}
    if value == "ABS":
        value = str(tmp_path / "abs-evil.zip")   # an absolute path, inside this test's folder
    if field == "name":
        asset["name"] = value
    else:
        rel["tag_name"] = value
    with pytest.raises(ValueError):
        downloads.fetch(entry, str(tmp_path / "w"), allow_unpinned=True, rel=rel)
