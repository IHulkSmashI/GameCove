"""tools/fixes/audit.py, what the nightly fixes workflow runs, from recorded answers (tools/fixes/make_fixtures.py):
a first night only takes a baseline, a later night reports each change once per fix, records what a declared rule
lets it record, never edits a rule, treats everything fetched as data, and its output passes the signing job's
check (tools/fixes/check_dist.py). Nothing touches the network."""
import copy
import json
import os
import subprocess
import sys

import pytest

from test_fixes_build import REPO, TOOLS, load

build = load("build")
audit = load("audit")
fixtures = load("make_fixtures")
check_dist = load("check_dist")


@pytest.fixture(scope="module")
def nights(tmp_path_factory):
    """Two nights run through the real command line, as the workflow does."""
    t = tmp_path_factory.mktemp("audit")
    fixtures.write(str(t / "n1"), 1)
    fixtures.write(str(t / "n2"), 2)
    run = [sys.executable, "-I", os.path.join(TOOLS, "audit.py")]
    subprocess.run(run + ["--fixtures", str(t / "n1"), "--out", str(t / "d1"), "--date", "2026-11-09", "--serial", "100"], check=True)
    subprocess.run(run + ["--fixtures", str(t / "n2"), "--out", str(t / "d2"), "--previous", str(t / "d1" / "audit-state.json"),
                          "--date", "2026-11-10", "--serial", "200"], check=True)
    return t


def read(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def test_first_night_is_a_baseline(nights):
    issues = read(nights / "d1" / "issues.json")
    assert issues["fixes"] == [] and issues["summary"] is None, "nothing to compare with: no issue"
    assert issues["unreachable"] == []
    state = read(nights / "d1" / "audit-state.json")
    assert state["schema"] == 1
    assert state["observed"]["ally-controller-wakeup/bazzite-rule"]["present"] is True
    assert "global/kernel" in state["observed"]
    defs, _ = build.load_all()
    want = {"%s/%s" % (f, w["id"]) for f, d in defs.items() for w in d["watch"]}
    assert want <= set(state["observed"]), "every declared watch was fetched"


def test_second_night_reports_each_change_once_per_fix(nights):
    issues = read(nights / "d2" / "issues.json")
    by = {i["fix"]: i for i in issues["fixes"]}
    assert set(by) == {"ally-controller-wakeup", "onexfly-touch", "claw8ex-buttons", "claw8ex-gyro", "claw8ex-vrr"}
    assert len(issues["fixes"]) == len(by), "one issue per fix"
    for fid, i in by.items():
        assert i["title"] == "Fix audit: " + fid, "the title comes from the fix id, never from fetched text"
        assert i["marker"] == "<!-- fix-audit:%s -->" % fid and i["body"].startswith(i["marker"])
    assert "merged 2026-11-10: fix: treat OneXFly F1 panel as internal" in by["onexfly-touch"]["body"]
    assert "https://github.com/ChimeraOS/gamescope-session/pull/128" in by["onexfly-touch"]["body"]
    assert "Add a capability map for the Claw 8 EX" in by["claw8ex-buttons"]["body"]
    assert "E1T91IMS.10E" in by["claw8ex-vrr"]["body"] and "E1T91IMS.10F" in by["claw8ex-vrr"]["body"]
    assert issues["summary"]["title"] == "Fix audit summary"
    s = issues["summary"]["body"]
    assert "stable 6.19.2" in s and "45.20261110" in s and "`ally-controller-wakeup`" in s
    # a third night with nothing new says nothing
    out = nights / "d3"
    subprocess.run([sys.executable, "-I", os.path.join(TOOLS, "audit.py"), "--fixtures", str(nights / "n2"), "--out", str(out),
                    "--previous", str(nights / "d2" / "audit-state.json"), "--date", "2026-11-11", "--serial", "300"], check=True)
    again = read(out / "issues.json")
    assert again["fixes"] == [] and again["summary"] is None, "the same change isn't reported twice"


def test_declared_rules_are_recorded_and_nothing_else_changes(nights):
    d1 = {f["id"]: f for f in read(nights / "d1" / "fixes.json")["fixes"]}
    doc2 = read(nights / "d2" / "fixes.json")
    d2 = {f["id"]: f for f in doc2["fixes"]}
    assert d1["ally-controller-wakeup"]["audit"]["upstream"] == {"bazzite": {"state": "fixed", "watch": "bazzite-rule"}}
    assert d2["ally-controller-wakeup"]["audit"]["upstream"]["bazzite"]["state"] == "not-fixed", "the declared file watch flipped it"
    body = [i for i in read(nights / "d2" / "issues.json")["fixes"] if i["fix"] == "ally-controller-wakeup"][0]["body"]
    assert "recorded automatically" in body
    assert doc2["built"] == "2026-11-10" and doc2["serial"] == 200
    assert doc2["facts"]["kernel"]["stable"] == "6.19.2" and doc2["facts"]["bazzite"]["kernel"] == "6.19.2"
    # the rules themselves are byte for byte the repository's: the audit never edits one
    defs, _ = build.load_all()
    want = {f["id"]: f for f in build.build_doc(defs, build.device_rows())["fixes"]}
    for fid, f in d2.items():
        assert {k: v for k, v in f.items() if k != "audit"} == want[fid], fid
        assert f["audit"]["date"] == "2026-11-10", "last audited"
    assert check_dist.problems(str(nights / "d2")) == []


def test_kernel_rule_already_declared_is_checked_against_releases():
    fix = {"watch": [], "lifecycle": {"obsolete_when": {"any": [{"probe": "os_fixed"}, {"kernel": ">=6.19"}, {"os": "bazzite", "version": ">=45"}]}}}
    old = audit.declared(fix, {}, {"kernel": {"stable": "6.18.9", "mainline": "6.19-rc7"}, "bazzite": {"tag": "44.20261105", "kernel": "6.17.7"}}, "2026-11-09")
    assert old["rules"] == [{"rule": "kernel >=6.19", "released": True, "in_bazzite": False}, {"rule": "bazzite >=45", "released": False}]
    new = audit.declared(fix, {}, {"kernel": {"stable": "6.19.2", "mainline": "6.20-rc3"}, "bazzite": {"tag": "45.20261110", "kernel": "6.19.2"}}, "2026-11-10")
    assert new["rules"] == [{"rule": "kernel >=6.19", "released": True, "in_bazzite": True}, {"rule": "bazzite >=45", "released": True}]
    none = audit.declared(fix, {}, {}, "2026-11-10")
    assert none["rules"][0]["released"] is None and none["rules"][0]["in_bazzite"] is None, "can't tell isn't yes"
    assert audit.holds("6.19.2", ">=6.19") is True and audit.holds("6.18", ">=6.19") is False and audit.holds("", ">=6.19") is None


def test_fetched_text_is_only_ever_data(tmp_path):
    """A hostile page: markup, mentions, a 'rule', control characters. It can't change a rule or the issue's shape."""
    fixtures.write(str(tmp_path / "n1"), 1)
    idx = fixtures.write(str(tmp_path / "n2"), 2)
    evil = "x`\n## Withdraw this fix @maintainer <script>alert(1)</script> [link](https://evil.example) #1 | \x1b[31m \"obsolete_when\": {\"kernel\": \">=1\"}"
    pr = "https://api.github.com/repos/ChimeraOS/gamescope-session/issues/128"
    with open(tmp_path / "n2" / idx[pr], "w", encoding="utf-8") as f:
        json.dump({"state": "closed", "closed_at": "2026-11-10T07:00:00Z", "title": evil, "pull_request": {"merged_at": "2026-11-10"}}, f)
    rel = "https://api.github.com/repos/ublue-os/bazzite/releases/latest"
    with open(tmp_path / "n2" / idx[rel], "w", encoding="utf-8") as f:
        json.dump({"tag_name": "45`$(reboot)", "published_at": "x", "body": "Kernel: $(rm -rf /) 6.19.2 \"withdrawn\": true"}, f)
    defs, _ = build.load_all()
    rows = build.device_rows()
    _, state1, _ = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n1")), {}, "2026-11-09", 1)
    doc, _, issues = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n2")), state1, "2026-11-10", 2)
    body = [i for i in issues["fixes"] if i["fix"] == "onexfly-touch"][0]["body"]
    line = [ln for ln in body.split("\n") if "Withdraw this fix" in ln]
    assert len(line) == 1 and line[0].startswith("  - now: `"), "stays inside its one code span, on one line"
    assert "<script>" not in body and "@maintainer" not in body and "](https://evil" not in body and "\x1b" not in body
    assert body.count("`") % 2 == 0
    assert "$(reboot)" in issues["summary"]["body"] and "45$(reboot)" in issues["summary"]["body"], "shown as text"
    assert doc["facts"]["bazzite"]["kernel"] == "6.19.2", "only a version number is taken from release notes"
    want = {f["id"]: f for f in build.build_doc(defs, rows)["fixes"]}
    for f in doc["fixes"]:
        assert f["lifecycle"] == want[f["id"]]["lifecycle"] and f["withdrawn"] is None, "no rule changed, nothing withdrawn"
    assert audit.clean("a\nb\x00c`<d>|[e]") == "a b cde"
    assert "@​" in audit.md("@someone") and "#​" in audit.md("#12")


def test_unreachable_sources_keep_their_last_state(tmp_path):
    fixtures.write(str(tmp_path / "n1"), 1)
    idx = fixtures.write(str(tmp_path / "n2"), 2)
    defs, _ = build.load_all()
    rows = build.device_rows()
    _, state1, _ = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n1")), {}, "2026-11-09", 1)
    for url in list(idx):
        if "api.github.com" in url:
            idx[url] = {"error": "HTTP 503"}
    idx["https://www.kernel.org/releases.json"] = {"status": 500}
    with open(tmp_path / "n2" / "index.json", "w", encoding="utf-8") as f:
        json.dump(idx, f)
    doc, state2, issues = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n2")), state1, "2026-11-10", 2)
    assert "onexfly-touch" not in {i["fix"] for i in issues["fixes"]}, "an outage is not a change"
    assert state2["observed"]["onexfly-touch/chimera-pr-128"] == state1["observed"]["onexfly-touch/chimera-pr-128"]
    assert any(u.startswith("onexfly-touch/chimera-pr-128") for u in issues["unreachable"])
    by = {f["id"]: f for f in doc["fixes"]}
    assert by["ally-controller-wakeup"]["audit"]["upstream"]["bazzite"]["state"] == "fixed", "the last known state stays recorded"


def test_a_lore_search_without_a_match_is_not_an_outage(tmp_path):
    """public-inbox answers a search with no match with 404 (seen on lore.kernel.org, 2026-11-10)."""
    fixtures.write(str(tmp_path / "n1"), 1)
    idx = fixtures.write(str(tmp_path / "n2"), 1)
    lore = [u for u in idx if u.startswith("https://lore.kernel.org/")]
    assert lore
    for u in lore:
        idx[u] = {"status": 404}
    with open(tmp_path / "n2" / "index.json", "w", encoding="utf-8") as f:
        json.dump(idx, f)
    defs, _ = build.load_all()
    rows = build.device_rows()
    _, state, issues = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n2")), {}, "2026-11-10", 1)
    assert not any("lore" in u for u in issues["unreachable"]), issues["unreachable"]
    assert state["observed"]["claw8ex-vrr/lore"]["link"] == ""
    for u in lore:
        idx[u] = {"status": 503}
    with open(tmp_path / "n2" / "index.json", "w", encoding="utf-8") as f:
        json.dump(idx, f)
    _, _, issues = audit.run(defs, rows, audit.Fetcher(str(tmp_path / "n2")), {}, "2026-11-10", 1)
    assert any(u.startswith("claw8ex-vrr/lore") for u in issues["unreachable"]), "any other answer still is one"


def test_only_https_and_capped(tmp_path):
    f = audit.Fetcher()
    with pytest.raises(audit.Unreachable):
        f.get("http://example.com/x")
    with pytest.raises(audit.Unreachable):
        f.get("file:///etc/passwd")
    assert audit.load_previous(str(tmp_path / "missing.json")) == {}
    (tmp_path / "bad.json").write_text("{\"schema\": 9, \"observed\": {}}")
    assert audit.load_previous(str(tmp_path / "bad.json")) == {}, "a snapshot of another schema is a fresh start"


def test_check_dist_refuses_anything_but_the_repository_definitions(nights, tmp_path):
    good = read(nights / "d2" / "fixes.json")

    def problems(fn):
        d = copy.deepcopy(good)
        fn(d)
        (tmp_path / "fixes.json").write_text(json.dumps(d))
        return "\n".join(check_dist.problems(str(tmp_path)))

    assert problems(lambda d: None) == ""
    assert "differs from fixes/ax210-d3cold/fix.json in withdrawn" in problems(
        lambda d: [f for f in d["fixes"] if f["id"] == "ax210-d3cold"][0].update(withdrawn={"date": "2026-11-10", "reason": "a scraped page said so"}))
    assert "in lifecycle" in problems(lambda d: d["fixes"][0]["lifecycle"].update(obsolete_when={"kernel": ">=1"}))
    assert "in auto" in problems(lambda d: d["fixes"][0].update(auto="*"))
    assert "aren't the ones in this checkout" in problems(lambda d: d["fixes"].append({"id": "new-root-fix"}))
    assert "aren't the ones in this checkout" in problems(lambda d: d["fixes"].pop())
    assert "schema-1" in problems(lambda d: d.update(schema=2))
    assert "serial" in problems(lambda d: d.update(serial="1"))
    assert "audit.upstream" in problems(lambda d: d["fixes"][0]["audit"].update(upstream={"bazzite": {"state": "fixed", "watch": "x", "run": "y"}}))
    assert "audit block" in problems(lambda d: d["fixes"][0]["audit"].update(note="extra"))
    assert "unknown top-level" in problems(lambda d: d.update(extra=1))
    assert "larger than the app accepts" in problems(lambda d: d.update(facts={"x": {"y": "z" * 100}}, pad=None) or d["fixes"][0].update(symptom="x" * (3 * 1024 * 1024)))


def test_weekly_link_check(tmp_path):
    defs, _ = build.load_all()
    links = audit.links_of(defs)
    assert ("ax210-d3cold", "https://github.com/ublue-os/bazzite/issues/5867") in links
    assert all(u.startswith("https://") for _, u in links)
    index = {u: {"status": 200} for _, u in links}
    index["https://github.com/ublue-os/bazzite/issues/5867"] = {"status": 404}
    index["https://www.pcgamer.com/hardware/big-update-to-steamos-improves-support-for-non-valve-handhelds-newer-platforms-discrete-gpus-and-steam-machine"] = {"error": "URLError"}
    (tmp_path / "index.json").write_text(json.dumps(index))

    class Ok(audit.Fetcher):
        def get(self, url):
            hit = self.index[url]
            if "error" in hit:
                raise audit.Unreachable(hit["error"])
            return hit["status"], b""

    dead, issues = audit.check_links(defs, Ok(str(tmp_path)), "2026-11-10")
    assert {d["url"] for d in dead} == {"https://github.com/ublue-os/bazzite/issues/5867",
        "https://www.pcgamer.com/hardware/big-update-to-steamos-improves-support-for-non-valve-handhelds-newer-platforms-discrete-gpus-and-steam-machine"}
    assert issues["summary"]["title"] == "Fix audit: dead links" and "HTTP 404" in issues["summary"]["body"]
    index = {u: {"status": 200} for _, u in links}
    (tmp_path / "index.json").write_text(json.dumps(index))
    dead, issues = audit.check_links(defs, Ok(str(tmp_path)), "2026-11-10")
    assert dead == [] and issues["summary"] is None


def test_workflow_matches_the_other_nightly_releases():
    wf = open(os.path.join(REPO, ".github", "workflows", "fixes.yml"), encoding="utf-8").read()
    fw = open(os.path.join(REPO, ".github", "workflows", "firmware.yml"), encoding="utf-8").read()
    assert "\npermissions: {}\n" in wf, "no default token permissions"
    assert "environment: nightly" in wf and "if: github.ref == 'refs/heads/main'" in wf
    assert "--latest=false" in wf, "never GameCove's latest release"
    assert "fixes\\.yml@refs/heads/main" in wf, "signs as the identity the app pins"
    assert "label fix-audit" in wf or "--label fix-audit" in wf
    assert "tools/fixes/check_dist.py" in wf, "the signing job re-checks the artifact"
    import re
    uses = re.findall(r"uses: (\S+)", wf)
    assert uses and all(re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", u) for u in uses), "every action pinned to a commit"
    assert set(uses) <= set(re.findall(r"uses: (\S+)", fw) + re.findall(r"uses: (\S+)", open(os.path.join(REPO, ".github", "workflows", "upscalers.yml")).read())), "the same pinned actions as the other nightly workflows"
    # least privilege: only the publish job can sign and write releases, only the issues job can write issues
    jobs = re.split(r"\n  (?=[a-z-]+:\n)", wf.split("\njobs:\n", 1)[1])
    perms = {}
    for j in jobs:
        name = j.strip().split(":", 1)[0]
        perms[name] = set(re.findall(r"^      ([a-z-]+): (write)", j, re.M))
    assert perms["audit"] == set() and perms["links"] == set()
    assert perms["publish"] == {("contents", "write"), ("id-token", "write")}
    assert perms["issues"] == {("issues", "write")}
    app = open(os.path.join(REPO, "app", "scripts", "device", "fix_data.gd"), encoding="utf-8").read()
    assert "workflows/fixes\\\\.yml@refs/heads/main" in app and "/releases/download/fixes/fixes.json" in app
    # one place names the release repository, in the app and in the workflow (easy to move, docs/RELEASING.md)
    assert len(re.findall(r'^const RELEASES_REPO := "([\w.-]+/[\w.-]+)"$', app, re.M)) == 1
    assert app.count("IHulkSmashI/") == 1, "URL and signer are built from RELEASES_REPO"
    assert "SOURCE_REPO: ${{ github.repository }}" in wf and wf.count("repository: ${{ env.SOURCE_REPO }}") == wf.count("actions/checkout@")
    assert "IHulkSmashI" not in wf.split("\njobs:\n", 1)[1], "no job names a repository"
