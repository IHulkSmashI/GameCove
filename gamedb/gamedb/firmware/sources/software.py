"""Newest upstream versions of the Linux driver stack (kernel, Mesa, linux-firmware) and the
handheld daemons/tools GameCove works with. Upstream only: what the OS channel ships is the
app's job (rpm-ostree / SteamOS updater)."""
from __future__ import annotations

import os
import re
import urllib.parse

from .common import date, load_json

KERNEL = "https://www.kernel.org/releases.json"
GITHUB = "https://api.github.com/repos/{repo}/releases/latest"
GITLAB = "{base}/api/v4/projects/{project}/repository/tags?per_page=50&order_by=updated"


def kernel(doc: object) -> dict:
    if not isinstance(doc, dict):
        return {}
    v = str((doc.get("latest_stable") or {}).get("version") or "")
    rel = next((r for r in doc.get("releases", []) if isinstance(r, dict) and r.get("version") == v), {})
    return {"version": v, "date": date((rel.get("released") or {}).get("isodate")),
            "notes_url": str(rel.get("changelog") or "https://www.kernel.org/")} if v else {}


def github(doc: object, repo: str) -> dict:
    if not isinstance(doc, dict) or not doc.get("tag_name"):
        return {}
    tag = str(doc["tag_name"])
    return {"version": tag[1:] if re.match(r"^v\d", tag) else tag, "date": date(doc.get("published_at")),
            "notes_url": str(doc.get("html_url") or f"https://github.com/{repo}/releases")}


def gitlab_tags(doc: object, pattern: str, notes: str) -> dict:
    best = None
    for t in doc if isinstance(doc, list) else []:
        m = re.match(pattern, str(t.get("name", "")))
        if not m or "rc" in m.group(1):
            continue
        key = [int(x) for x in re.findall(r"\d+", m.group(1))]
        if best is None or key > best[0]:
            best = (key, m.group(1), t)
    if not best:
        return {}
    commit = best[2].get("commit") or {}
    return {"version": best[1], "date": date(commit.get("committed_date") or commit.get("created_at")), "notes_url": notes}


def cgit_tags(page: str, pattern: str, notes: str) -> dict:
    tags = re.findall(pattern, page)
    if not tags:
        return {}
    v = max(tags)
    return {"version": v, "date": f"{v[:4]}-{v[4:6]}-{v[6:]}" if len(v) == 8 else "", "notes_url": notes}


def _gh_headers() -> dict:
    h = {"Accept": "application/vnd.github+json"}
    tok = os.environ.get("GITHUB_TOKEN", "")
    if tok:
        h["Authorization"] = "Bearer " + tok
    return h


def fetch(client, name: str, spec: dict) -> dict:
    k = spec["kind"]
    if k == "kernel_org":
        return kernel(load_json(client.get(KERNEL)))
    if k == "github":
        return github(load_json(client.get(GITHUB.format(repo=spec["repo"]), headers=_gh_headers())), spec["repo"])
    if k == "cgit_tags":
        return cgit_tags(client.get(spec["url"]).decode("utf-8", "replace"), spec["pattern"], spec["notes"])
    if k == "gitlab_tags":
        url = GITLAB.format(base=spec["base"], project=urllib.parse.quote(spec["project"], safe=""))
        return gitlab_tags(load_json(client.get(url)), spec["pattern"], spec["notes"])
    return {}
