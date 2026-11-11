#!/usr/bin/env python3
"""The nightly fix audit: has anything changed upstream that makes a fix unnecessary?

    python3 tools/fixes/audit.py --out dist [--previous prev/audit-state.json]
                                 [--fixtures DIR | --record DIR] [--date YYYY-MM-DD]
    python3 tools/fixes/audit.py --links --out dist [--fixtures DIR]

For every fix (fixes/<id>/fix.json) it fetches the "watch" entries, and the ones in
tools/fixes/audit.json that concern every fix, and compares each with what the last run saw
(--previous, the signed snapshot from the "fixes" release). It writes, in --out:

    fixes.json         the definitions (tools/fixes/build.py) plus "built", "serial", "facts"
                       and, per fix, "audit": what was observed. This is what gets signed and
                       what handhelds download.
    audit-state.json   the new snapshot
    issues.json        what to tell maintainers: one entry per fix with a change, and a summary
    summary.md         the same, for the workflow's job summary

What it may decide alone (docs/FIXES.md, "The nightly audit"): only what a rule already declares.
A github-file watch with "records" sets the fix's upstream state; a kernel or system version
named in an obsolete_when is checked against the newest releases. It never writes a rule.

Everything fetched is data. Nothing from a page is executed or evaluated; the only strings that
leave this script are short, cleaned values (clean(), md()) inside issue text. A watch that can't
be fetched keeps its last observation and is listed as unreachable, never as changed.

--fixtures runs it from recorded answers (index.json: URL -> file, or URL -> {"status": 404}),
which is how the tests and a dry run work; --record saves the answers of a live run that way.
--links checks that every https source and watch link still answers (the weekly job).
Standard library only.
"""
import argparse
import datetime
import gzip
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

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

GLOBAL = os.path.join(HERE, "audit.json")
STATE_SCHEMA = 1
MAX_BODY = 4 * 1024 * 1024
REPO_URL = "https://github.com/IHulkSmashI/GameCove"
# Where the rolling data releases (firmware, fixes) are published. GAMECOVE_DATA_REPO moves them, with
# app/scripts/device/fix_data.gd and the workflow's DATA_REPO (docs/RELEASING.md, "Moving the data releases").
DATA_REPO = os.environ.get("GAMECOVE_DATA_REPO", "IHulkSmashI/GameCove")
FIRMWARE_URL = "https://github.com/%s/releases/download/firmware/firmware.json.gz" % DATA_REPO
UA = "GameCove-fix-audit (+%s)" % REPO_URL
# Which fields of an observation decide "it changed" (the rest is shown, not compared).
IDENTITY = {
    "github-file": ("present", "sha"), "github-commits": ("sha",), "github-release": ("tag",),
    "github-issue": ("state", "merged"), "gitlab-tags": ("tag",), "kernel-releases": ("mainline", "stable"),
    "firmware-index": ("version",), "lore": ("link",), "url": ("hash",),
}


class Unreachable(Exception):
    pass


def clean(value, limit=160):
    """A fetched string made safe to show: one line, printable, no markup, capped."""
    s = re.sub(r"[\x00-\x1f\x7f  ]+", " ", str(value))
    s = re.sub(r"[`<>\[\]|\\]", "", s).strip()
    return s[:limit]


def md(value, limit=160):
    """clean(), and nobody is pinged and no issue is cross-linked from fetched text."""
    return clean(value, limit).replace("@", "@​").replace("#", "#​")


class Fetcher:
    """HTTPS GET with a size cap; or recorded answers (fixtures), or recording them."""

    def __init__(self, fixtures=None, record=None, token=None):
        self.fixtures = fixtures
        self.record = record
        self.token = token
        self.index = {}
        if fixtures:
            with open(os.path.join(fixtures, "index.json"), encoding="utf-8") as f:
                self.index = json.load(f)
        self.recorded = {}

    def get(self, url):
        """(status, bytes). Raises Unreachable when there is no usable answer."""
        if not url.startswith("https://"):
            raise Unreachable("not https: %s" % url)
        if self.fixtures is not None:
            hit = self.index.get(url)
            if hit is None:
                raise Unreachable("no recorded answer for %s" % url)
            if isinstance(hit, dict):
                if "error" in hit:
                    raise Unreachable(hit["error"])
                return int(hit["status"]), b""
            with open(os.path.join(self.fixtures, hit), "rb") as f:
                return 200, f.read()
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/vnd.github+json, */*"})
        if self.token and urllib.parse.urlsplit(url).hostname == "api.github.com":
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = r.read(MAX_BODY + 1)
                status = r.status
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                status, body = e.code, b""
            else:
                raise Unreachable("HTTP %d for %s" % (e.code, url))
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise Unreachable("%s for %s" % (type(e).__name__, url))
        if len(body) > MAX_BODY:
            raise Unreachable("answer larger than %d bytes: %s" % (MAX_BODY, url))
        if self.record:
            self._save(url, status, body)
        return status, body

    def _save(self, url, status, body):
        os.makedirs(self.record, exist_ok=True)
        if status != 200:
            self.recorded[url] = {"status": status}
        else:
            name = hashlib.sha256(url.encode()).hexdigest()[:16] + ".bin"
            with open(os.path.join(self.record, name), "wb") as f:
                f.write(body)
            self.recorded[url] = name
        with open(os.path.join(self.record, "index.json"), "w", encoding="utf-8") as f:
            json.dump(self.recorded, f, indent=1, sort_keys=True)

    def json(self, url):
        status, body = self.get(url)
        if status != 200:
            return status, None
        try:
            return 200, json.loads(body)
        except ValueError:
            raise Unreachable("not JSON: %s" % url)


# ------------------------------------------------------------------ one observation per watch

def _gh(path):
    return "https://api.github.com/repos/" + path


def observe(w, fetch, cache):
    """What a watch shows now: a small dict of cleaned strings, plus "link" for people."""
    kind = w["kind"]
    if kind == "github-file":
        url = _gh("%s/contents/%s" % (w["repo"], urllib.parse.quote(w["path"])))
        status, doc = fetch.json(url)
        link = "https://github.com/%s/blob/HEAD/%s" % (w["repo"], urllib.parse.quote(w["path"]))
        if status == 404:
            return {"present": False, "sha": "", "link": link}
        if isinstance(doc, list):   # a folder: its listing
            sha = hashlib.sha256("".join(sorted(clean(e.get("sha", ""), 64) for e in doc if isinstance(e, dict))).encode()).hexdigest()[:40]
            return {"present": True, "sha": sha, "link": link}
        if not isinstance(doc, dict):
            raise Unreachable("unexpected answer for %s" % url)
        return {"present": True, "sha": clean(doc.get("sha", ""), 64), "link": link}
    if kind == "github-commits":
        q = "?per_page=1" + ("&path=" + urllib.parse.quote(w["path"]) if w.get("path") else "")
        status, doc = fetch.json(_gh(w["repo"] + "/commits" + q))
        if status != 200 or not isinstance(doc, list) or not doc or not isinstance(doc[0], dict):
            raise Unreachable("no commits listed for %s %s" % (w["repo"], w.get("path", "")))
        c = doc[0]
        sha = clean(c.get("sha", ""), 64)
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise Unreachable("no commit id for %s" % w["repo"])
        commit = c.get("commit") if isinstance(c.get("commit"), dict) else {}
        who = commit.get("committer") if isinstance(commit.get("committer"), dict) else {}
        return {"sha": sha, "date": clean(who.get("date", ""), 30),
                "subject": clean(str(commit.get("message", "")).split("\n", 1)[0], 120),
                "link": "https://github.com/%s/commit/%s" % (w["repo"], sha)}
    if kind == "github-release":
        status, doc = fetch.json(_gh(w["repo"] + "/releases/latest"))
        if status == 200 and isinstance(doc, dict):
            tag = clean(doc.get("tag_name", ""), 60)
            out = {"tag": tag, "date": clean(doc.get("published_at", ""), 30),
                   "link": "https://github.com/%s/releases/tag/%s" % (w["repo"], urllib.parse.quote(tag))}
            # the kernel a release's notes name (Bazzite): a version number only, never the text
            m = re.search(r"[Kk]ernel\D{0,40}?(\d+\.\d+(?:\.\d+)?)", str(doc.get("body", ""))[:200000])
            if m:
                out["kernel"] = m.group(1)
            return out
        status, doc = fetch.json(_gh(w["repo"] + "/tags?per_page=1"))
        if status != 200 or not isinstance(doc, list) or not doc or not isinstance(doc[0], dict):
            raise Unreachable("no release or tag for %s" % w["repo"])
        tag = clean(doc[0].get("name", ""), 60)
        return {"tag": tag, "date": "", "link": "https://github.com/%s/releases/tag/%s" % (w["repo"], urllib.parse.quote(tag))}
    if kind == "github-issue":
        status, doc = fetch.json(_gh("%s/issues/%d" % (w["repo"], w["number"])))
        if status != 200 or not isinstance(doc, dict):
            raise Unreachable("no issue %s#%d" % (w["repo"], w["number"]))
        pr = doc.get("pull_request") if isinstance(doc.get("pull_request"), dict) else None
        state = clean(doc.get("state", ""), 10)
        if state not in ("open", "closed"):
            raise Unreachable("unexpected state for %s#%d" % (w["repo"], w["number"]))
        return {"state": state, "merged": bool(pr and pr.get("merged_at")), "closed": clean(doc.get("closed_at") or "", 30),
                "title": clean(doc.get("title", ""), 120),
                "link": "https://github.com/%s/%s/%d" % (w["repo"], "pull" if pr else "issues", w["number"])}
    if kind == "gitlab-tags":
        url = "https://gitlab.com/api/v4/projects/%s/repository/tags?per_page=1" % urllib.parse.quote(w["project"], safe="")
        status, doc = fetch.json(url)
        if status != 200 or not isinstance(doc, list) or not doc or not isinstance(doc[0], dict):
            raise Unreachable("no tags for %s" % w["project"])
        commit = doc[0].get("commit") if isinstance(doc[0].get("commit"), dict) else {}
        tag = clean(doc[0].get("name", ""), 60)
        return {"tag": tag, "date": clean(commit.get("created_at", ""), 30),
                "link": "https://gitlab.com/%s/-/tags/%s" % (w["project"], urllib.parse.quote(tag))}
    if kind == "kernel-releases":
        status, doc = fetch.json("https://www.kernel.org/releases.json")
        if status != 200 or not isinstance(doc, dict) or not isinstance(doc.get("releases"), list):
            raise Unreachable("kernel.org releases.json")
        out = {"mainline": "", "stable": "", "longterm": "", "link": "https://www.kernel.org/"}
        for r in doc["releases"]:
            if not isinstance(r, dict):
                continue
            kind_, ver = str(r.get("moniker", "")), clean(r.get("version", ""), 30)
            if kind_ in out and not out[kind_] and re.fullmatch(r"\d+\.\d+(\.\d+)?(-rc\d+)?", ver):
                out[kind_] = ver
        if not out["stable"] and not out["mainline"]:
            raise Unreachable("kernel.org lists no release")
        return out
    if kind == "firmware-index":
        if "firmware" not in cache:
            status, body = fetch.get(FIRMWARE_URL)
            if status != 200:
                raise Unreachable("the firmware index isn't published")
            try:
                cache["firmware"] = json.loads(gzip.decompress(body))
            except (OSError, ValueError, EOFError):
                raise Unreachable("the firmware index doesn't parse")
        dev = cache["firmware"].get("devices", {}).get(w["device"], {}) if isinstance(cache["firmware"], dict) else {}
        for it in dev.get("items", []) if isinstance(dev, dict) and isinstance(dev.get("items"), list) else []:
            if isinstance(it, dict) and it.get("kind") == w["item"]:
                page = str(it.get("download_page") or dev.get("support_url") or "")
                return {"version": clean(it.get("version", ""), 40), "date": clean(it.get("date", ""), 30),
                        "link": page if page.startswith("https://") and " " not in page else "https://github.com/%s/releases/tag/firmware" % DATA_REPO}
        raise Unreachable("the firmware index has no %s for %s" % (w["item"], w["device"]))
    if kind == "lore":
        url = "https://lore.kernel.org/all/?q=%s&x=A" % urllib.parse.quote(w["query"])
        status, body = fetch.get(url)
        human = "https://lore.kernel.org/all/?q=%s" % urllib.parse.quote(w["query"])
        if status == 404:
            # public-inbox answers a search with no match with 404: nothing posted yet, not an outage
            return {"link": "", "title": "", "updated": "", "search": human}
        if status != 200:
            raise Unreachable("lore search")
        text = body.decode("utf-8", "replace")
        entry = re.search(r"<entry>(.*?)</entry>", text, re.S)
        if not entry:
            return {"link": "", "title": "", "updated": "", "search": human}
        e = entry.group(1)
        href = re.search(r'<link[^>]*href="(https://lore\.kernel\.org/[^"\s]+)"', e)
        title = re.search(r"<title[^>]*>(.*?)</title>", e, re.S)
        updated = re.search(r"<updated>(.*?)</updated>", e, re.S)
        return {"link": href.group(1) if href else "", "title": clean(title.group(1) if title else "", 120),
                "updated": clean(updated.group(1) if updated else "", 30), "search": human}
    if kind == "url":
        status, body = fetch.get(w["url"])
        if status != 200:
            raise Unreachable("HTTP %d for %s" % (status, w["url"]))
        # the words on the page, without scripts, markup and whitespace, so tokens and layout don't count
        text = body.decode("utf-8", "replace")
        text = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", text)
        text = re.sub(r"(?s)<[^>]*>", " ", text)
        text = re.sub(r"\s+", " ", text).strip()
        return {"hash": hashlib.sha256(text.encode()).hexdigest()[:20], "length": len(text), "link": w["url"]}
    raise Unreachable("watch kind %r isn't known" % kind)


def changed(kind, before, after):
    return any(before.get(k) != after.get(k) for k in IDENTITY[kind])


def describe(kind, o):
    """One cleaned line for an observation."""
    if kind == "github-file":
        return "present (%s)" % o.get("sha", "")[:10] if o.get("present") else "not there"
    if kind == "github-commits":
        return "%s %s: %s" % (o.get("sha", "")[:10], o.get("date", "")[:10], o.get("subject", ""))
    if kind in ("github-release", "gitlab-tags"):
        return "%s%s%s" % (o.get("tag", ""), " (%s)" % o["date"][:10] if o.get("date") else "", ", kernel %s" % o["kernel"] if o.get("kernel") else "")
    if kind == "github-issue":
        return "%s%s: %s" % ("merged" if o.get("merged") else o.get("state", ""), " %s" % o["closed"][:10] if o.get("closed") else "", o.get("title", ""))
    if kind == "kernel-releases":
        return "mainline %s, stable %s, longterm %s" % (o.get("mainline", "?"), o.get("stable", "?"), o.get("longterm", "?"))
    if kind == "firmware-index":
        return "%s%s" % (o.get("version", ""), " (%s)" % o["date"][:10] if o.get("date") else "")
    if kind == "lore":
        return "%s %s" % (o.get("updated", "")[:10], o.get("title", "")) if o.get("link") else "no message"
    return "content %s (%s characters)" % (o.get("hash", ""), o.get("length", "?"))


# ------------------------------------------------------------------ versions and declared rules

def numbers(version):
    m = re.match(r"[^0-9]*([0-9]+(?:\.[0-9]+)*)", str(version))
    return [int(p) for p in m.group(1).split(".")] if m else []


def holds(have, expr):
    """`have` against "<op><version>": True, False, or None when it can't be told."""
    m = re.fullmatch(r"(>=|<=|==|>|<)(.+)", str(expr))
    a, b = numbers(have), numbers(m.group(2)) if m else []
    if not m or not a or not b:
        return None
    n = max(len(a), len(b))
    a, b = a + [0] * (n - len(a)), b + [0] * (n - len(b))
    c = (a > b) - (a < b)
    return {">=": c >= 0, "<=": c <= 0, "==": c == 0, ">": c > 0, "<": c < 0}[m.group(1)]


def declared(fix, observed, facts, date):
    """What the fix's own declarations let the audit record by itself: {"upstream": {...}, "rules": [...]}."""
    upstream = {}
    for w in fix["watch"]:
        rec, o = w.get("records"), observed.get(w["id"])
        if not rec or not o:
            continue
        state = rec.get("present") if o.get("present") else rec.get("absent")
        if state:
            upstream[rec["os"]] = {"state": state, "watch": w["id"]}
    rules = []
    for leaf in build.conditions(fix["lifecycle"]["obsolete_when"]):
        if "kernel" in leaf:
            k = facts.get("kernel", {})
            newest = max((k.get("stable", ""), k.get("mainline", "").split("-")[0]), key=numbers)
            rules.append({"rule": "kernel " + leaf["kernel"], "released": holds(newest, leaf["kernel"]),
                          "in_bazzite": holds(facts.get("bazzite", {}).get("kernel", ""), leaf["kernel"])})
        elif leaf.get("os") == "bazzite" and "version" in leaf:
            rules.append({"rule": "bazzite " + leaf["version"], "released": holds(facts.get("bazzite", {}).get("tag", ""), leaf["version"])})
    return {"date": date, "upstream": upstream, "rules": rules}


# ------------------------------------------------------------------ the run

def load_previous(path):
    if not path or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) and d.get("schema") == STATE_SCHEMA and isinstance(d.get("observed"), dict) else {}


def global_watches():
    with open(GLOBAL, encoding="utf-8") as f:
        ws = json.load(f)["watch"]
    schema = build.load_schema()
    for w in ws:
        errs = build.validate(w, schema["$defs"]["watch"], schema, "audit.json")
        if errs:
            raise SystemExit("\n".join(errs))
    return ws


def run(defs, rows, fetch, previous, date, serial, deadline=None):
    prev = previous.get("observed", {})
    first = not prev
    state = {"schema": STATE_SCHEMA, "date": date, "observed": {}, "declared": {}}
    cache, unreachable, per_fix, general = {}, [], {}, []

    def look(key, w):
        try:
            if deadline and time.monotonic() > deadline:
                raise Unreachable("out of time")
            o = observe(w, fetch, cache)
        except Unreachable as e:
            unreachable.append("%s: %s" % (key, clean(e, 200)))
            if key in prev:
                state["observed"][key] = prev[key]   # keep what we knew
            return prev.get(key)
        state["observed"][key] = o
        return o

    facts = {}
    for w in global_watches():
        key = "global/" + w["id"]
        o = look(key, w)
        if o is None:
            continue
        facts[w["id"]] = {k: v for k, v in o.items() if k != "link"}
        if key in prev and changed(w["kind"], prev[key], o):
            general.append({"watch": w["id"], "kind": w["kind"], "note": w["note"], "before": describe(w["kind"], prev[key]),
                            "after": describe(w["kind"], o), "link": o.get("link", "")})
    doc = build.build_doc(defs, rows)
    doc["built"] = date
    doc["serial"] = serial
    doc["facts"] = facts
    for fix in doc["fixes"]:
        observed = {}
        for w in fix["watch"]:
            key = "%s/%s" % (fix["id"], w["id"])
            o = look(key, w)
            if o is None:
                continue
            observed[w["id"]] = o
            if key in prev and changed(w["kind"], prev[key], o):
                per_fix.setdefault(fix["id"], []).append({
                    "watch": w["id"], "kind": w["kind"], "note": w["note"], "before": describe(w["kind"], prev[key]),
                    "after": describe(w["kind"], o), "link": o.get("link") or o.get("search", ""), "auto": ""})
        audit = declared(fix, observed, facts, date)
        was = previous.get("declared", {}).get(fix["id"], {})
        state["declared"][fix["id"]] = {"upstream": audit["upstream"], "rules": audit["rules"]}
        if not first:
            for os_name, u in audit["upstream"].items():
                old = was.get("upstream", {}).get(os_name, {}).get("state")
                if old is not None and old != u["state"]:
                    per_fix.setdefault(fix["id"], []).append({
                        "watch": u["watch"], "kind": "recorded", "note": "Recorded in the published data by the audit itself.",
                        "before": "%s: %s" % (os_name, old), "after": "%s: %s" % (os_name, u["state"]), "link": "", "auto": "recorded"})
            old_rules = {r["rule"]: r for r in was.get("rules", []) if isinstance(r, dict)}
            for r in audit["rules"]:
                o = old_rules.get(r["rule"], {})
                for k, what in (("released", "is released"), ("in_bazzite", "is in the newest Bazzite")):
                    if r.get(k) is True and o.get(k) is not True and r["rule"] in old_rules:
                        per_fix.setdefault(fix["id"], []).append({
                            "watch": "rule", "kind": "recorded", "note": "A rule this fix already declares now holds upstream; handhelds on that version retire the fix by themselves.",
                            "before": "%s: not yet" % r["rule"], "after": "%s %s" % (r["rule"], what), "link": "", "auto": "recorded"})
        fix["audit"] = audit
    issues = {"date": date, "fixes": [], "summary": None, "unreachable": unreachable}
    titles = {f["id"]: f["title"] for f in doc["fixes"]}
    for fid in sorted(per_fix):
        issues["fixes"].append({"fix": fid, "title": "Fix audit: %s" % fid, "marker": "<!-- fix-audit:%s -->" % fid,
                                "body": issue_body(fid, titles[fid], per_fix[fid], date)})
    if per_fix or general:
        issues["summary"] = {"title": "Fix audit summary", "marker": "<!-- fix-audit:summary -->",
                             "body": summary_body(per_fix, general, unreachable, titles, date)}
    return doc, state, issues


def _change_lines(c):
    out = ["- **%s** (%s)%s" % (md(c["watch"], 60), md(c["kind"], 30), ", recorded automatically" if c.get("auto") else ""),
           "  - was: `%s`" % md(c["before"]), "  - now: `%s`" % md(c["after"]), "  - why we watch it: %s" % c["note"]]
    link = str(c.get("link", ""))
    if link.startswith("https://") and re.fullmatch(r"[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+", link):
        out.append("  - %s" % link)
    return out


def issue_body(fid, title, changes, date):
    lines = ["<!-- fix-audit:%s -->" % fid,
             "The nightly audit of %s saw a change in what the **%s** fix (`fixes/%s/fix.json`) watches." % (date, title, fid), ""]
    for c in changes:
        lines.extend(_change_lines(c))
    lines += ["", "What to do: read the change. If it means the problem is now fixed upstream, add the rule to the fix's "
              "`lifecycle.obsolete_when` (a kernel, system, BIOS or tool version, or a file) or set `withdrawn`, set "
              "`audited` to today and close this issue. If it changes nothing, just close it. The audit never edits "
              "rules itself (docs/FIXES.md).", "",
              "Everything quoted above is fetched data, shown as text."]
    return "\n".join(lines) + "\n"


def summary_body(per_fix, general, unreachable, titles, date):
    lines = ["<!-- fix-audit:summary -->", "Fix audit of %s." % date, ""]
    if per_fix:
        lines.append("Fixes with a change (each has its own `fix-audit` issue):")
        lines.extend("- `%s` (%s): %d change(s)%s" % (f, titles[f], len(c), ", %d recorded automatically" % sum(1 for x in c if x.get("auto")) if any(x.get("auto") for x in c) else "")
                     for f, c in sorted(per_fix.items()))
        lines.append("")
    if general:
        lines.append("Upstream in general:")
        for c in general:
            lines.extend(_change_lines(c))
        lines.append("")
    if unreachable:
        lines.append("Couldn't be fetched this run (their last known state was kept):")
        lines.extend("- `%s`" % md(u, 200) for u in unreachable[:40])
    return "\n".join(lines) + "\n"


# ------------------------------------------------------------------ the weekly link check

def links_of(defs):
    """[(fix id, url)] for every https source and every link a watch points at."""
    out = []
    for fid, d in sorted(defs.items()):
        urls = [s for s in d["sources"] if s.startswith("https://") and " " not in s]
        for w in d["watch"]:
            if w["kind"] == "url":
                urls.append(w["url"])
            elif w["kind"] == "github-issue":
                urls.append("https://github.com/%s/issues/%d" % (w["repo"], w["number"]))
            elif w["kind"] in ("github-file", "github-commits", "github-release"):
                urls.append("https://github.com/" + w["repo"])
        seen = set()
        for u in urls:
            if u not in seen:
                seen.add(u)
                out.append((fid, u))
    return out


def check_links(defs, fetch, date):
    dead, cache = [], {}
    for fid, url in links_of(defs):
        if url not in cache:
            try:
                status, _ = fetch.get(url)
                cache[url] = "" if status == 200 else "HTTP %d" % status
            except Unreachable as e:
                cache[url] = clean(e, 120)
        if cache[url]:
            dead.append({"fix": fid, "url": url, "why": cache[url]})
    issues = {"date": date, "fixes": [], "summary": None, "unreachable": []}
    if dead:
        lines = ["<!-- fix-audit:links -->", "Link check of %s: these sources no longer answer. Find where each moved and update "
                 "the fix's `sources` / `watch`, or drop it when another source says the same." % date, ""]
        lines.extend("- `fixes/%s/fix.json`: %s (%s)" % (d["fix"], d["url"] if re.fullmatch(r"[A-Za-z0-9._~:/?#@!$&'()*+,;=%-]+", d["url"]) else "(unprintable link)", md(d["why"], 120)) for d in dead)
        issues["summary"] = {"title": "Fix audit: dead links", "marker": "<!-- fix-audit:links -->", "body": "\n".join(lines) + "\n"}
    return dead, issues


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--previous")
    ap.add_argument("--fixtures")
    ap.add_argument("--record")
    ap.add_argument("--links", action="store_true")
    ap.add_argument("--date")
    ap.add_argument("--serial", type=int)
    ap.add_argument("--max-minutes", type=float, default=15)
    a = ap.parse_args(argv)
    defs, problems = build.load_all()
    rows = build.device_rows()
    problems = problems or build.rules(defs, rows)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    date = a.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    fetch = Fetcher(a.fixtures, a.record, os.environ.get("GITHUB_TOKEN"))
    os.makedirs(a.out, exist_ok=True)

    def put(name, value):
        with open(os.path.join(a.out, name), "w", encoding="utf-8") as f:
            f.write(value if isinstance(value, str) else json.dumps(value, indent=1, ensure_ascii=False) + "\n")

    if a.links:
        dead, issues = check_links(defs, fetch, date)
        put("issues.json", issues)
        put("summary.md", issues["summary"]["body"] if issues["summary"] else "Every source link answers.\n")
        print("%d dead link(s)" % len(dead))
        return 0
    serial = a.serial if a.serial is not None else int(time.time())
    doc, state, issues = run(defs, rows, fetch, load_previous(a.previous), date, serial,
                             time.monotonic() + a.max_minutes * 60)
    put("fixes.json", build.render_json(doc))
    put("audit-state.json", state)
    put("issues.json", issues)
    put("summary.md", issues["summary"]["body"] if issues["summary"] else "Fix audit of %s: nothing changed.\n%s" % (
        date, "".join("- unreachable: `%s`\n" % md(u, 200) for u in issues["unreachable"][:40])))
    print("%d fix(es) with a change, %d unreachable watch(es)" % (len(issues["fixes"]), len(issues["unreachable"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
