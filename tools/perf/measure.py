#!/usr/bin/env python3
"""GameCove performance harness driver (GPL-3.0).

Runs the real app on a fake handheld (the e2e fixture, tools/devicematrix/gen.py)
in a private HOME / XDG folder, holds it in each state (home, quick menu over
home, a game in front, quick menu over the game) and prints what the process
costs there: CPU, wakeups (context switches), main-loop iterations, drawn
frames, memory, threads, child processes, write syscalls and heartbeat writes.
Then the quick menu's latency over a game and the resume handling's timing.

  python3 -I tools/perf/measure.py                     # 60 s per state, headless
  python3 -I tools/perf/measure.py --seconds 20 --display xvfb   # drawn on Xvfb (llvmpipe)
  python3 -I tools/perf/measure.py --json before.json  # keep the numbers
  python3 -I tools/perf/measure.py --compare before.json after.json  # table of both

The app is measured from inside (/proc/self, tests/perf/proc_stats.gd) so the
numbers line up with the states exactly. Real GPU cost can't be seen here: see
docs/PERFORMANCE.md for measuring on the handheld.

Env: GODOT (path to the Godot binary).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(REPO, "app")
E2E = os.path.join(APP, "tests", "e2e", "run.py")


def e2e():
    spec = importlib.util.spec_from_file_location("gamecove_e2e_run", E2E)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(args) -> dict:
    r = e2e()
    godot = r.godot_path(args.godot)
    base = tempfile.mkdtemp(prefix="gamecove-perf-")
    try:
        fixtures = os.path.join(base, "fixtures")
        g = subprocess.run([sys.executable, "-I", r.GEN, fixtures, "--only", r.ROWS[args.setup], "--setups", args.setup],
                           capture_output=True, text=True, check=False)
        if g.returncode != 0:
            sys.exit(g.stdout + g.stderr)
        with open(os.path.join(fixtures, "manifest.json"), encoding="utf-8") as f:
            manifest = json.load(f)
        work, info_path = r.prepare(fixtures, manifest, args.setup, base)
        env = r.private_env(work, info_path, {
            "PERF_SECONDS": str(args.seconds), "PERF_STATES": args.states,
            "PERF_LATENCY_RUNS": str(args.latency_runs), "PERF_RESUME_RUNS": str(args.resume_runs),
            "PERF_SETTLE_S": str(args.settle),
        })
        env["GAMECOVE_HEARTBEAT"] = os.path.join(env["XDG_RUNTIME_DIR"], "gamecove-heartbeat")
        cmd = [godot, "--path", APP, "-s", "res://tests/perf/run_perf.gd"]
        if args.display == "headless":
            cmd.insert(1, "--headless")
        else:
            xvfb = shutil.which("xvfb-run")
            if not xvfb:
                sys.exit("xvfb-run not found (apt install xvfb)")
            env["LIBGL_ALWAYS_SOFTWARE"] = "1"
            cmd = [xvfb, "-a", "-s", "-screen 0 1280x800x24"] + cmd + ["--rendering-driver", "opengl3"]
        log_path = os.path.join(base, "godot.log")
        with open(log_path, "w", encoding="utf-8") as log:
            p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=log, text=True)
            out_lines = []
            for line in p.stdout:
                out_lines.append(line.rstrip("\n"))
                if args.verbose and line.startswith("PERF "):
                    print(line.rstrip("\n"), flush=True)
            try:
                p.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                p.kill()
        with open(log_path, encoding="utf-8") as log:
            err = log.read()
        out = "\n".join(out_lines)
        res = None
        for line in out_lines:
            if line.startswith("PERF RESULT "):
                res = json.loads(line[len("PERF RESULT "):])
        fails = [l for l in (out + err).splitlines() if "PERF FAIL" in l or "SCRIPT ERROR" in l]
        if res is None or fails:
            print("\n".join((out + "\n" + err).splitlines()[-60:]))
            sys.exit("perf run failed")
        return res
    finally:
        subprocess.run(["chattr", "-R", "-i", base], capture_output=True, check=False)
        shutil.rmtree(base, ignore_errors=True)


ROWS = [("cpu_pct", "CPU %"), ("cpu_ms_per_s", "CPU ms/s (threads)"), ("wake_per_s", "wakeups/s (all threads)"),
        ("main_wake_per_s", "wakeups/s (main thread)"), ("loops_per_s", "main-loop iterations/s"),
        ("frames_per_s", "frames drawn/s"), ("rss_mb", "RSS MB"), ("threads", "threads"),
        ("writes_per_min", "write syscalls/min"), ("heartbeats_per_min", "heartbeat writes/min"), ("children", "child processes")]


def _cell(v) -> str:
    if isinstance(v, list):
        return ", ".join(v) if v else "none"
    return str(v)


def table(results: list[tuple[str, dict]]) -> str:
    states = []
    for _, r in results:
        for s in r["states"]:
            if s not in states:
                states.append(s)
    head = "| metric | " + " | ".join(f"{s} ({label})" if label else s for s in states for label, _ in results) + " |"
    out = [head, "|" + "---|" * (1 + len(states) * len(results))]
    for key, name in ROWS:
        cells = [_cell(r["states"].get(s, {}).get(key, "")) for s in states for _, r in results]
        out.append(f"| {name} | " + " | ".join(cells) + " |")
    for label, r in results:
        lat = r.get("latency_ms", [])
        if lat:
            out.append(f"\nquick menu over a game{' (' + label + ')' if label else ''}: "
                       f"median {sorted(lat)[len(lat) // 2]} ms, max {max(lat)} ms over {len(lat)} presses")
        res = r.get("resume", [])
        if res:
            out.append(f"resume{' (' + label + ')' if label else ''}: `resumed` {max(x['resumed_ms'] for x in res)} ms, "
                       f"controls replayed {max(x['replayed_ms'] for x in res)} ms after the check was due (worst of {len(res)})")
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--setup", default="claw8ex-bazzite")
    ap.add_argument("--seconds", type=float, default=60.0)
    ap.add_argument("--settle", type=float, default=10.0)
    ap.add_argument("--states", default="")
    ap.add_argument("--latency-runs", type=int, default=10)
    ap.add_argument("--resume-runs", type=int, default=4)
    ap.add_argument("--display", choices=["headless", "xvfb"], default="headless")
    ap.add_argument("--godot", default="")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--json", default="", help="write the result here")
    ap.add_argument("--compare", nargs="+", default=[], help="print a table of saved results (label=path or path)")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    if a.compare:
        rs = []
        for c in a.compare:
            label, _, path = c.rpartition("=")
            with open(path, encoding="utf-8") as f:
                rs.append((label or os.path.splitext(os.path.basename(path))[0], json.load(f)))
        print(table(rs))
        return 0
    res = run(a)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(res, f, indent=1)
    print(f"setup {res.get('setup')}, display {res.get('display')}, {res.get('seconds')} s per state")
    print(table([("", res)]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
