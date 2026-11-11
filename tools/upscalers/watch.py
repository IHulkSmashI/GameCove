#!/usr/bin/env python3
"""Watch every upstream GameCove's upscaling depends on but doesn't mirror, and say when one moved.

build.py mirrors and promotes what GameCove installs (OptiScaler, its v10 nightly, OptiPatcher, fakenvapi, the XeSS
XMX driver, the REFramework fork, AMD's FSR upscaler, the FSR 4.1.2 XMX build). This watches the rest: things a
person has to look at before GameCove changes, because they change what the decision table says or need a test on
hardware. Nothing here is downloaded to devices.

  what                                   why it matters
  intel/xess tags                        new XeSS / XeSS-FG / XeLL libraries (OptiScaler and the XMX driver bring them)
  FidelityFX-SDK tags                    a new AMD FSR upscaler: does the FSR 4.1.2 XMX build pair with it? (ask its author)
  Nukem9/dlssg-to-fsr3 tags              bundled inside OptiScaler's archive
  OptiPatcher tags                       its supported-games list
  proton-cachyos / proton-ge / Proton    FSR 4 upgrade variables, DXVK's Intel vendor hiding (launch_env.gd, launchenv.py)
  IHulkSmashI/xess-xmx-linux (main)      the owner's fork of the XMX driver
  IHulkSmashI/ClawDeck fsr4-xmx-files    where new FSR 4 on XMX builds are dropped (they are announced on Discord,
                                         which no job can read: a person commits them to that branch)
  onehoon/REFramework releases           the Capcom fork: what changed is read before a new build is adopted
  builds.lsfg-vk.dev                     lsfg-vk releases (GameCove pins one by sha256)
  decky-framegen / decky-lsfg-vk tags    what the Decky plugins moved to (their pins and markers)

  watch.py --previous prev/watch.json --out dist/watch.json     prints what changed as Markdown (the issue body)
The first run (no previous file) reports nothing. A source that can't be read keeps its last value and is listed
under "couldn't read", so a moved or renamed upstream ("changed shape") is noticed too.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"
LSFG_BUILDS = "https://builds.lsfg-vk.dev/"
# id -> (kind, where, why a person should look)
WATCHED = {
    "intel_xess": ("tags", "intel/xess", "new XeSS / XeSS-FG / XeLL libraries"),
    "amd_fsr_sdk": ("tags", "GPUOpen-LibrariesAndSDKs/FidelityFX-SDK",
                    "a new AMD FSR upscaler: check that the FSR 4.1.2 XMX build pairs with it before adopting"),
    "dlssg_to_fsr3": ("tags", "Nukem9/dlssg-to-fsr3", "bundled inside OptiScaler's archive"),
    "optipatcher": ("tags", "optiscaler/OptiPatcher", "its supported-games list grew"),
    "proton_cachyos": ("tags", "CachyOS/proton-cachyos", "FSR 4 upgrade variables and DXVK may have changed"),
    "proton_ge": ("release", "GloriousEggroll/proton-ge-custom", "FSR 4 upgrade variables and DXVK may have changed"),
    "proton_valve": ("release", "ValveSoftware/Proton", "check whether DXVK still hides the Intel GPU from XeSS games"),
    "xess_xmx_fork": ("branch", "IHulkSmashI/xess-xmx-linux:main", "the owner's fork of the XMX driver moved"),
    "fsr4_xmx_drop": ("branch", "IHulkSmashI/ClawDeck:fsr4-xmx-files", "a new FSR 4 on XMX build was dropped: test it on a Claw"),
    "reframework_fork": ("release", "onehoon/REFramework", "read what changed before the Capcom setup adopts it"),
    "decky_framegen": ("release", "xXJSONDeruloXx/Decky-Framegen", "its pins and markers (conflict detection)"),
    "decky_lsfg_vk": ("release", "xXJSONDeruloXx/decky-lsfg-vk", "its lsfg-vk config handling"),
    "lsfg_vk": ("lsfg", LSFG_BUILDS, "a new lsfg-vk release: update the pin in versions.json after a test"),
}


class Net:
    def __init__(self, token: str = ""):
        self.token = token

    def get(self, url: str) -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": "gamecove-upscalers-watch", "Accept": "application/vnd.github+json"})
        if self.token and url.startswith(API):
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read(4 << 20)


def read_one(net, kind: str, where: str) -> str:
    """The newest thing at a source, as one short string."""
    if kind == "tags":
        tags = json.loads(net.get(f"{API}/repos/{where}/tags?per_page=30"))
        names = [str(t["name"]) for t in tags if isinstance(t, dict) and t.get("name")]
        if not names:
            raise ValueError("no tags")
        return names[0]
    if kind == "release":
        rel = json.loads(net.get(f"{API}/repos/{where}/releases/latest"))
        return str(rel["tag_name"])
    if kind == "branch":
        repo, _, branch = where.partition(":")
        return str(json.loads(net.get(f"{API}/repos/{repo}/commits/{branch}"))["sha"])[:12]
    if kind == "lsfg":
        html = net.get(where).decode("utf-8", "replace")
        m = re.search(r'href="(lsfg-vk-[0-9][^"]*\.tar\.xz)">&gt;&gt; Latest release \(', html)
        if not m:
            raise ValueError("no 'Latest release' link on the builds page")
        return m.group(1)
    raise ValueError(f"unknown kind {kind}")


def watch(net, previous: dict | None) -> dict:
    prev = (previous or {}).get("seen") or {}
    seen, changed, failed = {}, [], []
    for key, (kind, where, why) in WATCHED.items():
        try:
            now = read_one(net, kind, where)
        except (OSError, ValueError, KeyError, TypeError, urllib.error.URLError) as e:
            failed.append({"id": key, "where": where, "error": f"{type(e).__name__}: {e}"[:200]})
            if key in prev:
                seen[key] = prev[key]
            continue
        seen[key] = now
        if key in prev and prev[key] != now:
            changed.append({"id": key, "where": where, "was": prev[key], "now": now, "why": why})
    return {"seen": seen, "changed": changed, "failed": failed}


def markdown(result: dict, build_report: dict | None = None, smoke: dict | None = None) -> str:
    """The issue text: empty when there is nothing a person needs to look at."""
    lines = []
    if result["changed"]:
        lines += ["### Upstreams that moved", "", "| What | Was | Now | Why look |", "| --- | --- | --- | --- |"]
        lines += [f"| {c['where']} | `{c['was']}` | `{c['now']}` | {c['why']} |" for c in result["changed"]]
    if result["failed"]:
        lines += ["", "### Couldn't read (moved, renamed or down)", ""] + [f"- {f['where']}: {f['error']}" for f in result["failed"]]
    if build_report and build_report.get("warnings"):
        lines += ["", "### The mirror build kept older entries", ""] + [f"- {w}" for w in build_report["warnings"]]
    if smoke and smoke.get("problems"):
        lines += ["", "### Smoke check failed: last night's index was kept", ""] + [f"- {p}" for p in smoke["problems"]]
    return "\n".join(lines).strip() + ("\n" if lines else "")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--previous")
    p.add_argument("--out", required=True)
    p.add_argument("--build-report")
    p.add_argument("--smoke-report")
    p.add_argument("--issue", help="write the issue body here (empty file: nothing to report)")
    a = p.parse_args(argv)

    def load(path):
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError, TypeError):
            return None

    result = watch(Net(os.environ.get("GITHUB_TOKEN", "")), load(a.previous))
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump({"seen": result["seen"]}, f, indent=1, sort_keys=True)
        f.write("\n")
    text = markdown(result, load(a.build_report), load(a.smoke_report))
    if a.issue:
        with open(a.issue, "w", encoding="utf-8") as f:
            f.write(text)
    print(text or "nothing moved")
    return 0


if __name__ == "__main__":
    sys.exit(main())
