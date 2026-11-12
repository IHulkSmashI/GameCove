#!/usr/bin/env python3
"""Layout matrix runner (GPL-3.0, part of GameCove).

Puts the real screens (the showcase profile and the screenshot tools' sets:
every screen, sheet, dialog, quick menu tab, settings page, setup and
installer step) on every screen size in app/tests/layout/matrix.gd and runs
app/tests/layout/layout_checks.gd on each. Headless: nothing is drawn, so a
4K row costs the same as an 800p one.

  python3 -I tools/layout/run.py --ci             the reduced set CI runs
  python3 -I tools/layout/run.py --full           every distinct layout
  python3 -I tools/layout/run.py --rows tv-4k-55in,panel-1280x800-7in
  python3 -I tools/layout/run.py --full --sets showcase,installer
  python3 -I tools/layout/run.py --rows tv-4k-55in --form console   wording on a Steam Machine

Every shot also gets the focus walk (app/tests/layout/focus_walk.gd, the
controller rules of docs/CONTROLLER-UX.md; FOCUS_WALK=0 skips it), whose own
test (app/tests/layout/walk_selftest.gd) runs first.

Rows that get the same layout are run once (the first row stands for the
group; the report names them all). Exit 1 when a check fails that isn't in
tools/layout/known.json (each entry there says why it is accepted).
Reports: OUT/<row>/<set>.json; tools/layout/summary.py OUT/* prints them.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(REPO, "app")
SETS = {
    "showcase": "../tools/showcase/showcase.gd",
    "stream": "../tools/showcase/showcase_stream.gd",
    "installer": "../tools/screenshots/shoot_installer.gd",
    "shots": "../tools/screenshots/shoot.gd",
    "controls": "../tools/screenshots/shoot_controls.gd",
    "device": "../tools/screenshots/shoot_device.gd",
    "streaming": "../tools/screenshots/shoot_streaming.gd",
}
# Light theme: geometry is the same, so one layout is enough.
CI_SETS = ["showcase", "installer", "shots"]


def godot_path(arg: str) -> str:
    beside = os.path.join(os.path.dirname(REPO), "tools", "Godot_v4.7.2-stable_linux.x86_64")
    for p in (arg, os.environ.get("GODOT", ""), beside, shutil.which("godot") or ""):
        if p and os.path.exists(p):
            return p
    sys.exit("Godot not found: pass --godot or set GODOT")


def matrix(godot: str) -> list:
    out = subprocess.run([godot, "--headless", "--path", APP, "-s", "../tools/layout/dump_matrix.gd"],
                         capture_output=True, text=True, check=False).stdout
    for line in out.splitlines():
        if line.startswith("MATRIX "):
            return json.loads(line[7:])
    sys.exit("could not read the matrix:\n" + out[-2000:])


def known() -> list:
    with open(os.path.join(HERE, "known.json"), encoding="utf-8") as f:
        return [k for k in json.load(f)["known"]]


def is_known(kn: list, row: str, set_name: str, shot: str, p: dict) -> bool:
    for k in kn:
        if k.get("kind", "*") not in ("*", p["kind"]):
            continue
        if not fnmatch.fnmatch(row, k.get("row", "*")) or not fnmatch.fnmatch(set_name, k.get("set", "*")):
            continue
        if not fnmatch.fnmatch(shot, k.get("shot", "*")) or not fnmatch.fnmatch(p["node"], k.get("node", "*")):
            continue
        if not fnmatch.fnmatch(p["detail"], k.get("detail", "*")):
            continue
        return True
    return False


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ci", action="store_true")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--rows", default="")
    ap.add_argument("--sets", default="")
    ap.add_argument("--form", default="", help="console | desktop: also check the wording for a device that isn't a handheld")
    ap.add_argument("--theme", default="cove")
    ap.add_argument("--out", default="")
    ap.add_argument("--godot", default="")
    ap.add_argument("--timeout", type=int, default=1500)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args(argv)
    godot = godot_path(a.godot)
    subprocess.run([godot, "--headless", "--path", APP, "--import"], capture_output=True, check=False)
    if os.environ.get("FOCUS_WALK", "1") != "0":
        st = subprocess.run([godot, "--headless", "--path", APP, "-s", "res://tests/layout/walk_selftest.gd"],
                            capture_output=True, text=True, timeout=300, check=False)
        print("\n".join(l for l in (st.stdout + st.stderr).splitlines() if l.startswith("WALK SELFTEST")), flush=True)
        if st.returncode != 0 or "SCRIPT ERROR" in st.stdout + st.stderr:
            print((st.stdout + st.stderr)[-3000:])
            sys.exit("the focus walk's own test failed")
    rows = matrix(godot)
    by_id = {r["id"]: r for r in rows}
    if a.rows:
        wanted = [by_id[i] for i in a.rows.split(",") if i in by_id]
        missing = [i for i in a.rows.split(",") if i not in by_id]
        if missing:
            sys.exit(f"not in the matrix: {missing}")
    else:
        seen = set()
        wanted = []
        for r in rows:
            if a.ci and not a.full and not r["ci"]:
                continue
            if not (a.ci or a.full):
                continue
            key = tuple(r["layout"])
            if key in seen:
                continue
            seen.add(key)
            wanted.append(r)
    if not wanted:
        sys.exit("nothing to run: pass --ci, --full or --rows")
    sets = [s for s in (a.sets.split(",") if a.sets else (CI_SETS if a.ci and not a.full else list(SETS))) if s]
    out = a.out or tempfile.mkdtemp(prefix="gamecove-layout-")
    kn = known()
    failures = 0
    accepted = 0
    shots = 0
    t0 = time.time()
    for r in wanted:
        same = [x["id"] for x in rows if x["layout"] == r["layout"] and x["id"] != r["id"]]
        print(f"layout {r['layout'][0]}x{r['layout'][1]}: {r['id']} ({r['size'][0]}x{r['size'][1]}, x{r['scale']:.2f})"
              + (f"; same layout: {', '.join(same)}" if same else ""), flush=True)
        for s in sets:
            d = os.path.join(out, r["id"])
            os.makedirs(d, exist_ok=True)
            home = tempfile.mkdtemp(prefix="gamecove-layout-home-")
            env = {k: v for k, v in os.environ.items() if k in ("PATH", "LANG", "LC_ALL", "TERM", "USER", "TZ", "FOCUS_WALK")}
            env.update({"HOME": home, "XDG_DATA_HOME": os.path.join(home, "data"), "XDG_CACHE_HOME": os.path.join(home, "cache"),
                        "XDG_CONFIG_HOME": os.path.join(home, "config"), "LAYOUT_ROW": r["id"], "LAYOUT_OUT": d,
                        "LAYOUT_FORM": a.form, "SHOWCASE_THEME": a.theme, "SHOOT_THEME": "" if a.theme == "cove" else a.theme})
            report = os.path.join(d, ("shoot_" + s if s in ("installer", "controls", "device", "streaming") else
                                      {"showcase": "showcase", "stream": "showcase_stream", "shots": "shoot"}[s]) + ".json")
            if os.path.exists(report):
                os.remove(report)
            tail, errs = "", []
            for _attempt in range(4):   # more tries when the process died before its report (killed for memory on a busy machine)
                try:
                    p = subprocess.run([godot, "--headless", "--path", APP, "-s", SETS[s], "--", "--out", d + "/"],
                                       env=env, capture_output=True, text=True, timeout=a.timeout, check=False)
                    tail = (p.stdout + p.stderr)[-1500:]
                    errs = [l for l in (p.stdout + p.stderr).splitlines() if "SCRIPT ERROR" in l]
                except subprocess.TimeoutExpired:
                    tail, errs = "timed out", ["timed out"]
                if os.path.exists(report):
                    break
                time.sleep(30)
            shutil.rmtree(home, ignore_errors=True)
            if not os.path.exists(report):
                print(f"  {s}: FAILED, no report\n{tail}")
                failures += 1
                continue
            with open(report, encoding="utf-8") as f:
                doc = json.load(f)
            bad = 0
            for shot in doc["order"]:
                shots += 1
                for pr in doc["shots"][shot]["problems"]:
                    if is_known(kn, r["id"], s, shot, pr):
                        accepted += 1
                        continue
                    bad += 1
                    print(f"  FAIL {s}/{shot} [{pr['kind']}] {pr['text']!r} {pr['detail']} ({pr['node'][-80:]})", flush=True)
            for e in errs[:5]:
                print(f"  FAIL {s}: {e}")
                bad += 1
            failures += bad
            if a.verbose or bad:
                print(f"  {s}: {len(doc['order'])} shots, {bad} problems", flush=True)
    print(f"layout: {len(wanted)} layouts, {shots} shots, {failures} failed, {accepted} accepted (known.json), "
          f"{int(time.time() - t0)} s; reports in {out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
