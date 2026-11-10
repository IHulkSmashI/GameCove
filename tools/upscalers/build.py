#!/usr/bin/env python3
"""Build upscalers.json and the mirror's new files (.github/workflows/upscalers.yml runs this nightly).

For every upscaler component GameCove installs:
  1. find the newest upstream build: the GitHub releases API (OptiScaler, the OptiScaler v10 nightly, fakenvapi,
     xess-xmx-linux, REFramework), the rolling OptiPatcher asset (downloaded and hashed: a new hash is a new build),
     and the newest commit of the FSR 4 files (AMD's FidelityFX SDK, ClawDeck's fsr4-xmx-files branch);
  2. download it, check the digest upstream publishes (GitHub's asset "digest") where there is one, compute sha256
     and size, and for archives run the helper's own extraction checks (no absolute paths, no '..', no links or
     device nodes) and check that the files GameCove needs are in it;
  3. put it in dist/upload/<tag>/ under its immutable mirror name (gamecove_upscale.mirror.mirror_name) unless the
     mirror already has that name. Nothing is ever deleted from the mirror, so every pinned hash keeps resolving;
  4. the same for every pin in versions.json (part A: the tested files, under the names versions.json expects), so
     the first run fills the mirror with what GameCove was tested with;
  5. write dist/upscalers.json (schema 1). A component whose upstream can't be read or fails a check keeps the
     previous index's entry (or the pin), so a bad night never removes anything.

The workflow then uploads dist/upload/*/* (never --clobber), and only after that signs and publishes the index.

  build.py --versions versions.json --out dist [--have assets.tsv] [--previous upscalers.json]
  assets.tsv: "<tag>\t<name>\t<size>" per file already on the mirror's releases (gh release view --json assets)
"""
from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "packaging", "helpers"))

from gamecove_upscale import downloads, mirror  # noqa: E402

API = "https://api.github.com"
MAX_FILE = 1 << 30
ASSETS_PER_TAG = 950          # GitHub allows 1000 assets per release; then "upscalers-2", ...

# where each component comes from upstream (versions.json keeps how it's installed)
SOURCES = {
    "optiscaler": {"kind": "release", "repo": "optiscaler/OptiScaler", "asset": "optiscaler_*.7z", "prerelease": False,
                   "version": "tag", "require_root": ["OptiScaler.dll", "OptiScaler.ini"], "gpl_source": True},
    "optiscaler_v10": {"kind": "release", "repo": "optiscaler/OptiScaler-nightly", "asset": "optiscaler_v*.7z",
                       "prerelease": True, "version": "asset", "require_root": ["OptiScaler.dll", "OptiScaler.ini"]},
    "optipatcher": {"kind": "rolling", "repo": "xXJSONDeruloXx/OptiScaler-Bleeding-Edge",
                    "tag": "bins-for-optipatcher-rolling", "asset": "OptiPatcher_rolling.asi"},
    "fakenvapi": {"kind": "release", "repo": "FakeMichau/fakenvapi", "asset": "fakenvapi-*.7z", "prerelease": False,
                  "version": "tag", "require": ["fakenvapi.dll"], "inner": ["fakenvapi.dll"]},
    "xess_xmx_linux": {"kind": "release", "repo": "HHHHanasak1/xess-xmx-linux", "asset": "xess-xmx-linux-*.zip",
                       "prerelease": False, "version": "tag", "require": ["install.sh", "uninstall.sh"]},
    "reframework": {"kind": "release", "repo": "onehoon/REFramework", "asset": "REFramework.zip", "prerelease": False,
                    "version": "tag", "require": ["dinput8.dll"], "inner": ["dinput8.dll"]},
    "fsr4_amd": {"kind": "git-files", "repo": "GPUOpen-LibrariesAndSDKs/FidelityFX-SDK", "ref": "",
                 "dir": "Kits/FidelityFX/signedbin", "files": ["amd_fidelityfx_upscaler_dx12.dll"],
                 "notice": "Kits/FidelityFX/docs/license.md"},
    "fsr4_xmx": {"kind": "git-files", "repo": "IHulkSmashI/ClawDeck", "ref": "fsr4-xmx-files", "dir": "",
                 "files": ["amd_fidelityfx_upscaler_dx12.dll", "fsr-original.dll"]},
}
ARCHIVES = (".7z", ".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar")


class Net:
    """GitHub API and downloads (tests replace it)."""

    def __init__(self, token: str = ""):
        self.token = token

    def _req(self, url: str, accept: str) -> urllib.request.Request:
        h = {"User-Agent": "GameCove-upscalers-index", "Accept": accept}
        if self.token and url.startswith(API):
            h["Authorization"] = f"Bearer {self.token}"
        return urllib.request.Request(url, headers=h)

    def json(self, path: str):
        with urllib.request.urlopen(self._req(API + path, "application/vnd.github+json"), timeout=60) as r:
            return json.load(r)

    def download(self, url: str, dest: str) -> None:
        with urllib.request.urlopen(self._req(url, "application/octet-stream"), timeout=300) as r, open(dest, "wb") as f:
            n = 0
            for chunk in iter(lambda: r.read(1 << 20), b""):
                n += len(chunk)
                if n > MAX_FILE:
                    raise ValueError(f"{url}: larger than {MAX_FILE} bytes")
                f.write(chunk)


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def sha256_of(path: str) -> str:
    return downloads.sha256_of(path)


def short_hashes(s: str) -> str:
    return re.sub(r"[0-9a-f]{40}", lambda m: m.group()[:8], s)


def version_of(spec: dict, tag: str, asset: str) -> str:
    if spec.get("version") == "asset":
        m = re.match(r"(?i)^optiscaler_v?(.+?)\.(7z|zip)$", asset)
        v = m.group(1).replace("_", "-") if m else ""
    else:
        v = short_hashes(re.sub(r"^v(?=\d)", "", tag))
    v = mirror.safe_part(v)
    if not mirror.VERSION_RE.match(v):
        raise ValueError(f"can't make a version out of {tag!r} / {asset!r}")
    return v


class Mirror:
    """What's on the mirror's releases already, and where a new file goes."""

    def __init__(self, have_tsv: str | None):
        self.where: dict[str, tuple[str, int]] = {}
        self.count: dict[str, int] = {}
        if have_tsv and os.path.exists(have_tsv):
            for line in open(have_tsv, encoding="utf-8"):
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[1]:
                    self.where[parts[1]] = (parts[0], int(parts[2]) if len(parts) > 2 and parts[2].isdigit() else 0)
                    self.count[parts[0]] = self.count.get(parts[0], 0) + 1
        self.planned: list[tuple[str, str, str]] = []      # (tag, name, local path)

    def files_tag(self) -> str:
        n = 1
        while True:
            tag = mirror.INDEX_TAG if n == 1 else f"{mirror.INDEX_TAG}-{n}"
            if self.count.get(tag, 0) < ASSETS_PER_TAG:
                return tag
            n += 1

    def url_of(self, name: str) -> str | None:
        hit = self.where.get(name)
        return mirror.mirror_url(name, hit[0]) if hit else None

    def has_prefix(self, prefix: str) -> str | None:
        return next((n for n in self.where if n.startswith(prefix)), None)

    def add(self, name: str, path: str, out: str, tag: str | None = None) -> str:
        """The mirror URL for `name`; the file is planned for upload when the mirror doesn't have it yet."""
        url = self.url_of(name)
        if url:
            return url
        tag = tag or self.files_tag()
        dest = os.path.join(out, "upload", tag, name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(path, dest)
        self.where[name] = (tag, os.path.getsize(dest))
        self.count[tag] = self.count.get(tag, 0) + 1
        self.planned.append((tag, name, dest))
        return mirror.mirror_url(name, tag)


# ---- checking a file ------------------------------------------------------------------------------------------------
def check_archive(path: str, name: str, spec: dict, work: str) -> dict:
    """The helper's extraction checks, then what GameCove needs must be in it. Returns {relative path: sha256} of
    the files listed in spec["inner"]."""
    if not name.lower().endswith(ARCHIVES):
        return {}
    out = tempfile.mkdtemp(dir=work)
    arc = os.path.join(out, "a-" + mirror.safe_part(name))
    shutil.copyfile(path, arc)
    downloads.extract(arc, os.path.join(out, "x"))           # raises on absolute paths, '..', links, device nodes
    root = os.path.join(out, "x")
    files = {}
    for r, _d, f in os.walk(root):
        for x in f:
            p = os.path.join(r, x)
            if os.path.islink(p):
                raise ValueError(f"{name}: link {x}")
            files[os.path.relpath(p, root).replace(os.sep, "/")] = p
    for req in spec.get("require_root", []):
        if req not in files:
            raise ValueError(f"{name}: no {req} at the top")
    for req in spec.get("require", []):
        if not any(k.rsplit("/", 1)[-1] == req for k in files):
            raise ValueError(f"{name}: no {req} in it")
    inner = {k: sha256_of(p) for k, p in files.items() if k.rsplit("/", 1)[-1] in spec.get("inner", [])}
    shutil.rmtree(out, ignore_errors=True)
    return inner


def fetch_checked(net: Net, url: str, name: str, work: str, want_sha: str | None = None, digest: str | None = None) -> str:
    p = os.path.join(tempfile.mkdtemp(dir=work), mirror.safe_part(name))
    net.download(url, p)
    got = sha256_of(p)
    if digest and got != digest:
        raise ValueError(f"{name}: sha256 {got} isn't the digest upstream publishes ({digest})")
    if want_sha and got != want_sha.lower():
        raise ValueError(f"{name}: sha256 {got} isn't the pinned {want_sha}")
    return p


def today() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")


# ---- the newest upstream build ----------------------------------------------------------------------------------
def newest_release(net: Net, comp: str, spec: dict, mir: Mirror, out: str, work: str, prev: dict | None) -> dict:
    rels = net.json(f"/repos/{spec['repo']}/releases?per_page=15")
    for rel in rels:
        if rel.get("draft") or (rel.get("prerelease") and not spec.get("prerelease")):
            continue
        asset = next((a for a in rel.get("assets", []) if fnmatch.fnmatch(a.get("name", "").lower(), spec["asset"].lower())), None)
        if asset:
            break
    else:
        raise ValueError(f"no release of {spec['repo']} has an asset matching {spec['asset']}")
    tag, aname = rel["tag_name"], asset["name"]
    version = version_of(spec, tag, aname)
    digest = downloads.asset_digest(asset)
    if prev and prev.get("tag") == tag and prev.get("asset") == aname and (not digest or digest == prev.get("sha256")) \
            and mir.url_of(prev["mirror_url"].rsplit("/", 1)[1]):
        return prev                                            # nothing new: no download
    path = fetch_checked(net, asset["browser_download_url"], aname, work, digest=digest)
    sha = sha256_of(path)
    inner = check_archive(path, aname, spec, work)
    entry = {"version": version, "tag": tag, "asset": aname, "date": (rel.get("published_at") or today())[:10],
             "upstream_url": asset["browser_download_url"], "sha256": sha, "size": os.path.getsize(path),
             "upstream_digest": bool(digest), "release_url": rel.get("html_url", ""),
             "mirror_url": mir.add(mirror.mirror_name(comp, version, sha, aname), path, out)}
    if inner:
        entry["inner"] = inner
    if spec.get("gpl_source"):
        entry.update(gpl_source(net, comp, spec["repo"], tag, version, mir, out, work))
    return entry


def gpl_source(net: Net, comp: str, repo: str, tag: str, version: str, mir: Mirror, out: str, work: str) -> dict:
    """The tag's source archive next to the binary (GPL-3.0 §6: the source stays available as long as the binary).
    GitHub regenerates these archives, so one per version is kept, whatever its hash."""
    url = f"https://github.com/{repo}/archive/refs/tags/{tag}.tar.gz"
    prefix = "-".join((mirror.safe_part(comp), mirror.safe_part(version), "source")) + "-"
    have = mir.has_prefix(prefix)
    if have:
        return {"source_url": url, "source_mirror_url": mir.url_of(have)}
    try:
        p = fetch_checked(net, url, f"{repo.split('/')[1]}-{tag}.tar.gz", work)
    except (OSError, ValueError, urllib.error.URLError) as e:
        log(f"warning: {comp} {version}: source archive: {e}")
        return {"source_url": url}
    name = prefix + sha256_of(p)[:8] + ".tar.gz"
    return {"source_url": url, "source_mirror_url": mir.add(name, p, out)}


def newest_rolling(net: Net, comp: str, spec: dict, mir: Mirror, out: str, work: str, prev: dict | None) -> dict:
    url = f"https://github.com/{spec['repo']}/releases/download/{spec['tag']}/{spec['asset']}"
    digest, date = None, today()
    try:
        rel = net.json(f"/repos/{spec['repo']}/releases/tags/{spec['tag']}")
        a = next((x for x in rel.get("assets", []) if x.get("name") == spec["asset"]), None)
        if a:
            digest, date = downloads.asset_digest(a), (a.get("updated_at") or date)[:10]
    except (OSError, ValueError, urllib.error.URLError) as e:
        log(f"note: {comp}: release API: {e}; hashing the download")
    path = fetch_checked(net, url, spec["asset"], work, digest=digest)
    sha = sha256_of(path)
    if prev and prev.get("sha256") == sha:                     # the same bytes: the same build
        return prev
    version = "rolling-" + date.replace("-", "")
    return {"version": version, "tag": spec["tag"], "asset": spec["asset"], "date": date, "upstream_url": url,
            "sha256": sha, "size": os.path.getsize(path), "upstream_digest": bool(digest),
            "mirror_url": mir.add(mirror.mirror_name(comp, version, sha, spec["asset"]), path, out)}


def newest_files(net: Net, comp: str, spec: dict, mir: Mirror, out: str, work: str, prev: dict | None) -> dict:
    q = f"/repos/{spec['repo']}/commits?per_page=1" + (f"&sha={spec['ref']}" if spec.get("ref") else "") + \
        (f"&path={spec['dir']}" if spec.get("dir") else "")
    c = net.json(q)[0]
    commit, date = c["sha"], c["commit"]["committer"]["date"][:10]
    if prev and prev.get("commit") == commit:
        return prev
    version = f"{date.replace('-', '')}-{commit[:8]}"
    return files_entry(net, comp, spec, commit, version, date, mir, out, work)


def files_entry(net, comp, spec, commit, version, date, mir, out, work, pinned: dict | None = None) -> dict:
    base = f"https://raw.githubusercontent.com/{spec['repo']}/{commit}" + (f"/{spec['dir']}" if spec.get("dir") else "")
    files = {}
    notice = None
    if spec.get("notice"):              # AMD's licence allows redistribution with its notice: no notice, no copy
        n_url = f"https://raw.githubusercontent.com/{spec['repo']}/{commit}/{spec['notice']}"
        p = fetch_checked(net, n_url, "license.md", work)
        notice = mir.add(mirror.mirror_name(comp, version, sha256_of(p), os.path.basename(spec["notice"])), p, out)
    for fn in spec["files"]:
        up = f"{base}/{fn}"
        p = fetch_checked(net, up, fn, work, want_sha=(pinned or {}).get(fn))
        sha = sha256_of(p)
        files[fn] = {"sha256": sha, "size": os.path.getsize(p), "upstream_url": up,
                     "mirror_url": mir.add(mirror.mirror_name(comp, version, sha, fn), p, out)}
    e = {"version": version, "commit": commit, "date": date, "files": files}
    if notice:
        e["notice_url"] = notice
    return e


# ---- the pins (part A) ------------------------------------------------------------------------------------------
def pin_items(v: dict) -> list[dict]:
    """Every pinned file in versions.json: {component, version, name (mirror), tag, url, sha256, archive spec}."""
    out = []
    for key in ("optiscaler", "optiscaler_v10", "xess_xmx_linux", "reframework"):
        e = v.get(key) or {}
        if e.get("mirror"):
            out.append({"component": key, "entry": e, "mirror": e["mirror"], "url": e["url"], "sha256": e["sha256"],
                        "asset": e.get("asset") or e["url"].rsplit("/", 1)[1]})
        for x in e.get("extras", []):
            comp = {"OptiPatcher": "optipatcher", "fakenvapi": "fakenvapi"}[x["name"]]
            out.append({"component": comp, "entry": x, "mirror": x["mirror"], "url": x["url"], "sha256": x["sha256"],
                        "asset": x["url"].rsplit("/", 1)[1]})
    for key in mirror.FILES_COMPONENTS:
        e = v.get(key) or {}
        for fn, sha in (e.get("files") or {}).items():
            out.append({"component": key, "entry": e, "mirror": e["mirror"][fn], "url": e["base"].rstrip("/") + "/" + fn,
                        "sha256": sha, "asset": fn})
    return out


def mirror_pins(net: Net, v: dict, mir: Mirror, out: str, work: str) -> list[str]:
    """Copy every tested file to the mirror under the name versions.json expects; returns warnings."""
    warnings = []
    seen = set()
    for it in pin_items(v):
        if it["mirror"] in seen:
            continue
        seen.add(it["mirror"])
        if not mirror.is_mirror_url(it["mirror"]):
            warnings.append(f"{it['component']}: versions.json mirror URL isn't GameCove's release: {it['mirror']}")
            continue
        tag, name = it["mirror"].rsplit("/", 2)[-2:]
        if mir.url_of(name):
            continue
        try:
            notice = None
            if it["component"] == "fsr4_amd" and it["entry"].get("notice"):    # AMD's notice first: none, no copy
                commit = re.search(r"/([0-9a-f]{40})/", it["entry"]["base"]).group(1)
                notice = fetch_checked(net, f"https://raw.githubusercontent.com/{it['entry']['repo']}/{commit}/"
                                       f"{it['entry']['notice']}", "license.md", work)
            p = fetch_checked(net, it["url"], it["asset"], work, want_sha=it["sha256"])
            check_archive(p, it["asset"], SOURCES.get(it["component"], {}), work)
        except (OSError, ValueError, AttributeError, urllib.error.URLError) as e:
            warnings.append(f"tested {it['component']} ({name}) can't be mirrored from upstream: {e}. If you have the "
                            f"file with sha256 {it['sha256']}: gh release upload {tag} <file renamed to {name}>")
            continue
        if notice:
            mir.add(mirror.mirror_name("fsr4_amd", it["entry"]["version"], sha256_of(notice),
                                       os.path.basename(it["entry"]["notice"])), notice, out, tag)
        mir.add(name, p, out, tag)
    if "optiscaler" in v and v["optiscaler"].get("tag"):
        gpl_source(net, "optiscaler", v["optiscaler"].get("repo", "optiscaler/OptiScaler"), v["optiscaler"]["tag"],
                   v["optiscaler"]["version"], mir, out, work)
    return warnings


def pin_entry(comp: str, v: dict, mir: Mirror) -> dict | None:
    """The index entry for a component from its pin, when the pin's file is on the mirror."""
    for it in pin_items(v):
        if it["component"] != comp:
            continue
        e = it["entry"]
        if comp in mirror.FILES_COMPONENTS:
            files = {}
            for fn, sha in e["files"].items():
                name = e["mirror"][fn].rsplit("/", 1)[1]
                if not mir.url_of(name):
                    return None
                files[fn] = {"sha256": sha, "size": mir.where[name][1], "upstream_url": e["base"].rstrip("/") + "/" + fn,
                             "mirror_url": mir.url_of(name)}
            return {"version": e["version"], "date": "", "files": files, "pinned": True}
        name = it["mirror"].rsplit("/", 1)[1]
        if not mir.url_of(name):
            return None
        out = {"version": e["version"], "tag": e.get("tag") or e["version"], "asset": it["asset"], "date": "",
               "upstream_url": it["url"], "sha256": it["sha256"], "size": mir.where[name][1],
               "mirror_url": mir.url_of(name), "pinned": True}
        if comp == "reframework" and e.get("dll_sha256"):
            out["inner"] = {"dinput8.dll": e["dll_sha256"]}
        if comp == "fakenvapi" and e.get("file_sha256"):
            out["inner"] = dict(e["file_sha256"])
        return out
    return None


# ---- all of it --------------------------------------------------------------------------------------------------
def build(net: Net, versions_path: str, out: str, have: str | None = None, previous: str | None = None,
          now: str | None = None) -> dict:
    v = json.load(open(versions_path, encoding="utf-8"))
    prev_comps = {}
    if previous and os.path.exists(previous):
        try:
            prev_comps = mirror.parse(open(previous, "rb").read())["components"]
        except ValueError as e:
            log(f"warning: previous index ignored: {e}")
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="upscalers-")
    mir = Mirror(have)
    report = {"warnings": mirror_pins(net, v, mir, out, work), "components": {}}
    comps = {}
    for comp, spec in SOURCES.items():
        prev = prev_comps.get(comp)
        if prev and not mir.url_of((prev.get("mirror_url") or next(iter(prev.get("files", {}).values()), {}).get("mirror_url", "")).rsplit("/", 1)[-1]):
            prev = None                         # its file isn't on the mirror (a hand-edited release): not carried
        try:
            fn = {"release": newest_release, "rolling": newest_rolling, "git-files": newest_files}[spec["kind"]]
            comps[comp] = fn(net, comp, spec, mir, out, work, prev)
            report["components"][comp] = comps[comp]["version"]
        except Exception as e:                  # one upstream failing never takes the others down
            fallback = prev or pin_entry(comp, v, mir)
            report["warnings"].append(f"{comp}: {type(e).__name__}: {e}; kept {fallback['version'] if fallback else 'nothing'}")
            if fallback:
                comps[comp] = fallback
                report["components"][comp] = fallback["version"] + " (kept)"
    shutil.rmtree(work, ignore_errors=True)
    idx = {"schema": 1, "generated": now or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "repo": mirror.REPO, "note": "Newest upstream build of each upscaler GameCove installs, mirrored on this "
           "repository's 'upscalers' releases under immutable names. Signed with cosign keyless by "
           ".github/workflows/upscalers.yml on main; GameCove checks that signature and every file's sha256.",
           "components": comps}
    raw = json.dumps(idx, indent=1, sort_keys=True).encode() + b"\n"
    mirror.parse(raw)                            # what devices will accept, or this run fails before publishing
    with open(os.path.join(out, mirror.INDEX_NAME), "wb") as f:
        f.write(raw)
    with open(os.path.join(out, "upload-plan.tsv"), "w", encoding="utf-8") as f:
        for tag, name, path in mir.planned:
            f.write(f"{tag}\t{name}\t{os.path.relpath(path, out)}\n")
    report["uploads"] = [f"{t}/{n}" for t, n, _ in mir.planned]
    return report


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--versions", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--have")
    p.add_argument("--previous")
    a = p.parse_args(argv)
    rep = build(Net(os.environ.get("GITHUB_TOKEN", "")), a.versions, a.out, a.have, a.previous)
    lines = ["## Upscalers index", "", "| Component | Version |", "| --- | --- |"]
    lines += [f"| {k} | {v} |" for k, v in rep["components"].items()]
    lines += ["", f"New files on the mirror: {len(rep['uploads'])}"] + [f"- {u}" for u in rep["uploads"]]
    if rep["warnings"]:
        lines += ["", "### Warnings"] + [f"- {w}" for w in rep["warnings"]]
    text = "\n".join(lines) + "\n"
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(text)
    for w in rep["warnings"]:
        print(f"::warning::{w}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
