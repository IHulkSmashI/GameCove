#!/usr/bin/env python3
"""Prints what tools/layout runs found: summary.py DIR [DIR ...] (folders holding <set>.json)."""
import collections
import glob
import json
import os
import sys


def main(argv):
    total = 0
    for d in argv:
        for path in sorted(glob.glob(os.path.join(d, "*.json"))):
            doc = json.load(open(path, encoding="utf-8"))
            seen = collections.OrderedDict()
            for shot in doc["order"]:
                for p in doc["shots"][shot]["problems"]:
                    key = (p["kind"], p["node"], p["text"], p["detail"])
                    seen.setdefault(key, []).append(shot)
            print(f"== {doc['row']} {doc['set']}: layout {doc['layout'][0]}x{doc['layout'][1]}, {len(doc['order'])} shots, {len(seen)} distinct problems")
            for (kind, node, text, detail), shots in seen.items():
                total += 1
                where = ",".join(shots[:3]) + ("…" if len(shots) > 3 else "")
                print(f"  [{kind}] {where}: {text!r} {detail}  ({node[-70:]})")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
