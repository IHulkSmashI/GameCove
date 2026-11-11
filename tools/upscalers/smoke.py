#!/usr/bin/env python3
"""Smoke check of the nightly upscalers build, before anything is signed.

A new upstream build is only worth shipping if GameCove can still use it. For what build.py put in dist/ this checks,
with Python's standard library, 7-Zip for OptiScaler's archive and GameCove's own helper modules:

  files     every Windows library the index names as a single file (AMD's FSR upscaler, the FSR 4.1.2 XMX build) is a
            64-bit PE DLL with the exports GameCove relies on (the FidelityFX entry points); the XMX build still
            imports Cabinet.dll (so the LZMS cabinet.dll GameCove ships is still what it needs)
  archives  OptiScaler's archive still has OptiScaler.dll (64-bit PE) and OptiScaler.ini at its root
  ini       every setting GameCove would write for every preset and frame generation choice (launchenv.opti_ini)
            exists in that OptiScaler.ini: a renamed key would silently do nothing in games
  games     the generated games.json loads and every setting in it is a valid OptiScaler.ini line

  smoke.py <dist> [--games FILE]    exit 0 when all hold; else 1 with one line per problem (the workflow then
                                    keeps last night's index and opens an issue)
Only files new in this run are in dist/; a component carried over unchanged was checked the night it came in.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "packaging", "helpers"))

from gamecove_upscale import gamedb, launchenv, mirror  # noqa: E402
from gamecove_upscale.selfcheck import MACHINE_AMD64, check_ini, pe_info  # noqa: E402

FFX_EXPORTS = {"ffxCreateContext", "ffxDestroyContext", "ffxConfigure", "ffxQuery", "ffxDispatch"}
PE_RULES = {            # component -> file -> {"exports": needed, "imports": DLL names needed}
    "fsr4_amd": {"amd_fidelityfx_upscaler_dx12.dll": {"exports": FFX_EXPORTS}},
    "fsr4_xmx": {"amd_fidelityfx_upscaler_dx12.dll": {"exports": FFX_EXPORTS, "imports": {"cabinet.dll"}},
                 "fsr-original.dll": {"exports": FFX_EXPORTS}},
}


def check_pe(path: str, rule: dict, label: str) -> list[str]:
    try:
        info = pe_info(path)
    except (ValueError, struct.error, OSError) as e:
        return [f"{label}: {e}"]
    out = []
    if info["machine"] != MACHINE_AMD64 or not info["dll"]:
        out.append(f"{label}: not a 64-bit Windows DLL")
    missing = set(rule.get("exports") or ()) - info["exports"]
    if missing:
        out.append(f"{label}: exports gone: {', '.join(sorted(missing))}")
    need = set(rule.get("imports") or ()) - info["imports"]
    if need:
        out.append(f"{label}: no longer imports {', '.join(sorted(need))} (the build changed shape)")
    return out


def _7z(archive: str, dest: str, names: list[str]) -> None:
    subprocess.run(["7z", "x", "-y", f"-o{dest}", archive, *names], check=True, capture_output=True, timeout=300)


def check_games(path: str) -> list[str]:
    doc = gamedb.load(path)
    if not doc.get("games"):
        return ["games.json: no games"]
    out = []
    for g in doc["games"]:
        for k, v in {**(g.get("ini") or {}), **{k: v for w in (g.get("when") or {}).values() for k, v in w.items()}}.items():
            if not launchenv.INI_KEY_RE.match(str(k)) or not launchenv.INI_VAL_RE.match(str(v)):
                out.append(f"games.json: {g.get('id')}: bad setting {k}={v}")
    return out[:20]


def run(dist: str, games: str | None = None) -> list[str]:
    problems: list[str] = []
    with open(os.path.join(dist, mirror.INDEX_NAME), "rb") as f:
        idx = mirror.parse(f.read())
    planned = {}
    plan = os.path.join(dist, "upload-plan.tsv")
    if os.path.isfile(plan):
        for line in open(plan, encoding="utf-8"):
            tag, name, path = line.rstrip("\n").split("\t")
            planned[name] = os.path.join(dist, path)
    for comp, rules in PE_RULES.items():
        for fn, f in ((idx["components"].get(comp) or {}).get("files") or {}).items():
            path = planned.get(f["mirror_url"].rsplit("/", 1)[1])
            if path and fn in rules:
                problems += check_pe(path, rules[fn], f"{comp}/{fn}")
    for comp, v10 in (("optiscaler", False), ("optiscaler_v10", True)):
        e = idx["components"].get(comp)
        path = planned.get(e["mirror_url"].rsplit("/", 1)[1]) if e else None
        if not path:
            continue
        with tempfile.TemporaryDirectory(prefix="smoke-") as work:
            try:
                _7z(path, work, ["OptiScaler.dll", "OptiScaler.ini"])
                problems += check_pe(os.path.join(work, "OptiScaler.dll"), {}, f"{comp}/OptiScaler.dll")
                with open(os.path.join(work, "OptiScaler.ini"), encoding="utf-8", errors="replace") as f:
                    problems += [f"{comp}: {p}" for p in check_ini(f.read(), v10)]
            except (subprocess.SubprocessError, OSError) as e:
                problems.append(f"{comp}: the archive can't be read ({e})")
    if games and os.path.isfile(games):
        problems += check_games(games)
    return problems


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("dist")
    p.add_argument("--games")
    p.add_argument("--report")
    a = p.parse_args(argv)
    problems = run(a.dist, a.games)
    for line in problems:
        print(f"::error::{line}")
    if a.report:
        with open(a.report, "w", encoding="utf-8") as f:
            json.dump({"problems": problems}, f, indent=1)
    print("smoke check: " + ("ok" if not problems else f"{len(problems)} problem(s)"))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
