#!/usr/bin/env python3
"""GameCove end-to-end suite driver (GPL-3.0).

Builds the fake devices (three handhelds and a Steam Machine) once (tools/devicematrix/gen.py --setups), then runs
the real app headless on each one, in its own process with a private HOME and
XDG folders, so nothing of the machine running the tests is used or changed:

  python3 -I app/tests/e2e/run.py                    # every setup, every suite
  python3 -I app/tests/e2e/run.py --setups ally-steamos --suites quick_menu
  python3 -I app/tests/e2e/run.py --iters 50 --seed 7  # randomized parts 50 times
  E2E_SOAK=1 python3 -I app/tests/e2e/run.py         # long soak (200 iterations)

Each setup runs as: one process for every suite but the restart suite, then the
restart suite in two processes on the same files (phase 1 changes settings,
phase 2 is the app started again). After each process, no process it started
may be left (orphan check). Seeds are printed so a failure can be replayed with
--seed. Exit 1 on any failure.

Env: GODOT (path to the Godot binary), E2E_SOAK=1.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.dirname(os.path.dirname(HERE))
REPO = os.path.dirname(APP)
GEN = os.path.join(REPO, "tools", "devicematrix", "gen.py")
SETUPS = ["claw8ex-bazzite", "ally-steamos", "legion-go-s-bazzite", "steam-machine-steamos"]
ROWS = {"claw8ex-bazzite": "msi-claw-8-ex", "ally-steamos": "asus-rog-ally",
        "legion-go-s-bazzite": "lenovo-legion-go-s-z2go", "steam-machine-steamos": "valve-steam-machine"}
RESTART_SUITE = "restart"
## Suites that run in a process of their own (they bring the player's games and
## store tools along, and a long random run shouldn't share a process with the rest).
OWN_PROCESS = ["journeys", "monkey"]
# The Steam Machine has no TDP slider, battery or backlight, which is what the profile, restart,
# robustness, settings and game suites drive: it runs the suites that fit a box (suite_box.gd
# covers what must be absent there).
BOX_SUITES = "smoke,screens,box,capabilities,library,quick_menu,saves,perf,animations"
BOXED = ["steam-machine-steamos"]


def godot_path(arg: str) -> str:
    # --godot, $GODOT, a tools/ folder next to the checkout, then godot on PATH (no machine-specific paths)
    beside = os.path.join(os.path.dirname(REPO), "tools", "Godot_v4.7.2-stable_linux.x86_64")
    for p in (arg, os.environ.get("GODOT", ""), beside, shutil.which("godot") or ""):
        if p and os.path.exists(p):
            return p
    sys.exit("Godot not found: pass --godot or set GODOT")


def private_env(work: str, info_path: str, extra: dict) -> dict:
    env = {k: v for k, v in os.environ.items()
           if k in ("PATH", "LANG", "LC_ALL", "TERM", "USER", "LOGNAME", "TZ") or k.startswith("E2E_")}
    home = os.path.join(work, "home-real")
    run = os.path.join(work, "xdg", "run")
    for d in (home, run, os.path.join(work, "xdg", "data"), os.path.join(work, "xdg", "config"),
              os.path.join(work, "xdg", "cache")):
        os.makedirs(d, exist_ok=True)
    os.chmod(run, 0o700)
    env.update({
        "HOME": home, "XDG_DATA_HOME": os.path.join(work, "xdg", "data"),
        "XDG_CONFIG_HOME": os.path.join(work, "xdg", "config"), "XDG_CACHE_HOME": os.path.join(work, "xdg", "cache"),
        "XDG_RUNTIME_DIR": run,
        # no session bus, no display, no gamescope of the machine running this
        "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + os.path.join(run, "no-bus"),
        "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=" + os.path.join(run, "no-system-bus"),
        "E2E_WORK": work, "E2E_INFO": info_path,
    })
    env.update(extra)
    return env


def prepare(fixtures: str, manifest: dict, setup: str, base: str) -> tuple[str, str]:
    info = next(s for s in manifest["setups"] if s["id"] == setup)
    work = os.path.join(base, "work-" + setup)
    if os.path.exists(work):
        shutil.rmtree(work)
    os.makedirs(work)
    shutil.copytree(os.path.join(fixtures, setup), os.path.join(work, "fixture"), symlinks=True)
    root = os.path.join(work, "fixture", "root")
    pristine = os.path.join(work, "pristine")
    shutil.copytree(root, pristine, symlinks=True)
    info = dict(info, root=root, home=os.path.join(root, "home"), backends=os.path.join(work, "fixture", "backends.json"),
                pristine=pristine)
    info_path = os.path.join(work, "info.json")
    with open(info_path, "w", encoding="utf-8") as f:
        json.dump(info, f, indent=1)
    return work, info_path


def leftovers(work: str, before: set) -> list[str]:
    """Processes still running that this run started (their command names the work folder)."""
    out = []
    try:
        ps = subprocess.run(["ps", "-eo", "pid=,args="], capture_output=True, text=True, check=False).stdout
    except OSError:
        return out
    for line in ps.splitlines():
        pid, _, args = line.strip().partition(" ")
        if pid.isdigit() and int(pid) not in before and work in args and "run.py" not in args:
            out.append(line.strip())
    return out


def pids() -> set:
    try:
        ps = subprocess.run(["ps", "-eo", "pid="], capture_output=True, text=True, check=False).stdout
    except OSError:
        return set()
    return {int(x) for x in ps.split() if x.isdigit()}


def run_one(godot: str, work: str, info_path: str, extra: dict, timeout: int, label: str, verbose: bool) -> dict:
    env = private_env(work, info_path, extra)
    before = pids()
    t0 = time.time()
    cmd = [godot, "--headless", "--path", APP, "-s", "res://tests/e2e/run_e2e.gd"]
    try:
        p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout, check=False)
        out, err, code = p.stdout, p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = (e.stderr.decode() if isinstance(e.stderr, bytes) else (e.stderr or "")) + f"\nTIMEOUT after {timeout} s"
        code = 124
    result = None
    for line in out.splitlines():
        if line.startswith("E2E RESULT "):
            try:
                result = json.loads(line[len("E2E RESULT "):])
            except json.JSONDecodeError:
                pass
        elif verbose and (line.startswith("E2E ") or os.environ.get("E2E_RAW")):
            print("  " + line)
    if result is None:
        result = {"passed": 0, "failed": 1, "failures": [f"{label}: no result (exit {code})"]}
        tail = "\n".join((out + "\n" + err).splitlines()[-40:])
        result["failures"].append(tail)
    for line in err.splitlines():
        if line.startswith("E2E FAIL"):
            print("  " + line)
    time.sleep(0.2)
    left = leftovers(work, before)
    if left:
        result["failed"] += 1
        result["failures"].append(f"{label}: processes left running: {left}")
    if code not in (0, 1) and code != 124:
        result["failed"] += 1
        result["failures"].append(f"{label}: Godot exited with {code} (crash?)")
        crash = os.path.join(work, f"crash-{label.replace('/', '-')}-{int(time.time())}.log")
        with open(crash, "w", encoding="utf-8") as f:
            f.write(out + "\n----- stderr -----\n" + err)
        result["failures"].append("last lines of stderr:\n" + "\n".join(err.splitlines()[-25:]))
    if code == 124:
        result["failed"] += 1
        result["failures"].append(f"{label}: timed out")
    result["seconds"] = round(time.time() - t0, 1)
    return result


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--setups", default=",".join(SETUPS))
    ap.add_argument("--suites", default="", help="comma list of suite file name parts")
    ap.add_argument("--test", default="", help="part of a test name")
    ap.add_argument("--iters", type=int, default=0, help="iterations of the randomized parts (default 5, soak 200)")
    ap.add_argument("--seed", type=int, default=0, help="first seed (default: from the clock, printed)")
    ap.add_argument("--godot", default="")
    ap.add_argument("--keep", action="store_true", help="keep the work folder")
    ap.add_argument("--timeout", type=int, default=0)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    soak = os.environ.get("E2E_SOAK", "") not in ("", "0")
    iters = a.iters or (200 if soak else 5)
    seed = a.seed or int(time.time()) % 100000
    timeout = a.timeout or (3600 if soak else 900)
    godot = godot_path(a.godot)
    setups = [s for s in a.setups.split(",") if s]
    print(f"e2e: setups {setups}, iterations {iters}, seed {seed} (replay: --seed {seed} --iters {iters})")
    base = tempfile.mkdtemp(prefix="gamecove-e2e-")
    fixtures = os.path.join(base, "fixtures")
    rows = ",".join(ROWS[s] for s in setups)
    g = subprocess.run([sys.executable, "-I", GEN, fixtures, "--only", rows, "--setups", ",".join(setups)],
                       capture_output=True, text=True, check=False)
    if g.returncode != 0:
        print(g.stdout + g.stderr)
        return 1
    with open(os.path.join(fixtures, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    total_fail = 0
    total_pass = 0
    for setup in setups:
        work, info_path = prepare(fixtures, manifest, setup, base)
        common = {"E2E_SEED": str(seed), "E2E_ITERS": str(iters), "E2E_TEST": a.test}
        suites = [s for s in a.suites.split(",") if s]
        if setup in BOXED:
            fit = BOX_SUITES.split(",")
            suites = [s for s in suites if s in fit] if suites else fit
            if not suites:
                continue
        runs = []
        shared = [s for s in suites if s != RESTART_SUITE and s not in OWN_PROCESS]
        if not suites or shared:
            runs.append(("main", dict(common, E2E_SUITES=",".join(shared) or "suite_",
                                      E2E_SKIP=",".join([RESTART_SUITE] + OWN_PROCESS))))
        for own in OWN_PROCESS:
            if not suites or own in suites:
                runs.append((own, dict(common, E2E_SUITES=own, E2E_SKIP=RESTART_SUITE)))
        if not suites or RESTART_SUITE in suites:
            runs.append(("restart-1", dict(common, E2E_SUITES=RESTART_SUITE, E2E_PHASE="1")))
            runs.append(("restart-2", dict(common, E2E_SUITES=RESTART_SUITE, E2E_PHASE="2")))
        for label, extra in runs:
            r = run_one(godot, work, info_path, extra, timeout, f"{setup}/{label}", a.verbose)
            total_fail += int(r.get("failed", 0))
            total_pass += int(r.get("passed", 0))
            state = "ok" if not r.get("failed") else "FAILED"
            skipped = f", {r['skipped']} pending merge" if r.get("skipped") else ""
            print(f"{setup}/{label}: {r.get('passed', 0)} passed, {r.get('failed', 0)} failed{skipped} in {r['seconds']} s ({state})")
            for msg in r.get("failures", [])[:80]:
                print("    " + str(msg))
    if not a.keep:
        shutil.rmtree(base, ignore_errors=True)
        subprocess.run(["chattr", "-R", "-i", base], capture_output=True, check=False)
        shutil.rmtree(base, ignore_errors=True)
    else:
        print("work folder kept: " + base)
    print(f"e2e: {total_pass} passed, {total_fail} failed (seed {seed}, iterations {iters})")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
