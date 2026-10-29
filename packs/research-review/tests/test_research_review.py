"""Synthetic local handoff E2E; no real posts, accounts or provider calls."""
import copy
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import mock_open, patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import research_review as rr


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.run = self.root / "run"
        proc = self.cli("init", str(self.run), "--question", "Compare public evidence",
                        "--recipient", "Coordinator", "--max-chars", "1000")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.path = self.run / "bundle.json"
        self.bundle = rr.load(self.path)
        self.bundle["sources"] = [{"id": "S1", "url": "https://example.org/post",
            "speaker": "Publisher", "published_at": "unknown", "by": "researcher",
            "retrieved_at": "2026-01-01T00:00:00Z", "method": "browser",
            "outcome": "read", "conditions": "synthetic example", "excerpt": "Example text"}]
        self.bundle["claims"] = [{"id": "C1", "statement": "An attributed report.",
            "speaker": "Publisher", "kind": "experience", "causal_status": "reported",
            "conditions": "cause is unconfirmed", "source_ids": ["S1"]}]
        self.bundle["artifacts"][0]["claim_ids"] = ["C1"]
        (self.run / "report.md").write_text("The publisher reports it; cause unconfirmed.\n")
        self.bind_review()

    def cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPTS / "research_review.py"), *args],
                              text=True, capture_output=True)

    def save(self):
        self.path.write_text(json.dumps(self.bundle))

    def bind_review(self):
        digest = rr.inspect(self.bundle, self.run)[-1]
        self.bundle["review"] = {"target_digest": digest, "reviewer": "Reviewer",
            "checked_at": "2026-01-01T01:00:00Z",
            "artifact_ids": [a["id"] for a in self.bundle["artifacts"]],
            "items": [{"claim_id": c["id"], "verdict": "verified",
                       "source_ids": c["source_ids"], "note": "Synthetic check"}
                      for c in self.bundle["claims"]]}
        self.save()

    def result(self):
        return rr.lint(self.bundle, self.run)

    def test_cli_roundtrip_and_truth_boundary(self):
        self.assertEqual(self.cli("target", str(self.path)).returncode, 0)
        proc = self.cli("lint", str(self.path))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertTrue(result["structure_only"])
        self.assertTrue(result["structurally_complete"])
        self.assertIn("source_truth", result["not_verified"])
        self.assertIn("prose_claim_coverage", result["not_verified"])

    def test_init_never_overwrites_and_ignores_private_run(self):
        before = self.path.read_bytes()
        proc = self.cli("init", str(self.run), "--question", "other", "--recipient", "other")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(before, self.path.read_bytes())
        self.assertEqual((self.run / ".gitignore").read_text(), "*\n")
        if os.name == "posix":
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_brief_contains_task_id_and_contract_without_sending(self):
        proc = self.cli("brief", str(self.path))
        self.assertEqual(proc.returncode, 0)
        self.assertIn(self.bundle["task"]["id"], proc.stdout)
        self.assertIn("Research bundle v1", proc.stdout)

    def test_changed_report_or_evidence_invalidates_review(self):
        (self.run / "report.md").write_text("Different causal assertion.")
        self.assertFalse(self.result()["structurally_complete"])
        self.bind_review()
        self.bundle["claims"][0]["conditions"] = "different condition"
        self.assertFalse(self.result()["structurally_complete"])

    def test_missing_appendix_review_and_claim_are_incomplete(self):
        (self.run / "appendix.md").write_text("A second material claim.")
        self.bundle["claims"].append({**self.bundle["claims"][0], "id": "C2"})
        self.bundle["artifacts"].append({"id": "appendix", "kind": "appendix",
            "path": "appendix.md", "claim_ids": ["C2"], "unknown_claim_ids": []})
        self.bind_review()
        self.bundle["review"]["artifact_ids"] = ["report"]
        self.bundle["review"]["items"] = self.bundle["review"]["items"][:1]
        result = self.result()
        self.assertFalse(result["structurally_complete"])
        self.assertTrue(any("appendix" in x for x in result["issues"]))
        self.assertTrue(any("C2" in x for x in result["issues"]))

    def test_unknown_can_be_reported_but_must_be_disclosed(self):
        claim = self.bundle["claims"][0]
        claim["kind"] = "unknown"
        with self.assertRaises(rr.ContractError):
            self.result()
        self.bundle["artifacts"][0]["unknown_claim_ids"] = ["C1"]
        self.bind_review()
        self.bundle["review"]["items"][0]["verdict"] = "unverifiable"
        self.assertTrue(self.result()["structurally_complete"])
        self.assertEqual(self.result()["disclosed_unknown_claim_ids"], ["C1"])

    def test_reviewer_identity_and_unavailable_original(self):
        self.bundle["review"]["reviewer"] = "researcher"
        self.assertFalse(self.result()["structurally_complete"])
        self.bundle["sources"][0]["outcome"] = "unavailable"
        self.bind_review()
        self.assertFalse(self.result()["structurally_complete"])

    def test_different_fetch_conditions_can_coexist(self):
        self.bundle["sources"].append({**self.bundle["sources"][0], "id": "S0",
            "outcome": "unavailable", "excerpt": "", "method": "curl",
            "conditions": "different headers"})
        self.bind_review()
        self.assertTrue(self.result()["structurally_complete"])

    def test_paths_ids_and_qualifier_fields(self):
        for change in (lambda: self.bundle["artifacts"][0].update(path="../outside.md"),
                       lambda: self.bundle["artifacts"][0].update(claim_ids=["missing"]),
                       lambda: self.bundle["claims"][0].pop("speaker"),
                       lambda: self.bundle["claims"][0].pop("conditions")):
            original = copy.deepcopy(self.bundle)
            change()
            with self.assertRaises(rr.ContractError):
                self.result()
            self.bundle = original

    def test_duplicate_json_keys_and_non_finite_values(self):
        for raw in ('{"schema_version":1,"schema_version":1}', '{"value":NaN}'):
            self.path.write_text(raw)
            self.assertEqual(self.cli("lint", str(self.path)).returncode, 2)

    def test_numeric_url_is_a_json_input_error_without_traceback(self):
        self.bundle["sources"][0]["url"] = 123
        self.save()
        proc = self.cli("lint", str(self.path))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("invalid public URL", json.loads(proc.stderr)["error"])
        self.assertNotIn("Traceback", proc.stderr)

    def test_task_id_requires_a_string(self):
        self.bundle["task"]["id"] = 123
        self.save()
        self.assertEqual(self.cli("brief", str(self.path)).returncode, 2)

    def test_size_limit_bounds_reads_before_parsing_or_hashing(self):
        source = mock_open(read_data=b"x" * (rr.LIMIT + 1))
        with patch.object(Path, "open", source):
            with self.assertRaises(rr.ContractError):
                rr.load(self.path)
            source().read.assert_called_once_with(rr.LIMIT + 1)
        source = mock_open(read_data=b"x" * (rr.LIMIT + 1))
        with patch.object(Path, "open", source):
            with self.assertRaises(rr.ContractError):
                rr.inspect(self.bundle, self.run)
            source().read.assert_called_once_with(rr.LIMIT + 1)

    def test_length_budget_is_combined_raw_report_text(self):
        (self.run / "second.md").write_text("x" * 30)
        self.bundle["task"]["max_chars"] = 60
        self.bundle["artifacts"].append({"id": "report2", "kind": "report",
            "path": "second.md", "claim_ids": ["C1"], "unknown_claim_ids": []})
        self.bind_review()
        self.assertFalse(self.result()["structurally_complete"])


if __name__ == "__main__":
    unittest.main()
