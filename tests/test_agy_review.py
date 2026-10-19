"""Exercise the production wrapper across a deterministic AGY process boundary."""

# unittest cleanup and explicit process reaping own fixture resources.
# pylint: disable=consider-using-with
# Real process fixtures intentionally execute trusted argument arrays and load central scripts.
# ruff: noqa: E402, INP001, S603, S607, PT027

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

sys.path.insert(0, str(ROOT / "scripts"))
import agy_review
import agy_review_report

FIXTURE = r"""#!/usr/bin/env python3
import json, os, re, sys, uuid, time
from pathlib import Path
scenario=os.environ.get('SCENARIO', 'clean')
if sys.argv[1:] == ['models']:
    if scenario == 'catalog-failure': print('authentication unavailable token=fixture-catalog-secret',file=sys.stderr); sys.exit(1)
    print('gemini-3.8-flash-high\tFlash\ngemini-4-argon-high\tArgon High\ngemini-5-pro-preview-high\tPreview')
    sys.exit(0)
if scenario == 'hang':
    child=os.fork()
    if child == 0: time.sleep(60)
    time.sleep(60)
if scenario == 'pipe':
    child=os.fork()
    if child == 0: time.sleep(60); sys.exit(0)
prompt=sys.argv[sys.argv.index('--print')+1]
receipt=re.search(r'exact target receipt is ([a-f0-9]{64})', prompt).group(1)
files=json.loads(re.search(r'Required coverage paths: (.+)', prompt).group(1))
cid=str(uuid.uuid4()) if scenario != 'same-session' else 'same-session'
model=sys.argv[sys.argv.index('--model')+1]
if scenario == 'wrong-model': model='gemini-3.8-flash-high'
print(json.dumps({'event':'init','conversation_id':cid,'init':{'model':model}}))
if scenario == 'malformed': print('bad-json'); sys.exit(0)
if scenario == 'denied': print(json.dumps({'event':'tool_result','error':'permission denied'}))
if scenario == 'denial-in-source': print(json.dumps({'event':'step_update','step_update':{'state':'DONE','tool_info':{'output':'fixture source mentions permission denied'}}}))
if scenario == 'unavailable':
    if model == 'gemini-4-argon-high': print('model unavailable',file=sys.stderr); sys.exit(1)
if scenario == 'transient':
    state=Path(os.environ['STATE'])
    if not state.exists(): state.write_text('retry'); print('network timeout',file=sys.stderr); sys.exit(1)
if scenario == 'mutate': Path(os.environ['MUTATE']).write_text('changed during review')
if scenario == 'secret':
    print('{"token":"fixture-secret-value"} password: fixture-password user@example.org 192.0.2.10 agy-oauth-file-base64:c2VjcmV0',file=sys.stderr); sys.exit(1)
result={'verdict':'approve','summary':'clean','findings':[],'next_steps':[], 'review_target_receipt':receipt, 'coverage':{'status':'complete','read_files':files,'denied_reads':[]}}
if scenario == 'verdict': result['verdict']='needs-attention'
if scenario == 'incomplete': result['coverage']['read_files']=[]
if scenario == 'wrong-receipt': result['review_target_receipt']='0'*64
if scenario == 'high': result['findings']=[{'severity':'high','title':'Defect','body':'Evidence','file':'doc.md','line_start':1,'line_end':1,'confidence':1,'recommendation':'Repair'}]
print(json.dumps({'event':'result','result':{'conversation_id':cid,'status':'SUCCESS','structured_output':result}}))
"""


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.repo = self.home / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "doc.md").write_text("Initial document")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")
        self.base = self.git("rev-parse", "HEAD").strip()
        (self.repo / "doc.md").write_text("Changed document")
        self.git("commit", "-qam", "change")
        self.bin = self.home / "bin"
        self.bin.mkdir()
        (self.bin / "agy").write_text(FIXTURE)
        (self.bin / "agy").chmod(0o755)
        self.report = self.home / "report.json"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, text=True)

    def run_review(self, scenario="clean", document=False, cwd=None):
        env = {
            **os.environ,
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "SCENARIO": scenario,
            "STATE": str(self.home / "state"),
            "MUTATE": str(self.repo / "doc.md"),
            "AGY_REVIEW_SKIP_LOCAL_PII": "1",
            "AGY_REVIEW_REPORT_FILE": str(self.report),
            "AGY_REVIEW_DIAGNOSTIC_DIR": str(self.home / "diagnostics"),
        }
        args = (
            ["document", "--kind", "plan", "--file", "doc.md"]
            if document
            else ["code", "--base", self.base]
        )
        return subprocess.run(
            ["bash", str(ROOT / "scripts/agy-review.sh"), *args],
            cwd=cwd or self.repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=35,
        )

    def test_clean_real_wrapper(self):
        result = self.run_review()
        assert result.returncode == 0, result.stderr
        report = json.loads(self.report.read_text())
        assert report["report_version"] == 2
        assert (
            report["sessions"]["reviewer"]["conversation_id"]
            != report["sessions"]["verifier"]["conversation_id"]
        )
        assert report["model"]["actual_model"] == "gemini-4-argon-high"

    def test_fail_closed(self):
        for scenario in (
            "verdict",
            "high",
            "incomplete",
            "denied",
            "wrong-model",
            "wrong-receipt",
            "same-session",
            "malformed",
        ):
            with self.subTest(scenario=scenario):
                result = self.run_review(scenario)
                assert result.returncode != 0, result.stdout

    def test_document_mutation(self):
        assert self.run_review("mutate", document=True).returncode != 0

    def test_external_symlink(self):
        (self.repo / "doc.md").unlink()
        outside = self.home / "outside"
        outside.write_text("external")
        (self.repo / "doc.md").symlink_to(outside)
        assert self.run_review(document=True).returncode != 0

    def test_subdirectory_invocation(self):
        sub = self.repo / "sub"
        sub.mkdir()
        assert self.run_review(cwd=sub).returncode == 0

    def test_advanced_base(self):
        head = self.git("rev-parse", "HEAD").strip()
        self.git("checkout", "-qb", "advanced", self.base)
        (self.repo / "base.md").write_text("advanced base")
        self.git("add", ".")
        self.git("commit", "-qm", "advance")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.git("checkout", "-q", "--detach", head)
        result = self.run_review()
        assert result.returncode == 0, result.stderr
        report = json.loads(self.report.read_text())
        assert report["target"]["base_sha"] == self.base
        assert report["target"]["merge_base_sha"] != self.base

    def test_transient_retry(self):
        result = self.run_review("transient")
        assert result.returncode == 0, result.stderr
        assert len(json.loads(self.report.read_text())["attempt_metadata"]) == 3

    def test_inherited_pipe_exits(self):
        assert self.run_review("pipe").returncode == 0

    def test_external_attempt_deadline(self):
        work = self.home / "bounded"
        work.mkdir()
        rc, _, _, _ = agy_review.bounded(
            ["python3", "-c", "import os,time; os.fork(); time.sleep(60)"],
            self.repo,
            work,
            "hung",
            0.2,
        )
        assert rc == 124

    def test_report_consumer(self):
        result = self.run_review()
        assert result.returncode == 0, result.stderr
        report = json.loads(self.report.read_text())
        report["receipt"] = {
            "repository": "fixture",
            "base_sha": self.base,
            "head_sha": report["target"]["head_sha"],
            "workflow_sha": "workflow",
            "tools_sha": "tools",
            "agy_version": "1.4.2",
            "tool_status": 0,
        }
        assert agy_review_report.validate(
            report,
            repository="fixture",
            base=self.base,
            head=report["target"]["head_sha"],
            workflow="workflow",
            version="1.4.2",
            tools="tools",
            merge_base=report["target"]["merge_base_sha"],
        )
        report["verifier"]["verdict"] = "needs-attention"
        assert not agy_review_report.gate(report)
        report["verifier"]["verdict"] = "approve"
        report["sessions"]["verifier"]["actual_model"] = "wrong"
        assert not agy_review_report.gate(report)

    def test_fallback_pair_restart(self):
        # Test policy resides in an isolated tool checkout; production stays unqualified.

        tools = self.home / "tools"
        shutil.copytree(ROOT / "scripts", tools)
        (tools / "agy-model-policy.json").write_text(
            json.dumps(
                {
                    "last_verified_model": "gemini-3.9-pro-high",
                    "qualification": {"identity": "fixture", "receipt": "qualified"},
                }
            )
        )
        with patch.dict(
            os.environ,
            {
                "SCENARIO": "unavailable",
                "AGY_REVIEW_SKIP_LOCAL_PII": "1",
                "AGY_REVIEW_REPORT_FILE": str(self.report),
                "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            },
        ):
            result = subprocess.run(
                ["bash", str(tools / "agy-review.sh"), "code", "--base", self.base],
                cwd=self.repo,
                text=True,
                capture_output=True,
                check=False,
                timeout=20,
            )
        assert result.returncode == 0, result.stderr
        report = json.loads(self.report.read_text())
        assert not report["model"]["latest_model_accepted"]
        assert report["model"]["actual_model"] == "gemini-3.9-pro-high"
        assert report["attempt_metadata"][-1]["pair"] == 2

    def test_catalog_failure_diagnostic(self):
        result = self.run_review("catalog-failure")
        policy = json.loads((ROOT / "scripts/agy-model-policy.json").read_text())
        if policy.get("qualification"):
            assert result.returncode == 0
            report = json.loads(self.report.read_text())
            assert report["model"]["latest_model_accepted"] is False
            assert (
                report["model"]["fallback_reason"] == "catalog-unavailable-or-ambiguous"
            )
        else:
            assert result.returncode != 0
        diagnostic = (self.home / "diagnostics/catalog.stderr.txt").read_text()
        assert "authentication unavailable" in diagnostic
        assert "fixture-catalog-secret" not in diagnostic

    def test_denial_phrase_in_source_is_not_tool_failure(self):
        assert self.run_review("denial-in-source").returncode == 0

    def test_exact_pii_base(self):
        tools = self.home / "pii-tools"
        tools.mkdir()
        shutil.copy(ROOT / "scripts/check-pii.sh", tools)
        (tools / "check_pii.py").write_text(
            "import os,sys,json; from pathlib import Path; "
            "root=Path(sys.argv[sys.argv.index('--input-dir')+1]); "
            "Path(os.environ['PII_CAPTURE']).write_text(json.dumps(sorted(p.read_text() for p in root.glob('*.path'))))"
        )
        (self.repo / "other.md").write_text("second change")
        self.git("add", ".")
        self.git("commit", "-qm", "second change")
        captured = self.home / "scan.json"
        result = subprocess.run(
            [
                "bash",
                str(tools / "check-pii.sh"),
                "--scope",
                "changed",
                "--base",
                self.base,
            ],
            cwd=self.repo,
            env={**os.environ, "PII_CAPTURE": str(captured)},
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        paths = json.loads(captured.read_text())
        assert any(p.endswith("doc.md") for p in paths), paths
        assert any(p.endswith("other.md") for p in paths), paths

    def test_overall_deadline_interrupts_nonprovider_work(self):
        source = (
            "import sys,time,signal; sys.path.insert(0,sys.argv[1]); import agy_review; "
            "signal.setitimer(signal.ITIMER_REAL,0.2); time.sleep(60)"
        )
        result = subprocess.run(
            [sys.executable, "-c", source, str(ROOT / "scripts")],
            check=False,
            timeout=5,
        )
        assert result.returncode == 124

    def test_cancellation_cleanup(self):
        work = self.home / "cancel"
        work.mkdir()
        source = (
            "import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); "
            "import agy_review; agy_review.bounded(['python3','-c',"
            "'import os,time; os.fork(); time.sleep(60)'],Path(sys.argv[2]),Path(sys.argv[2]),'cancel',60)"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", source, str(ROOT / "scripts"), str(work)]
        )
        try:
            time.sleep(0.5)
            process.send_signal(signal.SIGTERM)
            assert process.wait(timeout=5) == 143
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)

    def test_atomic_report(self):
        agy_review.atomic_json(self.report, {"complete": True})
        assert json.loads(self.report.read_text()) == {"complete": True}
        assert not list(self.home.glob(".report.json.*"))

    def test_catalog_selection(self):
        assert (
            agy_review.eligible_catalog(
                "gemini-4-argon-high\ngemini-3.9-pro-high\ngemini-5-flash-high"
            )
            == "gemini-4-argon-high"
        )
        with self.assertRaisesRegex(ValueError, "catalog"):
            agy_review.eligible_catalog("gemini-4-argon-high\ngemini-4-pro-high")

    def test_private_diagnostics(self):
        result = self.run_review("secret")
        combined = (
            result.stdout
            + result.stderr
            + "".join(p.read_text() for p in (self.home / "diagnostics").glob("*"))
        )
        for value in (
            "fixture-secret-value",
            "fixture-password",
            "user@example.org",
            "192.0.2.10",
            "c2VjcmV0",
        ):
            assert value not in combined


if __name__ == "__main__":
    unittest.main()
