"""Verify diagnostics cannot silently pass when Swift reports concurrency warnings."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("verify_concurrency", SCRIPTS / "verify_concurrency.py")
concurrency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(concurrency)
project_spec = importlib.util.spec_from_file_location("verify_project", SCRIPTS / "verify_project.py")
project = importlib.util.module_from_spec(project_spec)
project_spec.loader.exec_module(project)


class VerificationDiagnosticsTests(unittest.TestCase):
    def test_actor_sendability_and_swift6_notes_fail_the_gate(self):
        fixtures = [
            "App.swift:5: warning: main actor-isolated value cannot be referenced here\n",
            "App.swift:8: warning: capture of 'work' with non-Sendable type in a closure\n",
            "App.swift:10: warning: passing argument may introduce data races\n",
            "App.swift:12: warning: unsafe operation\n  note: this is an error in the Swift 6 language mode\n",
        ]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                self.assertEqual(len(concurrency.concurrency_warnings(fixture)), 1)

    def test_ordinary_sdk_deprecation_and_clean_output_do_not_fail_concurrency(self):
        self.assertEqual(concurrency.concurrency_warnings("App.swift:2: warning: oldAPI was deprecated in iOS 26\n"), [])
        self.assertEqual(concurrency.concurrency_warnings("Build succeeded\n"), [])

    @unittest.skipUnless(sys.platform == "linux", "Linux platform boundary")
    def test_native_mode_cannot_claim_ios_checks_on_linux(self):
        result = subprocess.run([sys.executable, str(SCRIPTS / "verify_concurrency.py"), "--native"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("No native check ran", result.stdout)


class WorkflowContractTests(unittest.TestCase):
    def test_linux_workflow_requires_the_shared_gate_and_evidence_artifact(self):
        workflow = {
            "jobs": {
                "verify": {
                    "runs-on": "ubuntu-24.04",
                    "container": "swift:6.3.3-noble",
                    "steps": [
                        {"run": 'python3 "$GITHUB_WORKSPACE/scripts/verify.py" --logs-dir "$RUNNER_TEMP/mio-verification"'},
                        {"uses": "actions/upload-artifact@v7"},
                    ],
                }
            }
        }
        self.assertEqual(project.workflow_contract_issues("verify-linux.yml", workflow), [])

        workflow["jobs"]["verify"]["container"] = "ubuntu:latest"
        workflow["jobs"]["verify"]["steps"][0]["run"] = "echo skipped"
        workflow["jobs"]["verify"]["steps"].pop()
        issues = project.workflow_contract_issues("verify-linux.yml", workflow)
        self.assertEqual(len(issues), 3)
        self.assertIn("Ubuntu 24.04 och Swift 6.3.3 Noble", issues)
        self.assertIn("den gemensamma verifieraren med sparad loggplats", issues)
        self.assertIn("uppladdning av verifieringsbevis", issues)


if __name__ == "__main__":
    unittest.main()
