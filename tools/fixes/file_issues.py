#!/usr/bin/env python3
"""Opens or updates the fix-audit issues the nightly audit asked for (the workflow's issues job).

    python3 -I tools/fixes/file_issues.py issues.json [more issues.json ...] [--dry-run]

One open issue per fix (title "Fix audit: <id>", label fix-audit): when one is open, the new
change is added as a comment; otherwise it is created. The same for the summary and the weekly
dead-links report. Titles come from the audit's own fixed words and the fix id; bodies are passed
to gh as files, never through a shell. Needs gh and GH_TOKEN with issues: write. Standard
library only.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

LABEL = "fix-audit"
TITLE = re.compile(r"Fix audit(: [a-z0-9][a-z0-9-]{1,63}| summary|: dead links)")
MAX_BODY = 60000


def entries(paths):
    out = []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
        for e in list(doc.get("fixes", [])) + ([doc["summary"]] if doc.get("summary") else []):
            title, body = str(e.get("title", "")), str(e.get("body", ""))
            if not TITLE.fullmatch(title):
                raise SystemExit("refusing an issue title the audit doesn't make: %r" % title[:80])
            out.append((title, body[:MAX_BODY]))
    return out


def gh(args, dry):
    if dry:
        print("gh " + " ".join(args))
        return "[]"
    return subprocess.run(["gh"] + args, check=True, capture_output=True, text=True).stdout


def main(argv):
    dry = "--dry-run" in argv
    todo = entries([a for a in argv if a != "--dry-run"])
    if not todo:
        print("nothing to report")
        return 0
    gh(["label", "create", LABEL, "--force", "--color", "5319e7",
        "--description", "The nightly fix audit saw a change upstream (docs/FIXES.md)"], dry)
    listed = json.loads(gh(["issue", "list", "--label", LABEL, "--state", "open", "--limit", "200", "--json", "number,title"], dry) or "[]")
    open_by_title = {str(i.get("title", "")): int(i["number"]) for i in listed if isinstance(i, dict) and "number" in i}
    for title, body in todo:
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as f:
            f.write(body)
        try:
            if title in open_by_title:
                gh(["issue", "comment", str(open_by_title[title]), "--body-file", f.name], dry)
                print("updated #%d: %s" % (open_by_title[title], title))
            else:
                gh(["issue", "create", "--title", title, "--label", LABEL, "--body-file", f.name], dry)
                print("opened: %s" % title)
        finally:
            os.unlink(f.name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
