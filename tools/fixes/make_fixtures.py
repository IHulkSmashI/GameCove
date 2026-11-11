#!/usr/bin/env python3
"""Answers for a fix audit without the network: one file per URL the audit would fetch.

    python3 tools/fixes/make_fixtures.py DIR [--night 2]

Writes DIR/index.json and the answer files in the shapes the real services use (GitHub's REST
API, GitLab's tags, kernel.org's releases.json, a lore Atom feed, plain pages, GameCove's firmware
index), for every watch the fix definitions and tools/fixes/audit.json declare. The tests and
CI's dry run of the nightly workflow use it:

    make_fixtures.py n1            &&  audit.py --fixtures n1 --out d1
    make_fixtures.py n2 --night 2  &&  audit.py --fixtures n2 --out d2 --previous d1/audit-state.json

Night 2 is night 1 with a handful of upstream changes (CHANGES below): a Bazzite rule file gone,
a pull request merged, a new InputPlumber commit, a new BIOS, a new kernel and Bazzite release.
To capture real answers instead, run audit.py --record DIR on a machine with network access.
"""
import gzip
import hashlib
import importlib.util
import json
import os
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("gamecove_fixes_audit", os.path.join(HERE, "audit.py"))
audit = sys.modules.get("gamecove_fixes_audit") or importlib.util.module_from_spec(spec)
if "gamecove_fixes_audit" not in sys.modules:
    sys.modules["gamecove_fixes_audit"] = audit
    spec.loader.exec_module(audit)
build = audit.build

# What differs on night 2: "<fix>/<watch id>" or "global/<id>".
CHANGES = {"ally-controller-wakeup/bazzite-rule", "onexfly-touch/chimera-pr-128", "claw8ex-buttons/ip-config",
           "claw8ex-gyro/ip-config", "claw8ex-buttons/bios", "claw8ex-vrr/bios", "claw8ex-gyro/bios", "global/kernel",
           "global/bazzite"}


def _sha(text):
    return hashlib.sha1(text.encode()).hexdigest()


def answers(night):
    """{url: bytes | {"status": int}} for every watch."""
    defs, problems = build.load_all()
    if problems:
        raise SystemExit("\n".join(problems))
    out = {}
    firmware = {"schema": 1, "devices": {}}

    def put(url, value):
        out[url] = value if isinstance(value, dict) and "status" in value and len(value) == 1 else json.dumps(value).encode()

    def one(key, w):
        new = night == 2 and key in CHANGES
        kind = w["kind"]
        gh = "https://api.github.com/repos/"
        if kind == "github-file":
            url = gh + "%s/contents/%s" % (w["repo"], urllib.parse.quote(w["path"]))
            put(url, {"status": 404} if new else {"type": "file", "sha": _sha(key), "path": w["path"]})
        elif kind == "github-commits":
            q = "?per_page=1" + ("&path=" + urllib.parse.quote(w["path"]) if w.get("path") else "")
            put(gh + w["repo"] + "/commits" + q, [{"sha": _sha(key + ("2" if new else "")),
                "commit": {"message": ("Add a capability map for the Claw 8 EX\n\nbody" if new else "Update %s\n\nbody" % (w.get("path") or "the tree")),
                           "committer": {"date": "2026-11-%02dT08:00:00Z" % (10 if new else 2)}}}])
        elif kind == "github-release":
            tag = {"global/bazzite": ("44.20261105", "45.20261110")}.get(key, ("v1.2.0", "v1.3.0"))[1 if new else 0]
            body = "## Changes\n| Kernel | %s |\n" % ("6.19.2-ba02" if new else "6.17.7-ba25") if key == "global/bazzite" else "notes"
            put(gh + w["repo"] + "/releases/latest", {"tag_name": tag, "published_at": "2026-11-%02dT00:00:00Z" % (10 if new else 5), "body": body})
        elif kind == "github-issue":
            doc = {"state": "closed" if new else "open", "closed_at": "2026-11-10T07:00:00Z" if new else None,
                   "title": "fix: treat OneXFly F1 panel as internal" if "pr" in w["id"] else "Report %d" % w["number"]}
            if "pr" in w["id"]:
                doc["pull_request"] = {"merged_at": "2026-11-10T07:00:00Z" if new else None}
            put(gh + "%s/issues/%d" % (w["repo"], w["number"]), doc)
        elif kind == "gitlab-tags":
            put("https://gitlab.com/api/v4/projects/%s/repository/tags?per_page=1" % urllib.parse.quote(w["project"], safe=""),
                [{"name": "20261110" if new else "20261015", "commit": {"created_at": "2026-10-15T00:00:00Z"}}])
        elif kind == "kernel-releases":
            put("https://www.kernel.org/releases.json", {"releases": [
                {"moniker": "mainline", "version": "6.20-rc3" if new else "6.19-rc7"},
                {"moniker": "stable", "version": "6.19.2" if new else "6.18.9"},
                {"moniker": "longterm", "version": "6.12.60"}]})
        elif kind == "firmware-index":
            dev = firmware["devices"].setdefault(w["device"], {"support_url": "https://www.msi.com/Handheld/support", "items": []})
            if not any(i["kind"] == w["item"] for i in dev["items"]):
                dev["items"].append({"kind": w["item"], "name": "BIOS", "version": "E1T91IMS.10F" if new else "E1T91IMS.10E", "date": "2026-11-01"})
        elif kind == "lore":
            entry = "" if not new else "<entry><title>[PATCH] drm: quirk</title><updated>2026-11-10T00:00:00Z</updated><link href=\"https://lore.kernel.org/all/2026x@y/\"/></entry>"
            out["https://lore.kernel.org/all/?q=%s&x=A" % urllib.parse.quote(w["query"])] = ("<feed>%s</feed>" % entry).encode()
        elif kind == "url":
            out[w["url"]] = ("<html><script>var t=%d</script><body>Notes %s</body></html>" % (night, "B" if new else "A")).encode()

    for w in audit.global_watches():
        one("global/" + w["id"], w)
    for fid, d in sorted(defs.items()):
        for w in d["watch"]:
            one("%s/%s" % (fid, w["id"]), w)
    out[audit.FIRMWARE_URL] = gzip.compress(json.dumps(firmware).encode(), mtime=0)
    return out


def write(folder, night=1):
    os.makedirs(folder, exist_ok=True)
    index = {}
    for url, value in sorted(answers(night).items()):
        if isinstance(value, dict):
            index[url] = value
            continue
        name = hashlib.sha256(url.encode()).hexdigest()[:16] + ".bin"
        with open(os.path.join(folder, name), "wb") as f:
            f.write(value)
        index[url] = name
    with open(os.path.join(folder, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, sort_keys=True)
    return index


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    write(sys.argv[1], 2 if sys.argv[2:4] == ["--night", "2"] else 1)
