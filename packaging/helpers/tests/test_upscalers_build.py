"""tools/upscalers/build.py, what the nightly workflow runs: the newest upstream builds and every tested pin go to
the mirror under immutable names, archives pass the helper's own checks, a bad night keeps the previous entries, and
the index it writes is one the helper accepts. GitHub is faked (FakeNet); nothing touches the network."""
import hashlib
import io
import json
import os
import sys
import zipfile

import pytest

HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, ".."))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "tools", "upscalers"))

import build  # noqa: E402
from gamecove_upscale import mirror  # noqa: E402


def sha(b):
    return hashlib.sha256(b).hexdigest()


def zbytes(files, link=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for n, t in files.items():
            z.writestr(n, t)
        if link:
            zi = zipfile.ZipInfo(link)
            zi.external_attr = 0o120777 << 16
            z.writestr(zi, "/etc/passwd")
    return buf.getvalue()


OPTI_PIN = zbytes({"OptiScaler.dll": "o94", "OptiScaler.ini": "[x]"})
XESS_PIN = zbytes({"xess-xmx-linux-20261104/install.sh": "echo", "xess-xmx-linux-20261104/uninstall.sh": "echo"})
XESS_NEW = zbytes({"xess-xmx-linux-20261120/install.sh": "echo new", "xess-xmx-linux-20261120/uninstall.sh": "echo"})
REF_PIN = zbytes({"dinput8.dll": "ref15"})
PATCHER_PIN = b"tested optipatcher"
PATCHER_NOW = b"optipatcher rolled since"
FNV = zbytes({"fakenvapi.dll": "fnv"})
FSR_AMD = b"amd dll"
FSR_XMX = b"nitec dll"
NOTICE = b"AMD licence text"
AMD_COMMIT = "7539ae8b6568ad29ed78a753404351daf3b5cca7"
XMX_COMMIT = "34a8210e75962eaa3b7b1bf55c6f915eb036c3f6"


def murl(comp, ver, data, fn):
    return mirror.mirror_url(mirror.mirror_name(comp, ver, sha(data), fn))


def versions():
    up = "https://github.com"
    return {
        "xess_xmx_linux": {"repo": "HHHHanasak1/xess-xmx-linux", "tag": "20261104", "version": "20261104",
                           "asset": "xess-xmx-linux-20261104.zip", "sha256": sha(XESS_PIN),
                           "url": f"{up}/HHHHanasak1/xess-xmx-linux/releases/download/20261104/xess-xmx-linux-20261104.zip",
                           "mirror": murl("xess_xmx_linux", "20261104", XESS_PIN, "xess-xmx-linux-20261104.zip")},
        "reframework": {"repo": "onehoon/REFramework", "tag": "fork-release-15", "version": "fork-release-15",
                        "asset": "REFramework.zip", "sha256": sha(REF_PIN), "dll_sha256": sha(b"ref15"),
                        "url": f"{up}/onehoon/REFramework/releases/download/fork-release-15/REFramework.zip",
                        "mirror": murl("reframework", "fork-release-15", REF_PIN, "REFramework.zip")},
        "optiscaler": {"version": "0.9.4", "repo": "optiscaler/OptiScaler", "tag": "v0.9.4", "sha256": sha(OPTI_PIN),
                       "url": f"{up}/optiscaler/OptiScaler/releases/download/v0.9.4/Optiscaler_0.9.4.zip",
                       "mirror": murl("optiscaler", "0.9.4", OPTI_PIN, "Optiscaler_0.9.4.zip"),
                       "extras": [{"name": "OptiPatcher", "version": "rolling-dfg017", "sha256": sha(PATCHER_PIN),
                                   "url": f"{up}/xXJSONDeruloXx/OptiScaler-Bleeding-Edge/releases/download/bins-for-optipatcher-rolling/OptiPatcher_rolling.asi",
                                   "mirror": murl("optipatcher", "rolling-dfg017", PATCHER_PIN, "OptiPatcher_rolling.asi"),
                                   "dest": "plugins/OptiPatcher.asi"}]},
        "fsr4_amd": {"repo": "GPUOpen-LibrariesAndSDKs/FidelityFX-SDK", "version": "sdk2.4.0-7539ae8b",
                     "base": f"https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/{AMD_COMMIT}/Kits/FidelityFX/signedbin",
                     "files": {"amd_fidelityfx_upscaler_dx12.dll": sha(FSR_AMD)}, "notice": "Kits/FidelityFX/docs/license.md",
                     "mirror": {"amd_fidelityfx_upscaler_dx12.dll": murl("fsr4_amd", "sdk2.4.0-7539ae8b", FSR_AMD, "amd_fidelityfx_upscaler_dx12.dll")}},
        "fsr4_xmx": {"repo": "IHulkSmashI/ClawDeck", "version": "4.1.2-34a8210e",
                     "base": f"https://raw.githubusercontent.com/IHulkSmashI/ClawDeck/{XMX_COMMIT}",
                     "files": {"fsr-original.dll": sha(FSR_AMD), "amd_fidelityfx_upscaler_dx12.dll": sha(FSR_XMX)},
                     "mirror": {"fsr-original.dll": murl("fsr4_xmx", "4.1.2-34a8210e", FSR_AMD, "fsr-original.dll"),
                                "amd_fidelityfx_upscaler_dx12.dll": murl("fsr4_xmx", "4.1.2-34a8210e", FSR_XMX, "amd_fidelityfx_upscaler_dx12.dll")}},
    }


class FakeNet(build.Net):
    def __init__(self, files, api):
        super().__init__("")
        self.files, self.api, self.got = files, api, []

    def json(self, path):
        v = self.api.get(path)
        if v is None or isinstance(v, Exception):
            raise v or OSError(f"404 {path}")
        return v

    def download(self, url, dest):
        self.got.append(url)
        if url not in self.files:
            raise OSError(f"404 {url}")
        with open(dest, "wb") as f:
            f.write(self.files[url])


def rel(tag, asset, data, digest=True, pre=False, date="2026-11-08T00:00:00Z"):
    url = f"https://github.com/x/y/releases/download/{tag}/{asset}"
    a = {"name": asset, "browser_download_url": url}
    if digest:
        a["digest"] = "sha256:" + sha(data)
    return {"tag_name": tag, "prerelease": pre, "draft": False, "published_at": date, "html_url": "https://x",
            "assets": [a]}, url, data


def world(xess_new=XESS_NEW, patcher=PATCHER_NOW, xess_digest=True):
    v = versions()
    files = {
        v["xess_xmx_linux"]["url"]: XESS_PIN, v["reframework"]["url"]: REF_PIN, v["optiscaler"]["url"]: OPTI_PIN,
        v["optiscaler"]["extras"][0]["url"]: patcher,
        v["fsr4_amd"]["base"] + "/amd_fidelityfx_upscaler_dx12.dll": FSR_AMD,
        f"https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/{AMD_COMMIT}/Kits/FidelityFX/docs/license.md": NOTICE,
        v["fsr4_xmx"]["base"] + "/fsr-original.dll": FSR_AMD, v["fsr4_xmx"]["base"] + "/amd_fidelityfx_upscaler_dx12.dll": FSR_XMX,
        "https://github.com/optiscaler/OptiScaler/archive/refs/tags/v0.9.4.tar.gz": b"source 0.9.4",
    }
    api = {}
    r, u, d = rel("20261120", "xess-xmx-linux-20261120.zip", xess_new, digest=xess_digest)
    files[u] = d
    api["/repos/HHHHanasak1/xess-xmx-linux/releases?per_page=15"] = [r]
    r, u, d = rel("fork-release-15", "REFramework.zip", REF_PIN)
    files[u] = d
    api["/repos/onehoon/REFramework/releases?per_page=15"] = [r]
    r, u, d = rel("v1.4.1", "fakenvapi-v1.4.1.zip", FNV)
    files[u] = d
    api["/repos/FakeMichau/fakenvapi/releases?per_page=15"] = [r]
    build.SOURCES["fakenvapi"]["asset"] = "fakenvapi-*.zip"            # zip here: no 7z on the test machine
    api["/repos/xXJSONDeruloXx/OptiScaler-Bleeding-Edge/releases/tags/bins-for-optipatcher-rolling"] = {
        "assets": [{"name": "OptiPatcher_rolling.asi", "updated_at": "2026-11-07T10:00:00Z", "digest": "sha256:" + sha(patcher)}]}
    api["/repos/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/commits?per_page=1&path=Kits/FidelityFX/signedbin"] = [
        {"sha": AMD_COMMIT, "commit": {"committer": {"date": "2026-10-28T00:00:00Z"}}}]
    api["/repos/IHulkSmashI/ClawDeck/commits?per_page=1&sha=fsr4-xmx-files"] = [
        {"sha": XMX_COMMIT, "commit": {"committer": {"date": "2026-11-05T00:00:00Z"}}}]
    # OptiScaler (both kinds): the API is down tonight -> the pin (stable) and nothing (v10, no pin here)
    return v, FakeNet(files, api)


@pytest.fixture(autouse=True)
def _restore_sources():
    saved = json.loads(json.dumps(build.SOURCES))
    yield
    build.SOURCES.clear()
    build.SOURCES.update(saved)


def _run(tmp_path, v, net, name="dist", have=None, previous=None):
    vp = tmp_path / "versions.json"
    vp.write_text(json.dumps(v))
    out = tmp_path / name
    rep = build.build(net, str(vp), str(out), have, previous, now="2026-11-09T05:41:00Z")
    idx = mirror.parse((out / "upscalers.json").read_bytes())
    plan = [ln.split("\t") for ln in (out / "upload-plan.tsv").read_text().splitlines()]
    return rep, idx, plan, out


def _have(tmp_path, plans):
    p = tmp_path / "have.tsv"
    p.write_text("".join(f"{t}\t{n}\t1\n" for plan in plans for t, n, _ in plan))
    return str(p)


def test_first_run_fills_the_mirror_with_every_pin_and_the_newest(tmp_path):
    v, net = world()
    rep, idx, plan, out = _run(tmp_path, v, net)
    names = {n for _t, n, _p in plan}
    assert {t for t, _n, _p in plan} == {"upscalers"}
    # part A: every tested file under exactly the name versions.json expects ...
    for it in build.pin_items(v):
        if it["component"] != "optipatcher":
            assert it["mirror"].rsplit("/", 1)[1] in names, it["mirror"]
    assert any(n.startswith("fsr4_amd-sdk2.4.0-7539ae8b-") and n.endswith("license.md") for n in names), "AMD's notice"
    assert any(n.startswith("optiscaler-0.9.4-source-") for n in names), "the GPL source next to OptiScaler"
    # ... except the rolled OptiPatcher, which is reported with how to upload it by hand
    assert any("optipatcher" in w and "gh release upload upscalers" in w for w in rep["warnings"])
    # part B: the newest of each
    c = idx["components"]
    assert c["xess_xmx_linux"]["version"] == "20261120" and c["xess_xmx_linux"]["upstream_digest"] is True
    assert c["optipatcher"]["version"] == "rolling-20261107" and c["optipatcher"]["sha256"] == sha(PATCHER_NOW)
    assert c["fakenvapi"]["inner"] == {"fakenvapi.dll": sha(b"fnv")}
    assert c["reframework"]["inner"] == {"dinput8.dll": sha(b"ref15")}
    assert c["fsr4_amd"]["version"] == "20261028-7539ae8b" and c["fsr4_amd"]["notice_url"].endswith("license.md")
    assert c["optiscaler"]["version"] == "0.9.4" and c["optiscaler"]["pinned"] is True, "API down: the pin, mirrored"
    assert "optiscaler_v10" not in c
    for e in c.values():
        for f in [e] if "mirror_url" in e else e["files"].values():
            assert f["mirror_url"].rsplit("/", 1)[1] in names
    # every planned file is really there, with the bytes its name's hash says
    for t, n, p in plan:
        assert sha((out / p).read_bytes())[:8] in n or "source" in n or n.endswith("license.md")


def test_second_run_uploads_nothing_new(tmp_path):
    v, net = world()
    _r, idx1, plan1, out1 = _run(tmp_path, v, net, "d1")
    v, net = world()
    rep, idx2, plan2, _o = _run(tmp_path, v, net, "d2", _have(tmp_path, [plan1]), str(out1 / "upscalers.json"))
    assert plan2 == [] and idx2["components"] == idx1["components"]


def test_link_in_a_new_archive_is_refused_and_the_previous_entry_kept(tmp_path):
    v, net = world()
    _r, idx1, plan1, out1 = _run(tmp_path, v, net, "d1")
    evil = zbytes({"x/install.sh": "echo", "x/uninstall.sh": "echo"}, link="x/lib/active")
    v, net = world(xess_new=evil)
    net.api["/repos/HHHHanasak1/xess-xmx-linux/releases?per_page=15"][0]["tag_name"] = "20261201"
    rep, idx2, plan2, _o = _run(tmp_path, v, net, "d2", _have(tmp_path, [plan1]), str(out1 / "upscalers.json"))
    assert idx2["components"]["xess_xmx_linux"] == idx1["components"]["xess_xmx_linux"]
    assert any("xess_xmx_linux" in w and "unsafe" in w for w in rep["warnings"]), rep["warnings"]
    assert plan2 == []


def test_digest_mismatch_is_refused(tmp_path):
    v, net = world()
    net.api["/repos/HHHHanasak1/xess-xmx-linux/releases?per_page=15"][0]["assets"][0]["digest"] = "sha256:" + "0" * 64
    rep, idx, plan, _o = _run(tmp_path, v, net)
    assert idx["components"]["xess_xmx_linux"]["version"] == "20261104", "the pin, not the mismatching build"
    assert any("digest upstream publishes" in w for w in rep["warnings"])


def test_a_full_release_rolls_over_to_the_next_tag(tmp_path):
    v, net = world()
    _r, _i, plan1, out1 = _run(tmp_path, v, net, "d1")
    have = tmp_path / "have.tsv"
    have.write_text("".join(f"upscalers\t{n}\t1\n" for _t, n, _p in plan1) +
                    "".join(f"upscalers\tfiller-{i}\t1\n" for i in range(build.ASSETS_PER_TAG)))
    v, net = world(xess_new=zbytes({"y/install.sh": "echo 2", "y/uninstall.sh": "echo"}))
    net.api["/repos/HHHHanasak1/xess-xmx-linux/releases?per_page=15"][0]["tag_name"] = "20261202"
    _rep, idx, plan, _o = _run(tmp_path, v, net, "d2", str(have), str(out1 / "upscalers.json"))
    assert [t for t, _n, _p in plan] == ["upscalers-2"]
    assert "/upscalers-2/" in idx["components"]["xess_xmx_linux"]["mirror_url"]
    assert mirror.is_mirror_url(idx["components"]["xess_xmx_linux"]["mirror_url"])


def test_amd_dll_without_its_notice_is_not_mirrored(tmp_path):
    v, net = world()
    for u in list(net.files):
        if u.endswith("license.md"):
            del net.files[u]
    rep, idx, plan, _o = _run(tmp_path, v, net)
    assert not any(n.startswith("fsr4_amd-") for _t, n, _p in plan)
    assert "fsr4_amd" not in idx["components"]
