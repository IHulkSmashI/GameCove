#!/usr/bin/env python3
"""Live check of the upscaler downloads against the real GameCove-data releases (NOT a test: it uses the network, so
it's never part of the gates). Runs the helper's own code end to end in a temp home:

  1. mirror.refresh(): upscalers.json and its .sigstore.json from the data repo, cosign verify-blob with the pinned
     identity and issuer (mirror.SIGNER_IDENTITY, OIDC_ISSUER), with the cosign the helper pins (downloaded and
     sha256 checked by mirror.cosign_path) -> state "verified".
  2. For the signed list's newest entries AND for every tested pin in versions.json (the fallback without a valid
     list), each file the app installs, through the functions the app calls: OptiScaler stable and v10 with their
     extras (OptiPatcher, fakenvapi) via optiscaler.install(); the XeSS XMX driver via the same steps as
     xess.install() up to (not including) running its install.sh: downloads.fetch(), _find_package(),
     scripts_check(); REFramework via reframework.install() into a temp game folder; the FSR 4 files via
     optiscaler.fsr4_xmx_download() and fsr4_amd_download(). Every file is sha256 checked by the helper itself.
  3. Every download must have come from the data repo's mirror (the first source tried), never the upstream
     fallback, so a broken mirror can't hide behind upstream.

usage: python3 -I tools/data_check/upscalers_live.py <work dir>     (exit 1 on any failure)
"""
from __future__ import annotations

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "packaging", "helpers"))

from gamecove_upscale import downloads, games, mirror, optiscaler, reframework, xess  # noqa: E402

failures: list[str] = []
used: list[str] = []
_download = downloads.download


def _recording(url: str, dest: str, timeout: float = 60.0) -> str:
    out = _download(url, dest, timeout)
    used.append(url)          # only reached when this source answered; get_verified then checks the sha256
    return out


downloads.download = _recording


def ok(cond: bool, what: str) -> None:
    print(("PASS " if cond else "FAIL ") + what, flush=True)
    if not cond:
        failures.append(what)


def from_mirror(what: str, start: int) -> None:
    urls = used[start:]
    bad = [u for u in urls if not u.startswith(mirror.RELEASE_BASE)]
    ok(bool(urls) and not bad, f"{what}: {len(urls) - len(bad)} of {len(urls)} download(s) from the mirror {mirror.RELEASE_BASE}"
       + (f"; from upstream instead (the mirror didn't answer): {bad}" if bad else ""))


def check_set(label: str, v: dict, home: str, work: str) -> None:
    for comp in ("optiscaler", "optiscaler_v10"):
        e = v.get(comp)
        if not e:
            ok(False, f"{label}: {comp} missing")
            continue
        n = len(used)
        r = optiscaler.install(home, e)
        ok(bool(r.get("ok")) and not r.get("already"), f"{label}: {comp} {e.get('version')} installed with extras "
           f"{[x.get('name') for x in e.get('extras', [])]} ({r.get('error') or r.get('dir')})")
        from_mirror(f"{label}: {comp}", n)
    e = v["xess_xmx_linux"]
    n = len(used)
    try:
        got = downloads.fetch(e, os.path.join(work, label, "xess"))
        pkg = xess._find_package(got["dir"])
        bad = xess.scripts_check(pkg) if pkg else "no install.sh"
        ok(pkg is not None and bad is None, f"{label}: XeSS XMX driver {got['tag']} ({e.get('asset')}) downloaded, "
           f"sha256 checked, unpacked, install scripts match the reviewed ones ({bad or 'ok'}; install.sh not run)")
    except Exception as ex:  # noqa: BLE001 - reported as a failure
        ok(False, f"{label}: XeSS XMX driver: {type(ex).__name__}: {ex}")
    from_mirror(f"{label}: XeSS XMX driver", n)
    e = v["reframework"]
    n = len(used)
    game = os.path.join(work, label, "game")
    os.makedirs(game, exist_ok=True)
    r = reframework.install(home, game, e)
    ok(bool(r.get("ok")) and os.path.isfile(os.path.join(game, reframework.DLL)),
       f"{label}: REFramework {e.get('tag')} into a game folder ({r.get('error') or reframework.DLL + ' in place'})")
    from_mirror(f"{label}: REFramework", n)
    for comp, fn in (("fsr4_xmx", optiscaler.fsr4_xmx_download), ("fsr4_amd", optiscaler.fsr4_amd_download)):
        e = v[comp]
        n = len(used)
        r = fn(home, e)
        ok(bool(r.get("ok")) and sorted(r.get("downloaded", [])) == sorted(e.get("files", {})),
           f"{label}: {comp} {e.get('version')} files {sorted(e.get('files', {}))} ({r.get('error') or 'sha256 checked'})")
        from_mirror(f"{label}: {comp}", n)


def main(argv: list[str]) -> int:
    work = os.path.abspath(argv[1])
    os.makedirs(work, exist_ok=True)
    r = mirror.refresh(os.path.join(work, "home-index"), force=True, timeout=60.0)
    ok(r["state"] == "verified", f"upscalers.json from {mirror.INDEX_URL}: {r['state']} (generated {r.get('generated')}; "
       f"identity {mirror.SIGNER_IDENTITY}, issuer {mirror.OIDC_ISSUER}) {r.get('error') or ''}".rstrip())
    newest = games.versions(os.path.join(work, "home-index"))
    pins = games.pins()
    for label, v in (("newest", newest), ("pins", pins)):
        home = os.path.join(work, "home-" + label)
        os.makedirs(home, exist_ok=True)
        check_set(label, v, home, work)
    print(f"{len(failures)} failed", flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
