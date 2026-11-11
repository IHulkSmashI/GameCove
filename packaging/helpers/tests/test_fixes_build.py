"""tools/fixes/build.py: every fixes/<id>/fix.json is checked against the schema and the rules a schema can't
say (every fix has metadata, an undo, a probe and tests), and app/data/fixes.json, the README table and the
catalogue in docs/FIXES.md are generated from them and kept in step."""
import copy
import importlib.util
import json
import os
import sys

import pytest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
TOOLS = os.path.join(REPO, "tools", "fixes")


def load(name):
    full = "gamecove_fixes_" + name
    if full not in sys.modules:
        spec = importlib.util.spec_from_file_location(full, os.path.join(TOOLS, name + ".py"))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[full] = mod
        spec.loader.exec_module(mod)
    return sys.modules[full]


build = load("build")


@pytest.fixture(scope="module")
def defs():
    d, problems = build.load_all()
    assert problems == []
    return d


@pytest.fixture(scope="module")
def rows():
    return build.device_rows()


def test_every_fix_folder_is_valid(defs, rows):
    assert build.rules(defs, rows) == []
    assert set(defs) == set(build.fix_ids())
    assert len(defs) >= 20


def test_every_fix_has_metadata_undo_probe_and_tests(defs):
    for name in build.fix_ids():
        folder = os.path.join(REPO, "fixes", name)
        assert os.path.isfile(os.path.join(folder, "fix.json")), name + ": metadata"
        d = defs[name]
        assert len(d["undo"]) >= 10, name + ": says how it's undone"
        assert d["lifecycle"]["probe"]["what"], name + ": says how it's probed"
        if d["kind"] in ("root", "file", "power"):
            script = open(os.path.join(folder, "fix.sh"), encoding="utf-8").read()
            assert "gc_main" in script or "remove)" in script, name + ": undo command"
            assert "gc_main" in script or "status)" in script, name + ": probe command"
            assert os.path.isfile(os.path.join(folder, "test.sh")), name + ": tests"
        if d["kind"] in ("root", "file"):
            assert "os_fixed" in script, name + ": the probe can say the system does it"
            assert "gc_main" in script or "\nupdate)" in script, name + ": update command"
            assert build.script_revision(script) == d["revision"], name + ": revision in step with fix.sh"
            assert d["lifecycle"]["obsolete_when"] is not None and d["watch"], name + ": lifecycle rule and a watch"


def test_schema_file_agrees_with_the_real_validator(defs):
    """The small built-in validator and the jsonschema package agree (when it's installed)."""
    jsonschema = pytest.importorskip("jsonschema")
    schema = build.load_schema()
    jsonschema.Draft202012Validator.check_schema(schema)
    v = jsonschema.Draft202012Validator(schema)
    for name, d in defs.items():
        assert list(v.iter_errors(d)) == [], name
    for bad in _broken(defs["ally-controller-wakeup"]):
        assert list(v.iter_errors(bad)) != []
        assert build.validate(bad, schema) != []


def _broken(good):
    out = []

    def variant(fn):
        d = copy.deepcopy(good)
        fn(d)
        out.append(d)

    variant(lambda d: d.pop("undo"))
    variant(lambda d: d.update(level="suggested"))
    variant(lambda d: d.update(schema=2))
    variant(lambda d: d.update(surprise=1))
    variant(lambda d: d.update(revision=0))
    variant(lambda d: d.update(breaks="looks"))
    variant(lambda d: d["lifecycle"].update(obsolete_when={"kernel": "6.19"}))               # no operator
    variant(lambda d: d["lifecycle"].update(obsolete_when={"file": "/home/user/x"}))          # not a system path
    variant(lambda d: d["lifecycle"].update(obsolete_when={"file": "/usr/../etc/shadow x"}))
    variant(lambda d: d["lifecycle"].update(obsolete_when={"run": "rm -rf /"}))               # not a condition
    variant(lambda d: d["lifecycle"].update(obsolete_when={"all": []}))
    variant(lambda d: d["lifecycle"].update(obsolete_when={"tool": "curl", "version": ">=1"}))  # not a known tool
    variant(lambda d: d["watch"].append({"id": "x1", "kind": "shell", "note": "run something"}))
    variant(lambda d: d["watch"].append({"id": "x1", "kind": "url", "url": "http://plain.example/x", "note": "not https at all"}))
    variant(lambda d: d.update(withdrawn={"date": "today", "reason": "because we said so"}))
    variant(lambda d: d["changes"].append({"type": "magic", "target": "/x/y", "detail": "something vague"}))
    variant(lambda d: d["tested"].append({"device": "msi-claw-8-ex", "os": "Bazzite"}))        # no date
    return out


def test_schema_rejects_broken_definitions(defs):
    schema = build.load_schema()
    assert build.validate(defs["ally-controller-wakeup"], schema) == []
    for bad in _broken(defs["ally-controller-wakeup"]):
        assert build.validate(bad, schema) != [], bad


def test_rules_a_schema_cannot_say(defs, rows):
    def problems(name, fn):
        d = copy.deepcopy(defs)
        fn(d[name])
        return "\n".join(build.rules(d, rows))

    assert "Recommended means preselected" in problems("ally-controller-wakeup", lambda d: d.update(level="optional"))
    assert "Recommended means preselected" in problems("claw-wifi-d3cold", lambda d: d.update(level="recommended"))
    assert "only for must-fix" in problems("ally-controller-wakeup", lambda d: d.update(must_fix=False, breaks=""))
    assert "can't be Recommended" in problems("ally-controller-wakeup", lambda d: d.update(risk="high"))
    assert "must_fix and breaks go together" in problems("quiet", lambda d: d.update(breaks="sleep"))
    assert "revision 2, but fix.sh says REVISION=1" in problems("ally-controller-wakeup", lambda d: d.update(revision=2))
    assert "needs obsolete_when" in problems("ally-controller-wakeup", lambda d: d["lifecycle"].update(obsolete_when=None))
    assert "needs at least one watch" in problems("ally-controller-wakeup", lambda d: d.update(watch=[]))
    assert "isn't in devices.json" in problems("claw8ex-vrr", lambda d: d["tested"].append({"device": "nope", "date": "2026-11-09", "os": "Bazzite"}))
    assert "used twice" in problems("claw8ex-vrr", lambda d: d["watch"].append(dict(d["watch"][0])))
    assert "needs 'number'" in problems("onexfly-touch", lambda d: d["watch"][0].pop("number"))
    assert "can record a result" in problems("onexfly-touch", lambda d: d["watch"][0].update(records={"os": "bazzite", "present": "fixed"}))
    assert "pick no handheld" in problems("onexfly-touch", lambda d: d.update(auto="platform:nothing-like-this", optional=[]))
    assert "advice is text" in problems("advice-gpd-sleep", lambda d: d.update(default="on"))
    assert "isn't the folder name" in problems("quiet", lambda d: d.update(id="quiet2"))


def test_a_fix_folder_without_a_definition_fails(tmp_path):
    (tmp_path / "newfix").mkdir()
    (tmp_path / "newfix" / "fix.sh").write_text("#!/bin/sh\n")
    (tmp_path / "lib").mkdir()
    d, problems = build.load_all(str(tmp_path))
    assert d == {} and problems == ["fixes/newfix: no fix.json (every fix needs its definition)"]


def test_generated_files_are_current(defs, rows):
    for path, text in build.generated(defs, rows).items():
        assert open(path, encoding="utf-8").read() == text, "%s is stale: run python3 tools/fixes/build.py" % os.path.relpath(path, REPO)


def test_built_catalogue_keeps_what_the_app_and_installer_read(defs, rows):
    doc = build.build_doc(defs, rows)
    assert doc["schema"] == 1 and doc["version"] == 1
    by = {f["id"]: f for f in doc["fixes"]}
    assert [f["id"] for f in doc["fixes"]][:3] == ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro"], "the page's order"
    assert by["quiet"]["devices"] == "*"
    ax = by["ax210-d3cold"]["devices"]
    assert ax["others"] == "optional" and {d["id"] for d in ax["listed"]} >= {"gpd-win-5", "ayaneo-2"}
    claw = {d["id"]: d for d in by["claw8ex-vrr"]["devices"]}
    assert claw["msi-claw-8-ex"]["level"] == "recommended" and claw["msi-claw-a1m"]["level"] == "optional"
    assert claw["msi-claw-8-ex"]["match"], "DMI ids of the model"
    assert "msi-claw-a8" not in claw, "excluded models stay out"
    for f in doc["fixes"]:
        assert "schema" not in f
        for k in ("id", "title", "line", "kind", "password", "sources", "auto", "optional", "page", "level", "lifecycle"):
            assert k in f, (f["id"], k)


def test_readme_table_lists_only_must_fix_fixes(defs, rows):
    table = build.readme_table(defs, rows)
    assert "**Sticks don't wake it**" in table and "**Recommended**: " in table and "**Optional**: " in table
    assert "Keep GameCove off the game's cores" not in table, "not a must-fix: out of the README table"
    assert "Fan presets" not in table and "Power button doesn't sleep" not in table
    assert "MSI Claw 8 EX AI+ (Bazzite, 2026-11-09)" in table, "tested on hardware, with the date"
    assert "Suggested" not in table and "Extras" not in table
    readme = open(build.README, encoding="utf-8").read()
    assert readme.index("## Fixes for your handheld") < readme.index("## Contents"), "near the top, before the contents"
    assert "docs/FIXES.md" in readme and "Recommended" in readme and "Tested on hardware" in readme
    doc = open(build.DOC, encoding="utf-8").read()
    for name in defs:
        assert "### %s\n" % name in doc, name + " is in docs/FIXES.md"


def test_validator_refuses_schema_keywords_it_does_not_know():
    with pytest.raises(ValueError):
        build.validate({}, {"type": "object", "patternProperties": {}})


def test_readme_table_needs_no_hidden_comment():
    """The README carries no hidden comments (packaging/tests/release.sh): the table's header is its marker."""
    text = "intro\n\n%s\n| --- |\n| old row |\n\nafter\n" % build.README_HEAD
    out = build.splice_table(text, "%s\n| --- |\n| new row |\n" % build.README_HEAD)
    assert "| new row |" in out and "| old row |" not in out
    assert out.startswith("intro\n\n") and out.endswith("\n\nafter\n")
    with open(build.README, encoding="utf-8") as f:
        readme = f.read()
    assert not any(line.startswith("<!--") for line in readme.split("\n"))
    assert readme.split("\n").count(build.README_HEAD) == 1
