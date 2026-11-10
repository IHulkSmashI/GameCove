"""Fetch the upscaler files GameCove installs on request: from GameCove's own mirror (the rolling "upscalers"
release, mirror.py) first, then from the project's own release, at the moment the user taps Install. Which version:
the newest from the signed index (mirror.versions), else the pins in data/versions.json. Every entry carries the sha256 of the exact asset that was tested, and fetch() refuses a
pinned entry without one (never falling back to the digest from the same API answer that supplied the URL). Only
"latest (untested)", which the user has to allow, may use GitHub's recorded digest instead, and it still needs one.
Extraction refuses absolute paths, '..', links and device nodes, so an archive cannot write outside its folder."""
from __future__ import annotations

import fnmatch
import json
import logging
import os
import re
import shutil
import subprocess
import tarfile
import urllib.request

from . import tls
import zipfile

log = logging.getLogger("gamecove.downloads")

API = "https://api.github.com/repos/{repo}/releases/{which}"
UNPINNED = ("", "pending-verification", None)


def load_versions(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def is_pinned(entry: dict) -> bool:
    return entry.get("tag") not in UNPINNED


def _get(url: str, timeout: float = 20.0) -> bytes:
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "GameCove"})
    with tls.urlopen(req, timeout) as r:
        return r.read()


def release(repo: str, tag: str | None) -> dict:
    which = f"tags/{tag}" if tag not in UNPINNED else "latest"
    return json.loads(_get(API.format(repo=repo, which=which)))


def sha256_of(path: str) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def asset_digest(asset: dict) -> str | None:
    """The sha256 GitHub records for a release asset ("digest": "sha256:<hex>"), when the API reports one."""
    d = asset.get("digest") or ""
    return d[7:].lower() if d.startswith("sha256:") and len(d) == 71 else None


def pick_asset(rel: dict, pattern: str) -> dict | None:
    """First asset matching the glob, ignoring case (OptiScaler ships "Optiscaler_<v>.7z", lower-case s)."""
    for a in rel.get("assets", []):
        if fnmatch.fnmatch(a.get("name", "").lower(), pattern.lower()):
            return a
    return None


def download(url: str, dest: str, timeout: float = 60.0) -> str:
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    req = urllib.request.Request(url, headers={"User-Agent": "GameCove", "Accept": "application/octet-stream"})
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644)
    with tls.urlopen(req, timeout) as r, os.fdopen(fd, "wb") as f:
        shutil.copyfileobj(r, f, 1 << 20)
    os.replace(tmp, dest)
    return dest


def sources(item: dict) -> list[str]:
    """Where an item may come from, in order: GameCove's mirror (only a URL on GameCove's own release), then the
    upstream URL. Both answer the same bytes; the sha256 decides either way."""
    from . import mirror
    out = []
    m = item.get("mirror")
    if isinstance(m, str) and mirror.is_mirror_url(m):
        out.append(m)
    u = item.get("url")
    if isinstance(u, str) and u.startswith("https://"):
        out.append(u)
    return out


def get_verified(urls: list[str], sha256: str, dest: str, timeout: float = 60.0) -> str:
    """Download the first source whose bytes have `sha256` to dest (atomically: a good file already at dest stays
    until the new one is checked). Raises ValueError when no source has those bytes, PermissionError without a pin."""
    want = (sha256 or "").lower()
    if len(want) != 64 or any(c not in "0123456789abcdef" for c in want):
        raise PermissionError(f"{os.path.basename(dest)} has no sha256 pinned; not installed")
    if not urls:
        raise ValueError(f"{os.path.basename(dest)}: nowhere to download it from")
    errors = []
    tmp = dest + ".new"
    for url in urls:
        try:
            download(url, tmp, timeout)
        except Exception as e:          # this source is down or gone: the next one
            errors.append(f"{url}: {type(e).__name__}: {e}")
            continue
        if sha256_of(tmp) == want:
            os.replace(tmp, dest)
            return dest
        os.remove(tmp)
        errors.append(f"{url}: does not match its pinned sha256")
        log.warning("%s does not match its pinned sha256", url)
    if any("does not match" in e for e in errors):
        raise ValueError(f"{os.path.basename(dest)} does not match its pinned sha256; not installed ({'; '.join(errors)})")
    raise OSError(f"{os.path.basename(dest)}: download failed ({'; '.join(errors)})")


def _safe(name: str) -> bool:
    n = name.replace("\\", "/")
    return not (n.startswith("/") or n == ".." or n.startswith("../") or "/../" in n or n.endswith("/.."))


def _zip_is_link(info: zipfile.ZipInfo) -> bool:
    """A zip member stored with a Unix symlink mode (S_IFLNK), which zipfile would write as a plain file holding the
    target path today, but other unzippers (and a later re-pack) would turn into a real link."""
    return ((info.external_attr >> 16) & 0o170000) == 0o120000


def _7z_links(listing: str) -> list[str]:
    """Members of a `7z l -slt` listing that are symbolic or hard links: a Unix mode starting with 'l' in Attributes
    (7-Zip prints e.g. "A_ -lrwxrwxrwx"), a Windows reparse point, or a "Link = " target."""
    out, path = [], ""
    for line in listing.splitlines():
        if line.startswith("Path = "):
            path = line[7:]
        elif line.startswith("Attributes = ") and (re.search(r"\bl[rwxsStT-]{9}\b", line) or "REPARSE" in line.upper()):
            out.append(path)
        elif line.startswith(("Link = ", "Symbolic Link = ", "Hard Link = ")) and line.split("=", 1)[1].strip():
            out.append(path)
    return out


def extract(archive: str, dest: str) -> str:
    if os.path.islink(dest):
        raise ValueError(f"refusing to extract into a symlink: {dest}")
    os.makedirs(dest, exist_ok=True)
    low = archive.lower()
    if low.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            for i in z.infolist():
                if not _safe(i.filename) or _zip_is_link(i):
                    raise ValueError(f"unsafe path in archive: {i.filename}")
            for i in z.infolist():
                z.extract(i, dest)
                mode = (i.external_attr >> 16) & 0o777
                if mode and not i.is_dir():
                    os.chmod(os.path.join(dest, i.filename), mode)
    elif low.endswith((".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".tar")):
        with tarfile.open(archive) as t:
            for m in t.getmembers():
                # no links (symbolic or hard) and no device nodes: none of the pinned upstream archives has any
                if not _safe(m.name) or m.issym() or m.islnk() or m.isdev():
                    raise ValueError(f"unsafe member in archive: {m.name}")
            if hasattr(tarfile, "data_filter"):
                t.extractall(dest, filter="data")
            else:
                t.extractall(dest)
    elif low.endswith(".7z"):
        tool = shutil.which("7z") or shutil.which("7za") or shutil.which("7zz")
        bsdtar = shutil.which("bsdtar")
        if tool:
            listing = subprocess.run([tool, "l", "-slt", archive], capture_output=True, text=True, check=True).stdout
            paths = [line[7:] for line in listing.splitlines() if line.startswith("Path = ")][1:]   # first is the archive
            links = _7z_links(listing)
        elif bsdtar:      # libarchive reads 7z too
            paths = subprocess.run([bsdtar, "-tf", archive], capture_output=True, text=True, check=True).stdout.splitlines()
            verbose = subprocess.run([bsdtar, "-tvf", archive], capture_output=True, text=True, check=True).stdout
            links = [ln for ln in verbose.splitlines() if ln[:1] in ("l", "h") or " link to " in ln]
        else:
            raise FileNotFoundError("7z or bsdtar is needed to unpack OptiScaler (Bazzite and SteamOS ship bsdtar)")
        for pth in paths:
            if not _safe(pth):
                raise ValueError(f"unsafe path in archive: {pth}")
        if links:
            raise ValueError(f"links are not allowed in archives: {links[0]}")
        if tool:
            subprocess.run([tool, "x", "-y", f"-o{dest}", archive], capture_output=True, check=True)
        else:
            subprocess.run([bsdtar, "-xf", archive, "-C", dest], capture_output=True, check=True)
    else:
        raise ValueError(f"unknown archive type: {archive}")
    return dest


def expected_sha256(entry: dict, tag: str, asset: dict) -> str:
    """The sha256 the downloaded asset must have. The pinned tag needs the pin in versions.json (the digest from the
    same API answer that gave the URL proves nothing if the release was replaced); an untested tag the user allowed
    needs at least GitHub's recorded digest. Never "no check"."""
    pin = (entry.get("sha256") or "").lower()
    if is_pinned(entry) and tag == entry.get("tag"):
        if len(pin) != 64 or any(c not in "0123456789abcdef" for c in pin):
            raise PermissionError(f"{entry.get('repo')} {tag} has no sha256 pinned in versions.json; not installed")
        return pin
    digest = asset_digest(asset)
    if not digest:
        raise PermissionError(f"{asset.get('name')} ({tag}) has no pinned or published sha256; not installed")
    return digest


def fetch(entry: dict, workdir: str, allow_unpinned: bool = False, rel: dict | None = None) -> dict:
    """Download and unpack one versions.json entry. Returns {tag, archive, dir}. `rel`: the release, when the caller
    has already looked it up. An entry with a mirror and an asset name (every pinned one, every index one) is
    fetched straight from the mirror (then upstream) with its sha256, no API call; "latest (untested)" asks the
    API."""
    if entry.get("mirror") and entry.get("asset") and is_pinned(entry) and not (rel and rel.get("tag_name") not in (None, entry.get("tag"))):
        tag = entry["tag"]
        if not _safe(entry["asset"]) or "/" in entry["asset"].replace("\\", "/"):
            raise ValueError(f"unsafe asset name: {entry['asset']}")
        urls = sources({**entry, "url": entry.get("url") or
                        f"https://github.com/{entry['repo']}/releases/download/{tag}/{entry['asset']}"})
        archive = get_verified(urls, expected_sha256(entry, tag, {}), os.path.join(workdir, "downloads", entry["asset"]))
        out = extract(archive, os.path.join(workdir, f"{os.path.basename(entry['repo'])}-{tag}"))
        return {"tag": tag, "archive": archive, "dir": out, "repo": entry["repo"]}
    if not is_pinned(entry) and not allow_unpinned:
        raise PermissionError(f"{entry['repo']} has no tested version pinned yet; allow 'latest (untested)' to continue")
    repo = (entry.get("fork") or entry["repo"]) if entry.get("use_fork") else entry["repo"]
    rel = rel or release(repo, entry.get("tag"))
    asset = pick_asset(rel, entry.get("asset_glob", "*"))
    if asset is None:
        raise FileNotFoundError(f"no asset matching {entry.get('asset_glob')} in {repo} {rel.get('tag_name')}")
    tag = str(rel.get("tag_name", "unknown"))
    # review problem 9: a pinned entry takes exactly its tag unless the user allowed "latest (untested)" (a
    # release answer naming another tag used to fall back to GitHub's own digest), and the API's asset name and
    # tag only become file names when they are plain names
    if is_pinned(entry) and tag != entry.get("tag") and not allow_unpinned:
        raise PermissionError(f"{repo} answered {tag}, not the tested {entry.get('tag')}; not installed")
    for what, name in (("asset name", str(asset.get("name", ""))), ("tag", tag)):
        if not name or name in (".", "..") or not _safe(name) or "/" in name.replace("\\", "/"):
            raise ValueError(f"unsafe {what} from the release: {name!r}")
    want = expected_sha256(entry, tag, asset)
    archive = download(asset["browser_download_url"], os.path.join(workdir, "downloads", asset["name"]))
    if sha256_of(archive) != want:
        os.remove(archive)
        raise ValueError(f"{asset['name']} does not match its pinned sha256; not installed")
    out = extract(archive, os.path.join(workdir, f"{os.path.basename(repo)}-{tag}"))
    return {"tag": tag, "archive": archive, "dir": out, "repo": repo}
