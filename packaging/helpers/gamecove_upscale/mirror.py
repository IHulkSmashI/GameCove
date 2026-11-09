"""GameCove's own copy of every upscaler file, and the signed list of the newest ones (owner decision, 2026-11-09).

Two halves, one source of truth:

  (A) a copy of every tested file on GameCove's rolling "upscalers" release, under a name that never changes
      (<component>-<version>-<sha256[:8]>-<upstream name>), so a file moved or replaced upstream never breaks an
      install. Older files are never deleted, so every pinned hash keeps resolving.
  (B) upscalers.json on the same release: per component the newest upstream version, its upstream URL, the mirror
      URL, sha256, size and date. .github/workflows/upscalers.yml rebuilds it nightly (tools/upscalers/build.py) and
      signs it with cosign keyless; this module accepts it only when the signature was made by exactly that workflow
      on main (SIGNER_IDENTITY), checked with the cosign get-gamecove.sh pins (~/.local/share/gamecove/tools).

How the helper uses it: before an install or update, refresh() fetches and verifies the index (at most every
FRESH_S); versions(home) is versions.json with every component the verified index lists replaced by its newest
entry. Without a verified index (offline, no cosign, bad signature, a malformed or older file) the bundled
versions.json pins are used, whose files are also on the mirror. Either way every file is checked against its
sha256 before use: nothing unverified is ever installed.
"""
from __future__ import annotations

import copy
import hashlib
import json
import logging
import os
import re
import shutil
import subprocess
import time
import urllib.request

from . import tls

log = logging.getLogger("gamecove.mirror")

REPO = "IHulkSmashI/GameCove"
RELEASE_BASE = f"https://github.com/{REPO}/releases/download/"
INDEX_TAG = "upscalers"
INDEX_NAME = "upscalers.json"
INDEX_URL = RELEASE_BASE + INDEX_TAG + "/" + INDEX_NAME
BUNDLE_URL = INDEX_URL + ".sigstore.json"
# the nightly workflow's GitHub OIDC identity, on the default branch only (as firmware_index.gd and get-gamecove.sh)
SIGNER_IDENTITY = r"(?i)^https://github\.com/IHulkSmashI/GameCove/\.github/workflows/upscalers\.yml@refs/heads/main$"
OIDC_ISSUER = "https://token.actions.githubusercontent.com"
# the cosign get-gamecove.sh pins (packaging/tests/release.sh keeps them equal)
COSIGN_VERSION = "v2.5.3"
COSIGN_SHA256 = "783b5d6c74105401c63946c68d9b2a4e1aab3c8abce043e06b8510b02b623ec9"
COSIGN_URL = f"https://github.com/sigstore/cosign/releases/download/{COSIGN_VERSION}/cosign-linux-amd64"

CACHE = os.path.join(".local", "share", "gamecove", "upscalers")
TOOLS = os.path.join(".local", "share", "gamecove", "tools")
MAX_INDEX = 1 << 20
FRESH_S = 600                     # an install right after another doesn't fetch again
MAX_AGE_S = 30 * 24 * 3600        # a verified copy is used offline for this long, then the pins
# files live on "upscalers" and, once it nears GitHub's 1000-asset limit, on "upscalers-2", "upscalers-3", ...
MIRROR_RE = re.compile(r"^https://github\.com/IHulkSmashI/GameCove/releases/download/upscalers(-[0-9]{1,3})?/"
                       r"[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$")
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ +-]{0,119}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")

# what each component is, for people (the app shows these names)
NAMES = {
    "optiscaler": "OptiScaler", "optiscaler_v10": "OptiScaler v10 (Capcom games)", "optipatcher": "OptiPatcher",
    "fakenvapi": "fakenvapi", "xess_xmx_linux": "XeSS XMX driver", "reframework": "REFramework",
    "fsr4_xmx": "FSR 4.1.2 on XMX", "fsr4_amd": "FSR 4 (AMD)",
}
ARCHIVE_COMPONENTS = ("optiscaler", "optiscaler_v10", "optipatcher", "fakenvapi", "xess_xmx_linux", "reframework")
FILES_COMPONENTS = ("fsr4_xmx", "fsr4_amd")


# ---- names ------------------------------------------------------------------------------------------------------
def safe_part(s: str) -> str:
    """A piece of a release asset name: GitHub keeps [A-Za-z0-9._+-]; anything else becomes '_'."""
    out = re.sub(r"[^A-Za-z0-9._+-]", "_", str(s)).strip("._-")
    return out or "x"


def mirror_name(component: str, version: str, sha256: str, filename: str) -> str:
    """The mirror's file name: immutable because it carries the version and the content's hash."""
    return "-".join((safe_part(component), safe_part(version), sha256[:8].lower(), safe_part(filename)))[:200]


def mirror_url(name: str, tag: str = INDEX_TAG) -> str:
    return RELEASE_BASE + tag + "/" + name


def is_mirror_url(url: str) -> bool:
    return isinstance(url, str) and bool(MIRROR_RE.match(url))


# ---- cosign -----------------------------------------------------------------------------------------------------
def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _fetch(url: str, limit: int, timeout: float) -> bytes:
    """One HTTPS GET, at most `limit` bytes (tests replace this: no network in tests)."""
    req = urllib.request.Request(url, headers={"User-Agent": "GameCove", "Accept": "application/octet-stream"})
    with tls.urlopen(req, timeout) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{url}: larger than {limit} bytes")
    return data


def cosign_path(home: str, download: bool = True) -> str | None:
    """The cosign to check signatures with: $GAMECOVE_COSIGN, else the copy get-gamecove.sh pins under
    ~/.local/share/gamecove/tools (sha256 checked), else the system's, else that pinned copy downloaded now."""
    env = os.environ.get("GAMECOVE_COSIGN", "")
    if env:
        return env if os.path.isfile(env) and os.access(env, os.X_OK) else None
    mine = os.path.join(home, TOOLS, "cosign-" + COSIGN_VERSION)
    if os.path.isfile(mine) and _sha256_file(mine) == COSIGN_SHA256:
        return mine
    sys_cosign = shutil.which("cosign")
    if sys_cosign:
        return sys_cosign
    if not download:
        return None
    try:
        data = _fetch(COSIGN_URL, 400 << 20, 120.0)
    except (OSError, ValueError) as e:
        log.info("cosign download failed: %s", e)
        return None
    if sha256_bytes(data) != COSIGN_SHA256:
        log.warning("the cosign download doesn't match its pinned sha256; not used")
        return None
    os.makedirs(os.path.dirname(mine), exist_ok=True)
    with open(mine + ".part", "wb") as f:
        f.write(data)
    os.chmod(mine + ".part", 0o755)
    os.replace(mine + ".part", mine)
    return mine


def verify(cosign: str, blob: str, bundle: str) -> tuple[bool, str]:
    """cosign verify-blob with exactly the workflow's identity. (ok, cosign's last lines)."""
    cmd = [cosign, "verify-blob", "--bundle", bundle, "--certificate-oidc-issuer", OIDC_ISSUER,
           "--certificate-identity-regexp", SIGNER_IDENTITY, blob]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        return False, str(e)
    tail = " ".join((r.stderr or r.stdout or "").strip().splitlines()[-3:])
    return r.returncode == 0, tail


# ---- the index --------------------------------------------------------------------------------------------------
def _check_item(name: str, e: dict) -> None:
    if not isinstance(e, dict):
        raise ValueError(f"{name}: not an object")
    if not VERSION_RE.match(str(e.get("version", ""))):
        raise ValueError(f"{name}: bad version {e.get('version')!r}")


def _check_file(where: str, f: dict) -> None:
    if not isinstance(f, dict) or not HEX64.match(str(f.get("sha256", ""))):
        raise ValueError(f"{where}: no sha256")
    if not is_mirror_url(f.get("mirror_url", "")):
        raise ValueError(f"{where}: mirror URL isn't GameCove's release: {f.get('mirror_url')!r}")
    if not str(f.get("upstream_url", "")).startswith("https://"):
        raise ValueError(f"{where}: upstream URL isn't https")


def parse(raw: bytes) -> dict:
    """The index from its bytes, every field checked (it names directories and URLs); ValueError when it isn't a
    schema-1 index. Components this helper doesn't know are dropped."""
    if len(raw) > MAX_INDEX:
        raise ValueError("index too large")
    try:
        d = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise ValueError(f"index isn't JSON: {e}") from e
    if not isinstance(d, dict) or d.get("schema") != 1 or not isinstance(d.get("components"), dict):
        raise ValueError("not a schema-1 upscalers index")
    if not re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", str(d.get("generated", ""))):
        raise ValueError("index has no generated time")
    comps = {}
    for name, e in d["components"].items():
        if name in ARCHIVE_COMPONENTS:
            _check_item(name, e)
            _check_file(name, e)
            if not FILE_RE.match(str(e.get("asset", ""))):
                raise ValueError(f"{name}: bad asset name")
            inner = e.get("inner") or {}
            if not isinstance(inner, dict) or not all(FILE_RE.match(k) and HEX64.match(str(v)) for k, v in inner.items()):
                raise ValueError(f"{name}: bad inner hashes")
            comps[name] = e
        elif name in FILES_COMPONENTS:
            _check_item(name, e)
            files = e.get("files")
            if not isinstance(files, dict) or not files:
                raise ValueError(f"{name}: no files")
            for fn, f in files.items():
                if not FILE_RE.match(fn) or "/" in fn:
                    raise ValueError(f"{name}: bad file name {fn!r}")
                _check_file(f"{name}/{fn}", f)
            comps[name] = e
    return {**d, "components": comps}


def _paths(home: str) -> dict:
    d = os.path.join(home, CACHE)
    return {"dir": d, "index": os.path.join(d, INDEX_NAME), "bundle": os.path.join(d, INDEX_NAME + ".sigstore.json"),
            "stamp": os.path.join(d, "verified.json")}


def _stamp(home: str) -> dict:
    try:
        with open(_paths(home)["stamp"], "r", encoding="utf-8") as f:
            s = json.load(f)
        return s if isinstance(s, dict) else {}
    except (OSError, ValueError):
        return {}


def load(home: str, now: float | None = None) -> dict | None:
    """The cached index when it was verified (its sha256 is the one recorded right after cosign accepted it) and
    that was less than MAX_AGE_S ago; else None."""
    p, st = _paths(home), _stamp(home)
    now = time.time() if now is None else now
    try:
        with open(p["index"], "rb") as f:
            raw = f.read(MAX_INDEX + 1)
    except OSError:
        return None
    if st.get("sha256") != sha256_bytes(raw) or now - float(st.get("verified_at", 0)) > MAX_AGE_S:
        return None
    try:
        return parse(raw)
    except ValueError:
        return None


def refresh(home: str, force: bool = False, timeout: float = 10.0, now: float | None = None) -> dict:
    """Fetch upscalers.json and its signature, verify, keep it. {"state": verified | cached | offline | unverified |
    bad-signature | invalid | older, "generated", "error"}. Never raises."""
    now = time.time() if now is None else now
    p, st = _paths(home), _stamp(home)
    have = load(home, now)
    if have and not force and now - float(st.get("verified_at", 0)) < FRESH_S:
        return {"state": "cached", "generated": have.get("generated"), "error": None}
    try:
        raw = _fetch(INDEX_URL, MAX_INDEX, timeout)
        bundle = _fetch(BUNDLE_URL, MAX_INDEX, timeout)
    except Exception as e:        # network of any kind: the pins (or the verified copy) are used
        return {"state": "offline", "generated": have.get("generated") if have else None, "error": f"{type(e).__name__}: {e}"}
    try:
        idx = parse(raw)
    except ValueError as e:
        return {"state": "invalid", "generated": have.get("generated") if have else None, "error": str(e)}
    cos = cosign_path(home)
    if not cos:
        return {"state": "unverified", "generated": have.get("generated") if have else None,
                "error": "cosign isn't available to check the list's signature"}
    os.makedirs(p["dir"], exist_ok=True)
    tmp_i, tmp_b = p["index"] + ".new", p["bundle"] + ".new"
    with open(tmp_i, "wb") as f:
        f.write(raw)
    with open(tmp_b, "wb") as f:
        f.write(bundle)
    ok, msg = verify(cos, tmp_i, tmp_b)
    if not ok:
        for t in (tmp_i, tmp_b):
            os.unlink(t)
        log.warning("upscalers.json signature refused: %s", msg)
        return {"state": "bad-signature", "generated": have.get("generated") if have else None, "error": msg or "cosign refused it"}
    if have and str(idx["generated"]) < str(have.get("generated", "")):
        # a genuinely signed but older list (replayed): keep the newer one
        for t in (tmp_i, tmp_b):
            os.unlink(t)
        return {"state": "older", "generated": have.get("generated"), "error": "an older list than the one already checked"}
    os.replace(tmp_i, p["index"])
    os.replace(tmp_b, p["bundle"])
    with open(p["stamp"] + ".new", "w", encoding="utf-8") as f:
        json.dump({"sha256": sha256_bytes(raw), "verified_at": now, "generated": idx["generated"]}, f)
    os.replace(p["stamp"] + ".new", p["stamp"])
    _memo.clear()
    return {"state": "verified", "generated": idx["generated"], "error": None}


# ---- what to install --------------------------------------------------------------------------------------------
def _archive_fields(e: dict) -> dict:
    return {"version": e["version"], "url": e["upstream_url"], "mirror": e["mirror_url"], "sha256": e["sha256"],
            "source": "index"}


def effective(pins: dict, idx: dict | None) -> dict:
    """versions.json with the verified index's newest entries in place of the pins. Each replaced entry keeps the
    pin's layout and install details and gets "source": "index"; an index entry that can't stand in for the pin (a
    missing inner file the install needs, other file names) is ignored and the pin stays."""
    v = copy.deepcopy(pins)
    comps = (idx or {}).get("components") or {}
    op, fk = comps.get("optipatcher"), comps.get("fakenvapi")
    for key in ("optiscaler", "optiscaler_v10"):
        if key not in v:
            continue
        e = comps.get(key)
        if e:
            v[key].update(_archive_fields(e))
            v[key]["tag"] = e.get("tag", v[key].get("tag"))
            v[key]["asset"] = e["asset"]
        for x in v[key].get("extras", []):
            if x.get("name") == "OptiPatcher" and op:
                x.update(_archive_fields(op))
            elif x.get("name") == "fakenvapi" and fk:
                inner = fk.get("inner") or {}
                if all(src in inner for src in (x.get("files") or {})):
                    x.update(_archive_fields(fk))
                    x["file_sha256"] = {src: inner[src] for src in (x.get("files") or {})}
    for key in ("xess_xmx_linux", "reframework"):
        e = comps.get(key)
        if not e or key not in v:
            continue
        if key == "reframework" and "dinput8.dll" not in (e.get("inner") or {}):
            continue
        v[key].update(_archive_fields(e))
        v[key].update({"tag": e.get("tag") or e["version"], "asset": e["asset"]})
        if key == "reframework":
            v[key]["dll_sha256"] = e["inner"]["dinput8.dll"]
    for key in FILES_COMPONENTS:
        e = comps.get(key)
        if not e or key not in v or set(e["files"]) != set(v[key].get("files") or {}):
            continue
        v[key].update({"version": e["version"], "source": "index",
                       "files": {n: f["sha256"] for n, f in e["files"].items()},
                       "mirror": {n: f["mirror_url"] for n, f in e["files"].items()},
                       "upstream": {n: f["upstream_url"] for n, f in e["files"].items()}})
    return v


_memo: dict = {}


def versions(home: str | None, pins: dict) -> dict:
    """effective() with the cached verified index (no network; refresh() fetches). Without home: the pins."""
    if not home:
        return copy.deepcopy(pins)
    p = _paths(home)["index"]
    try:
        key = (home, os.stat(p).st_mtime_ns)
    except OSError:
        key = (home, None)
    if key not in _memo:
        _memo.clear()
        _memo[key] = effective(pins, load(home))
    return copy.deepcopy(_memo[key])


def status(home: str) -> dict:
    """What the cached list is: {"verified": bool, "generated", "verified_at"} (no network)."""
    idx = load(home)
    st = _stamp(home)
    return {"verified": idx is not None, "generated": idx.get("generated") if idx else None,
            "verified_at": st.get("verified_at") if idx else None}
