"""The CI and release gates themselves (review of 56f5255): the e2e runner must not read a broken run as a pass,
and the release gate must look at the right CI run."""
import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[3]
RUN_PY = REPO / "app" / "tests" / "e2e" / "run.py"
CHECK = REPO / "tools" / "ci" / "check-ci-passed.sh"
WORKFLOWS = REPO / ".github" / "workflows"


def _runner():
    spec = importlib.util.spec_from_file_location("e2e_run", RUN_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_a_setup_error_is_a_failure_not_zero_of_zero():
    r = _runner().judge({"error": "no devices.json row"}, 1, "ally/main", False)
    assert r["failed"] >= 1 and "setup failed" in r["failures"][0]


def test_a_run_with_no_tests_fails():
    r = _runner().judge({"passed": 0, "failed": 0, "failures": []}, 0, "ally/main", False)
    assert r["failed"] == 1 and "ran no tests" in r["failures"][0]


def test_a_run_with_no_match_is_fine_when_a_test_filter_was_given():
    r = _runner().judge({"passed": 0, "failed": 0, "failures": []}, 0, "ally/main", True)
    assert r["failed"] == 0


def test_exit_one_with_nothing_reported_fails():
    r = _runner().judge({"passed": 3, "failed": 0, "failures": []}, 1, "ally/main", False)
    assert r["failed"] == 1


def test_a_normal_run_passes_and_a_pending_only_run_is_not_empty():
    j = _runner().judge
    assert j({"passed": 5, "failed": 0, "failures": []}, 0, "x", False)["failed"] == 0
    assert j({"passed": 0, "failed": 0, "failures": [], "skipped": 2}, 0, "x", False)["failed"] == 0


def _gate(tmp_path, runs, sha="abc"):
    f = tmp_path / "runs.json"
    f.write_text(json.dumps({"workflow_runs": runs}))
    env = dict(os.environ, CI_RUNS_JSON=str(f))
    return subprocess.run(["sh", str(CHECK), sha], env=env, capture_output=True, text=True, check=False)


def _run(event, conclusion, created, sha="abc"):
    return {"head_sha": sha, "event": event, "conclusion": conclusion, "created_at": created}


@pytest.mark.skipif(shutil.which("jq") is None, reason="jq is on the CI runners")
class TestReleaseGate:
    def test_green_push_run_passes(self, tmp_path):
        assert _gate(tmp_path, [_run("push", "success", "2026-11-10T10:00:00Z")]).returncode == 0

    def test_red_newest_run_blocks(self, tmp_path):
        r = _gate(tmp_path, [_run("push", "success", "2026-11-10T10:00:00Z"), _run("push", "failure", "2026-11-10T11:00:00Z")])
        assert r.returncode == 1 and "failure" in r.stderr

    def test_a_newer_green_pull_request_run_does_not_clear_a_red_push_run(self, tmp_path):
        r = _gate(tmp_path, [_run("push", "failure", "2026-11-10T10:00:00Z"), _run("pull_request", "success", "2026-11-10T12:00:00Z")])
        assert r.returncode == 1

    def test_a_newer_red_pull_request_run_does_not_block_a_green_push_run(self, tmp_path):
        r = _gate(tmp_path, [_run("push", "success", "2026-11-10T10:00:00Z"), _run("pull_request", "failure", "2026-11-10T12:00:00Z")])
        assert r.returncode == 0

    def test_only_pull_request_runs_is_no_ci(self, tmp_path):
        r = _gate(tmp_path, [_run("pull_request", "success", "2026-11-10T10:00:00Z")])
        assert r.returncode == 1 and "none" in r.stderr

    def test_another_commits_run_does_not_count(self, tmp_path):
        assert _gate(tmp_path, [_run("push", "success", "2026-11-10T10:00:00Z", sha="other")]).returncode == 1

    def test_no_runs_blocks(self, tmp_path):
        assert _gate(tmp_path, []).returncode == 1


def test_the_tag_is_made_only_after_the_gate_and_signing_uses_the_same_gate():
    rel = (WORKFLOWS / "release.yml").read_text()
    tag_job = rel[rel.index("\n  tag:"):rel.index("\n  cabinet:")]
    assert "check-ci-passed.sh" in tag_job
    assert tag_job.index("check-ci-passed.sh") < tag_job.index("git/refs")
    gate_job = rel[rel.index("\n  ci-passed:"):rel.index("\n  release:")]
    assert "check-ci-passed.sh" in gate_job


def test_no_step_relies_on_a_negated_grep_that_cannot_fail():
    for name in ("ci.yml", "release.yml"):
        for n, line in enumerate((WORKFLOWS / name).read_text().splitlines(), 1):
            assert not line.strip().startswith("! grep"), f"{name}:{n}: a `! grep` does not stop a bash -e step: {line.strip()}"
