#!/usr/bin/env python3
"""Shared-component traits: who shares what, and which fixes and quirks apply where (and why).

Handhelds share parts: the same SoC, EC driver, controller, Wi-Fi card, panel or whole body.
devices.json gives every row a "traits" object; fixes (app/data/fixes.json), quirks
(app/data/quirks.json) and device-matrix expectations name the devices they're for with
*selectors* over those traits, so something found on one model reaches every sibling.
app/scripts/device/traits.gd implements the same rules for the app (the tests check both agree).

Selector grammar (docs/DEVICES.md, Traits):
    "*"                          every row
    "<device id>"                one row
    "<key>:<pat>|<pat>"          a trait value (shell globs, any case); list traits match when any
                                 element matches; keys: TRAIT_KEYS, id, family, maker, tier,
                                 panel (= panel.id), panel.<field>, driver (gpu_driver or ec),
                                 vendor (= cpu_vendor)
    ["a", "b"]                   any of them (shorthand for {"any-of": [...]})
    {"any-of": [...]} {"all-of": [...]} {"not": sel}

Report:
    python3 tools/traits/traits.py trait wifi:ax210        every model sharing a trait (or any selector)
    python3 tools/traits/traits.py trait wifi              every value of a trait and who has it
    python3 tools/traits/traits.py model msi-claw-8-ex     traits, siblings, and every fix/quirk that
                                                           applies there and why
    python3 tools/traits/traits.py fixes                   each fix's device set
    python3 tools/traits/traits.py check                   validate traits and selectors (exit 1 on a problem)
"""
import fnmatch
import json
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEVICES = os.path.join(REPO, "app", "data", "devices.json")
FIXES = os.path.join(REPO, "app", "data", "fixes.json")
QUIRKS = os.path.join(REPO, "app", "data", "quirks.json")
EXPECT = os.path.join(REPO, "tools", "devicematrix", "expectations.json")
MATRIX_RUNTIME = ("vendor", "driver", "stack")  # matrix selectors read from the fixture, not traits

# trait -> (kind, allowed values or None). kind: str | list | panel
TRAIT_KEYS = {
    "platform": "str",       # shared body / board group
    "soc": "list",
    "gpu_arch": "list",
    "gpu_driver": "list",
    "cpu_vendor": "str",
    "ec": "list",            # platform / EC drivers
    "controller": "str",     # built-in controller family (USB ids from InputPlumber)
    "imu": "str",
    "wifi": "list",
    "panel": "panel",
    "audio": "list",
    "fingerprint": "str",    # USB id of the reader, or a placeholder when the id isn't known
    "firmware": "str",
    "session_quirk": "str",  # gamescope-session-plus device-quirks block
}
META_KEYS = ("sources", "unverified")
PANEL_KEYS = ("id", "vendor", "model", "hz", "orientation", "touch", "type", "gamescope")
ALLOWED = {
    "cpu_vendor": {"amd", "intel"},
    "gpu_arch": {"rdna2", "rdna3", "rdna3.5", "xe-lpg", "xe2", "xe3"},
    "gpu_driver": {"amdgpu", "i915", "xe"},
}
PANEL_ORIENT = {"left-up", "right-up", "bottom-up"}
SELECTOR_KEYS = set(TRAIT_KEYS) | {"id", "family", "maker", "tier", "driver", "vendor", "panel"} | {"panel." + k for k in PANEL_KEYS}
FIX_SEL_KEYS = ("auto", "optional")


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def rows(path=DEVICES):
    return load_json(path)["devices"]


def catalogue(path=FIXES):
    return load_json(path)["fixes"]


def quirks(path=QUIRKS):
    return load_json(path)["quirks"] if os.path.exists(path) else []


def values(row, key):
    """The row's values for a selector key, as a list of strings (empty = unknown / none)."""
    t = row.get("traits") or {}
    if key in ("id", "family", "maker", "tier"):
        v = row.get(key)
    elif key == "vendor":
        v = t.get("cpu_vendor")
    elif key == "driver":
        v = list(t.get("gpu_driver") or []) + list(t.get("ec") or [])
    elif key == "panel":
        v = (t.get("panel") or {}).get("id")
    elif key.startswith("panel."):
        v = (t.get("panel") or {}).get(key[6:])
        if isinstance(v, list):  # hz range
            v = "%s-%s" % tuple(v)
        elif isinstance(v, bool):
            v = "yes" if v else "no"
    else:
        v = t.get(key)
    if v is None:
        return []
    return [str(x) for x in v] if isinstance(v, list) else [str(v)]


def selector_problems(sel, where="selector"):
    out = []
    if isinstance(sel, list):
        for s in sel:
            out += selector_problems(s, where)
    elif isinstance(sel, dict):
        if len(sel) != 1 or next(iter(sel)) not in ("any-of", "all-of", "not"):
            out.append("%s: object needs exactly one of any-of, all-of, not: %r" % (where, sel))
        else:
            k, v = next(iter(sel.items()))
            if k == "not":
                out += selector_problems(v, where)
            elif not isinstance(v, list) or not v:
                out.append("%s: %s needs a non-empty list" % (where, k))
            else:
                out += selector_problems(v, where)
    elif isinstance(sel, str):
        if sel != "*" and ":" in sel:
            k, v = sel.split(":", 1)
            if k not in SELECTOR_KEYS:
                out.append("%s: unknown trait key %r in %r" % (where, k, sel))
            if v == "":
                out.append("%s: empty value in %r" % (where, sel))
        elif sel == "":
            out.append("%s: empty selector" % where)
    else:
        out.append("%s: a selector is a string, list or object, not %r" % (where, sel))
    return out


def matches(sel, row):
    """True when the selector picks this row."""
    if isinstance(sel, list):
        return any(matches(s, row) for s in sel)
    if isinstance(sel, dict):
        k, v = next(iter(sel.items()))
        if k == "any-of":
            return any(matches(s, row) for s in v)
        if k == "all-of":
            return all(matches(s, row) for s in v)
        if k == "not":
            return not matches(v, row)
        return False
    sel = str(sel)
    if sel == "*":
        return True
    if ":" not in sel:
        return sel == row.get("id")
    key, pats = sel.split(":", 1)
    have = [x.lower() for x in values(row, key)]
    for p in pats.lower().split("|"):
        for h in have:
            if fnmatch.fnmatchcase(h, p):
                return True
    return False


def why(sel, row):
    """The parts of the selector that hold for this row, as short text."""
    if isinstance(sel, list):
        sel = {"any-of": sel}
    if isinstance(sel, dict):
        k, v = next(iter(sel.items()))
        if k == "not":
            return "not (%s)" % describe(v)
        parts = [why(s, row) for s in v if matches(s, row)]
        return " and ".join(parts) if k == "all-of" else (parts[0] if parts else "")
    sel = str(sel)
    if sel == "*" or ":" not in sel:
        return "every handheld" if sel == "*" else "this model"
    key = sel.split(":", 1)[0]
    return "%s %s" % (key, "/".join(values(row, key)))


def describe(sel):
    if isinstance(sel, list):
        return " or ".join(describe(s) for s in sel)
    if isinstance(sel, dict):
        k, v = next(iter(sel.items()))
        if k == "not":
            return "not " + describe(v)
        return (" and " if k == "all-of" else " or ").join("(%s)" % describe(s) for s in v)
    return str(sel)


def resolve(sel, all_rows, exclude=()):
    if sel is None:
        return []
    return [r["id"] for r in all_rows if r["id"] not in exclude and matches(sel, r)]


def fix_sets(entry, all_rows):
    """{"auto": [ids], "optional": [ids]} for one catalogue entry (optional never repeats auto)."""
    excl = entry.get("exclude") or {}
    auto = resolve(entry.get("auto"), all_rows, excl) if entry.get("auto") not in (None, []) else []
    opt = resolve(entry.get("optional"), all_rows, excl) if entry.get("optional") not in (None, []) else []
    return {"auto": auto, "optional": [i for i in opt if i not in auto]}


def is_everywhere(sel):
    return sel == "*" or sel == ["*"]


def auto_fixes(row, cat):
    """Folder fixes (kind root / file) the installer applies on this row, in catalogue order."""
    out = []
    for e in cat:
        if e.get("kind") not in ("root", "file"):
            continue
        if row["id"] in (e.get("exclude") or {}):
            continue
        if e.get("auto") not in (None, []) and matches(e["auto"], row):
            out.append(e["id"])
    return out


# ------------------------------------------------------------------ validation

def trait_problems(row):
    rid = row.get("id", "?")
    t = row.get("traits")
    if not isinstance(t, dict):
        return ["%s: missing traits" % rid]
    out = []
    for k in t:
        if k not in TRAIT_KEYS and k not in META_KEYS:
            out.append("%s: unknown trait %s" % (rid, k))
    for k, kind in TRAIT_KEYS.items():
        if k not in t:
            out.append("%s: traits.%s missing (null when unknown)" % (rid, k))
            continue
        v = t[k]
        if v is None:
            continue
        if kind == "str":
            if not isinstance(v, str) or not v or v != v.lower() or " " in v:
                out.append("%s: traits.%s must be a lower-case id without spaces" % (rid, k))
            elif k in ALLOWED and v not in ALLOWED[k]:
                out.append("%s: traits.%s %s not one of %s" % (rid, k, v, sorted(ALLOWED[k])))
        elif kind == "list":
            if not isinstance(v, list) or not v:
                out.append("%s: traits.%s must be a non-empty list or null" % (rid, k))
                continue
            for x in v:
                if not isinstance(x, str) or not x or x != x.lower() or " " in x:
                    out.append("%s: traits.%s value %r must be a lower-case id" % (rid, k, x))
                elif k in ALLOWED and x not in ALLOWED[k]:
                    out.append("%s: traits.%s %s not one of %s" % (rid, k, x, sorted(ALLOWED[k])))
        elif kind == "panel":
            if not isinstance(v, dict) or not isinstance(v.get("id"), str) or not v["id"]:
                out.append("%s: traits.panel needs an id" % rid)
                continue
            for pk in v:
                if pk not in PANEL_KEYS:
                    out.append("%s: traits.panel.%s unknown" % (rid, pk))
            if "orientation" in v and v["orientation"] not in PANEL_ORIENT:
                out.append("%s: traits.panel.orientation %s" % (rid, v["orientation"]))
            hz = v.get("hz")
            if hz is not None and (not isinstance(hz, list) or len(hz) != 2 or hz[0] > hz[1]):
                out.append("%s: traits.panel.hz must be [lo, hi]" % rid)
            if "touch" in v and not isinstance(v["touch"], bool):
                out.append("%s: traits.panel.touch must be true/false" % rid)
    src = t.get("sources")
    if not isinstance(src, list) or not src:
        out.append("%s: traits.sources needs at least one source key" % rid)
    for u in t.get("unverified") or []:
        if u not in TRAIT_KEYS:
            out.append("%s: traits.unverified names %s, not a trait" % (rid, u))
    # consistency with the row's older fields
    if t.get("cpu_vendor") and row.get("cpu_vendor") and t["cpu_vendor"] != row["cpu_vendor"]:
        out.append("%s: traits.cpu_vendor %s but cpu_vendor %s" % (rid, t["cpu_vendor"], row["cpu_vendor"]))
    ga = str(row.get("gpu_arch", "")).lower()
    if t.get("gpu_arch") and ga not in ("", "unknown") and ga not in t["gpu_arch"]:
        out.append("%s: traits.gpu_arch %s lacks gpu_arch %s" % (rid, t["gpu_arch"], ga))
    return out


def all_problems(all_rows=None, cat=None, qs=None, src_keys=None):
    all_rows = rows() if all_rows is None else all_rows
    cat = catalogue() if cat is None else cat
    qs = quirks() if qs is None else qs
    if src_keys is None:
        src_keys = set(load_json(DEVICES).get("_trait_sources", {}))
    out = []
    ids = {r["id"] for r in all_rows}
    for r in all_rows:
        out += trait_problems(r)
        for s in (r.get("traits") or {}).get("sources") or []:
            if src_keys and s not in src_keys:
                out.append("%s: traits.sources %s isn't in _trait_sources" % (r["id"], s))
    for e in cat:
        for k in FIX_SEL_KEYS:
            if e.get(k) not in (None, []):
                out += selector_problems(e[k], "fixes.json %s.%s" % (e["id"], k))
                out += _unknown_ids(e[k], ids, "fixes.json %s.%s" % (e["id"], k))
        excl = e.get("exclude", {})
        if not isinstance(excl, dict):
            out.append("fixes.json %s.exclude must map device id -> reason" % e["id"])
        else:
            for i, reason in excl.items():
                if i not in ids:
                    out.append("fixes.json %s.exclude: unknown device %s" % (e["id"], i))
                if not str(reason).strip():
                    out.append("fixes.json %s.exclude.%s needs a reason" % (e["id"], i))
        if e.get("kind") in ("root", "file") and not e.get("why"):
            out.append("fixes.json %s: needs \"why\" (the shared part that makes it apply)" % e["id"])
    if os.path.exists(EXPECT):
        for sel in load_json(EXPECT).get("devices", {}):
            for part in sel.split("+"):
                k = part.split(":", 1)[0] if ":" in part else ""
                # "<row id>@<variant>": an extra matrix fixture of a row as seen on a real
                # setup (tools/devicematrix/overrides.json)
                if part in ("*", "generic", "generic-box-amd") or part in ids or k in MATRIX_RUNTIME or ("@" in part and part.split("@", 1)[0] in ids):
                    continue
                if not k or k not in SELECTOR_KEYS:
                    out.append("expectations.json devices: unknown device or selector %s" % sel)
                elif not resolve(part, all_rows):
                    out.append("expectations.json devices: %s picks no device" % sel)
    for q in qs:
        out += selector_problems(q.get("applies"), "quirks.json %s.applies" % q.get("id"))
        out += _unknown_ids(q.get("applies"), ids, "quirks.json %s.applies" % q.get("id"))
        for k in ("id", "applies", "what", "why", "sources"):
            if not q.get(k):
                out.append("quirks.json %s: needs %s" % (q.get("id", "?"), k))
        if q.get("applies") is not None and not resolve(q["applies"], all_rows):
            out.append("quirks.json %s: applies to no device" % q.get("id"))
    return out


def _unknown_ids(sel, ids, where):
    out = []
    if isinstance(sel, list):
        for s in sel:
            out += _unknown_ids(s, ids, where)
    elif isinstance(sel, dict):
        for v in sel.values():
            out += _unknown_ids(v, ids, where)
    elif isinstance(sel, str) and sel != "*" and ":" not in sel and sel not in ids:
        out.append("%s: unknown device %s" % (where, sel))
    return out


# ------------------------------------------------------------------ report

def _row(all_rows, rid):
    for r in all_rows:
        if r["id"] == rid:
            return r
    raise SystemExit("unknown device %s" % rid)


def report_trait(arg, all_rows):
    lines = []
    if ":" not in arg and arg in SELECTOR_KEYS:
        groups = {}
        for r in all_rows:
            for v in values(r, arg) or ["(unknown)"]:
                groups.setdefault(v, []).append(r["id"])
        for v in sorted(groups, key=lambda x: (-len(groups[x]), x)):
            lines.append("%s:%s (%d): %s" % (arg, v, len(groups[v]), ", ".join(groups[v])))
        return lines
    sel = json.loads(arg) if arg[:1] in "[{" else arg
    probs = selector_problems(sel)
    if probs:
        raise SystemExit("; ".join(probs))
    ids = resolve(sel, all_rows)
    lines.append("%s: %d model(s)" % (describe(sel), len(ids)))
    for r in all_rows:
        if r["id"] in ids:
            unv = " (unverified)" if ":" in str(sel) and str(sel).split(":", 1)[0] in (r["traits"].get("unverified") or []) else ""
            lines.append("  %-28s %s%s" % (r["id"], r["name"], unv))
    return lines


def report_model(rid, all_rows, cat, qs):
    r = _row(all_rows, rid)
    t = r["traits"]
    lines = ["%s (%s)" % (r["name"], rid), "traits:"]
    for k in TRAIT_KEYS:
        v = t.get(k)
        if v is None:
            continue
        mark = "  (unverified)" if k in (t.get("unverified") or []) else ""
        vs = json.dumps(v, ensure_ascii=False) if isinstance(v, dict) else ("/".join(v) if isinstance(v, list) else v)
        sib = [x["id"] for x in all_rows if x["id"] != rid and k != "panel" and set(values(x, k)) & set(values(r, k))]
        if k == "panel":
            sib = [x["id"] for x in all_rows if x["id"] != rid and values(x, "panel") == values(r, "panel")]
        lines.append("  %-14s %s%s" % (k, vs, mark))
        if sib:
            lines.append("  %-14s   shared with: %s" % ("", ", ".join(sib)))
    lines.append("fixes:")
    for e in cat:
        sets = fix_sets(e, all_rows)
        excl = (e.get("exclude") or {}).get(rid)
        if rid in sets["auto"]:
            lines.append("  %-24s auto      because %s" % (e["id"], why(e["auto"], r)))
        elif rid in sets["optional"]:
            lines.append("  %-24s optional  because %s" % (e["id"], why(e["optional"], r)))
        elif excl:
            lines.append("  %-24s excluded  %s" % (e["id"], excl))
    lines.append("quirks:")
    for q in qs:
        if matches(q["applies"], r):
            lines.append("  %-24s %s (because %s)" % (q["id"], q["what"], why(q["applies"], r)))
    if os.path.exists(EXPECT):
        lines.append("device-matrix expectations (tools/devicematrix/expectations.json):")
        for sel, per in load_json(EXPECT).get("devices", {}).items():
            hit, runtime = matrix_selector(sel, r)
            if hit:
                n = len([k for k in per if not k.startswith("_")])
                lines.append("  %-34s %d control check(s)%s" % (sel, n, " (if the fixture's stack/driver matches)" if runtime else ""))
    return lines


def matrix_selector(sel, row):
    """(applies, depends on the fixture) for an expectations.json "devices" key."""
    runtime = False
    for part in sel.split("+"):
        k = part.split(":", 1)[0] if ":" in part else ""
        if k in MATRIX_RUNTIME:
            runtime = True
            if k == "vendor" and not matches(part, row):
                return False, False
            continue
        if part == "generic":
            if row.get("tier") != "generic":
                return False, False
            continue
        if not matches(part, row):
            return False, False
    return True, runtime


def report_fixes(all_rows, cat):
    lines = []
    for e in cat:
        s = fix_sets(e, all_rows)
        if not s["auto"] and not s["optional"]:
            continue
        lines.append("%s  [%s]" % (e["id"], describe(e.get("auto")) if e.get("auto") else "-"))
        if s["auto"]:
            lines.append("  auto:     " + ", ".join(s["auto"]))
        if s["optional"]:
            lines.append("  optional: " + ", ".join(s["optional"]))
        for i, reason in (e.get("exclude") or {}).items():
            lines.append("  not on %s: %s" % (i, reason))
    return lines


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    all_rows, cat, qs = rows(), catalogue(), quirks()
    cmd = argv[0]
    if cmd == "check":
        p = all_problems(all_rows, cat, qs)
        for x in p:
            print(x, file=sys.stderr)
        return 1 if p else 0
    if cmd == "trait" and len(argv) == 2:
        out = report_trait(argv[1], all_rows)
    elif cmd == "model" and len(argv) == 2:
        out = report_model(argv[1], all_rows, cat, qs)
    elif cmd == "fixes":
        out = report_fixes(all_rows, cat)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
