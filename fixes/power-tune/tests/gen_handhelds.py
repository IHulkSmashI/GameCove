#!/usr/bin/env python3
"""Writes fixes/power-tune/handhelds.txt: EVERY handheld row of app/data/devices.json
(the power-tune verbs that touch firmware power limits or battery modes act only on
these). Same format and code as tools/fixes/gen_handhelds.py, without its filter.

    python3 -I fixes/power-tune/tests/gen_handhelds.py          rewrite the file
    python3 -I fixes/power-tune/tests/gen_handhelds.py --check  exit 1 when it is stale
"""
import importlib.util
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
OUT = os.path.join(REPO, "fixes", "power-tune", "handhelds.txt")
spec = importlib.util.spec_from_file_location("gen", os.path.join(REPO, "tools", "fixes", "gen_handhelds.py"))
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
gen.uses_fixes = lambda row: True
text = gen.render().replace(
    "# Handhelds the fan and charge-limit fixes may write to (DMI ids, shell globs, any case).",
    "# Every handheld GameCove knows: power-tune sets firmware power limits and battery modes only on these.").replace(
    "tools/fixes/gen_handhelds.py", "fixes/power-tune/tests/gen_handhelds.py")
if "--check" in sys.argv[1:]:
    have = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if have != text:
        print("fixes/power-tune/handhelds.txt is stale: run python3 -I fixes/power-tune/tests/gen_handhelds.py", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
open(OUT, "w", encoding="utf-8").write(text)
