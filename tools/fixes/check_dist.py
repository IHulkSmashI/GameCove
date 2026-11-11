#!/usr/bin/env python3
"""Checks the audit's output before it is signed (the publish job of .github/workflows/fixes.yml).

    python3 -I tools/fixes/check_dist.py dist

The signing job trusts nothing the fetching job made: dist/fixes.json must be exactly what this
checkout's fixes/<id>/fix.json files build (tools/fixes/build.py), plus only "built", "serial",
"facts" and a per-fix "audit" block of the expected shape. So a compromised fetch (or a page that
tricked the audit) can't change a rule, withdraw a fix or add one: rules only change through a
reviewed commit. Standard library only.
"""
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _sibling(name):
    """tools/fixes/<name>.py under its own module name ("build" alone is taken by other tools)."""
    full = "gamecove_fixes_" + name
    if full not in sys.modules:
        spec = importlib.util.spec_from_file_location(full, os.path.join(HERE, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[full] = mod
        spec.loader.exec_module(mod)
    return sys.modules[full]


build = _sibling("build")

MAX_BYTES = 2 * 1024 * 1024   # the app's cap (fix_data.gd MAX_BYTES)
DATE = r"20[0-9]{2}-[01][0-9]-[0-3][0-9]"


def _short(v, n=200):
    return isinstance(v, str) and len(v) <= n and not re.search(r"[\x00-\x1f]", v)


def problems(dist):
    path = os.path.join(dist, "fixes.json")
    raw = open(path, "rb").read()
    if len(raw) > MAX_BYTES:
        return ["fixes.json is larger than the app accepts"]
    doc = json.loads(raw)
    defs, errs = build.load_all()
    errs = errs or build.rules(defs, build.device_rows())
    if errs:
        return errs
    want = build.build_doc(defs, build.device_rows())
    out = []
    if not isinstance(doc, dict) or doc.get("schema") != build.DATA_SCHEMA:
        return ["not a schema-%d document" % build.DATA_SCHEMA]
    if set(doc) - set(want) - {"built", "serial", "facts"}:
        out.append("unknown top-level keys: %s" % sorted(set(doc) - set(want) - {"built", "serial", "facts"}))
    if not re.fullmatch(DATE, str(doc.get("built", ""))):
        out.append("built isn't a date")
    if not isinstance(doc.get("serial"), int) or isinstance(doc.get("serial"), bool) or doc["serial"] <= 0:
        out.append("serial isn't a positive whole number")
    facts = doc.get("facts")
    if not isinstance(facts, dict) or any(not isinstance(v, dict) or any(not (_short(x) or isinstance(x, (bool, int))) for x in v.values()) for v in facts.values()):
        out.append("facts isn't a map of small maps")
    got = doc.get("fixes")
    if not isinstance(got, list) or [f.get("id") if isinstance(f, dict) else None for f in got] != [f["id"] for f in want["fixes"]]:
        return out + ["the fixes aren't the ones in this checkout, in order"]
    for g, w in zip(got, want["fixes"]):
        audit = g.get("audit")
        rest = {k: v for k, v in g.items() if k != "audit"}
        if rest != w:
            keys = sorted(k for k in set(rest) | set(w) if rest.get(k) != w.get(k))
            out.append("%s: differs from fixes/%s/fix.json in %s" % (w["id"], w["id"], ", ".join(keys)))
        if not isinstance(audit, dict) or set(audit) != {"date", "upstream", "rules"} or not re.fullmatch(DATE, str(audit.get("date", ""))):
            out.append("%s: audit block missing or of another shape" % w["id"])
            continue
        up = audit["upstream"]
        if not isinstance(up, dict) or any(k not in ("bazzite", "steamos") or not isinstance(v, dict) or v.get("state") not in ("fixed", "not-fixed") or not _short(v.get("watch"), 41) or set(v) != {"state", "watch"} for k, v in up.items()):
            out.append("%s: audit.upstream of another shape" % w["id"])
        rules = audit["rules"]
        if not isinstance(rules, list) or any(not isinstance(r, dict) or not _short(r.get("rule"), 80) or set(r) - {"rule", "released", "in_bazzite"} or any(r.get(k) not in (True, False, None) for k in ("released", "in_bazzite")) for r in rules):
            out.append("%s: audit.rules of another shape" % w["id"])
    return out


def main(argv):
    errs = problems(argv[0] if argv else "dist")
    for e in errs:
        print(e, file=sys.stderr)
    if not errs:
        print("fixes.json matches this checkout's definitions")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
