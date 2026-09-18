#!/usr/bin/env python3
"""Acceptance tests for local, paired retrieval measurement."""
import copy
import importlib
import json
import sqlite3
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from threading import Barrier
from unittest.mock import patch
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
lab = importlib.import_module("retrieval_lab")


def document(text="曜日を待たず投稿する。", summaries=None):
    return {"source_id": "session-a", "start_line": 3, "end_line": 5,
            "text": text, "summaries": summaries or ["投稿タイミング quasar"]}


class RetrievalLabTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "lab"
        self.manifest = {"schema_version": 1, "documents": [document()]}

    def create(self, manifest=None):
        return lab.create_lab(self.root, manifest or self.manifest)

    def test_cli_search_starts_detached_shadow_and_reports_difference(self):
        self.create()
        script = Path(__file__).resolve().parents[1] / "scripts" / "retrieval_lab.py"
        completed = subprocess.run(
            [sys.executable, str(script), "--lab", str(self.root), "search", "quasar", "--sample-rate", "1"],
            capture_output=True, text=True, timeout=5, check=True,
        )
        foreground = json.loads(completed.stdout)
        self.assertTrue(foreground["sampled"])
        self.assertEqual(len(foreground["hits"]), 1)
        deadline = time.monotonic() + 5
        report = lab.report(self.root)
        while report["completed_pairs"] == 0 and time.monotonic() < deadline:
            time.sleep(.025)
            report = lab.report(self.root)
        self.assertEqual(report["completed_pairs"], 1)
        self.assertEqual(report["pending_pairs"], 0)
        self.assertEqual(report["feedback_unknown"], 1)
        case = next(c for c in report["review_cases"] if c["request_id"] == foreground["request_id"])
        self.assertIn("one_sided_retrieval", case["reason"])

    def stored_query(self, request_id):
        with closing(sqlite3.connect(self.root / "measurements.sqlite")) as db:
            db.row_factory = sqlite3.Row
            return dict(db.execute("SELECT * FROM queries WHERE id=?", (request_id,)).fetchone())

    def test_shadow_answer_requires_completed_retrieval(self):
        self.create()
        request = lab.search(self.root, "投稿", arm="recorder", sample_rate=1)
        citation = request["hits"][0]["citation_id"]
        with self.assertRaises(ValueError):
            lab.record_answer(self.root, request["request_id"], "baseline", "当日に投稿", [citation])
        lab.drain(self.root)
        answer = lab.record_answer(self.root, request["request_id"], "baseline", "当日に投稿", [citation])
        self.assertTrue(answer["answer_id"])

    def test_review_packet_hides_arms_and_summary_text(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=1)
        lab.drain(self.root)
        citation = request["hits"][0]["citation_id"]
        for arm, text in (("baseline", "曜日を待たずに投稿"), ("recorder", "同日中に投稿")):
            lab.record_answer(self.root, request["request_id"], arm, text, [citation])
        packet = lab.review_packet(self.root, request["request_id"])
        self.assertEqual(len(packet["candidates"]), 2)
        candidates = json.dumps(packet["candidates"], ensure_ascii=False)
        for hidden in ("baseline", "recorder", "quasar", "summaries", '"arm"'):
            self.assertNotIn(hidden, candidates)
        for candidate in packet["candidates"]:
            self.assertEqual(candidate["citations"][0]["text"], document()["text"])

    def test_replacing_answer_invalidates_previous_assessment(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=0)
        request_id = request["request_id"]
        citation = request["hits"][0]["citation_id"]
        answer = lab.record_answer(self.root, request_id, "recorder", "当日に投稿", [citation])
        lab.assess(self.root, request_id, answer["answer_id"], "supported", "absent", "human:fixture-review")
        assessment = json.loads(self.stored_query(request_id)["assessments"])["recorder"]
        self.assertEqual(assessment["grounded"], "supported")
        self.assertEqual(assessment["provenance"], "human:fixture-review")
        lab.record_answer(self.root, request_id, "recorder", "新しい別の結論", [citation])
        self.assertEqual(json.loads(self.stored_query(request_id)["assessments"]), {})
        with self.assertRaises(ValueError):
            lab.assess(self.root, request_id, answer["answer_id"], "supported", "absent", "human:fixture-review")

    def test_unresolvable_or_absent_citations_cannot_be_supported(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=0)
        for citations in (["missing-citation"], []):
            with self.subTest(citations=citations):
                answer = lab.record_answer(self.root, request["request_id"], "recorder", "結論", citations)
                with self.assertRaises(ValueError):
                    lab.assess(self.root, request["request_id"], answer["answer_id"], "supported", "absent", "human:test")
                lab.assess(self.root, request["request_id"], answer["answer_id"], "unknown", "unknown", "human:test")

    def test_retrieving_evidence_does_not_implicitly_assess_answer(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=1)
        lab.drain(self.root)
        self.assertEqual(json.loads(self.stored_query(request["request_id"])["assessments"]), {})
        self.assertEqual(lab.report(self.root)["feedback_unknown"], 1)

    def test_benchmark_measures_evidence_and_keeps_gold_out_of_history(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=0)
        citation = request["hits"][0]["citation_id"]
        before = lab.report(self.root)["total_queries"]
        result = lab.benchmark(self.root, [{"question": "quasar", "expected_citations": [citation]}], repeats=2)
        self.assertEqual(len(result["results"]), 4)
        for row in result["results"]:
            self.assertEqual(row["evidence_hit"], row["arm"] == "recorder")
            self.assertNotIn("grounded", row)
            self.assertNotIn("answer_correct", row)
        self.assertEqual(lab.report(self.root)["total_queries"], before)
        self.assertIn("not grounded answer accuracy", result["measurement_scope"])
        self.assertNotIn("expected_citations", json.dumps(self.stored_query(request["request_id"])))

    def test_concurrent_drainers_claim_each_job_once(self):
        self.create()
        for _ in range(8):
            lab.search(self.root, "投稿", sample_rate=1)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(lab.drain, self.root, max_jobs=8, max_seconds=10) for _ in range(2)]
            results = [future.result() for future in futures]
        self.assertEqual(sum(r["processed"] for r in results), 8)
        self.assertEqual(lab.report(self.root)["completed_pairs"], 8)
        self.assertEqual(lab.report(self.root)["pending_pairs"], 0)

    def test_concurrent_answer_and_assessment_updates_preserve_both_arms(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=1)
        request_id = request["request_id"]
        citation = request["hits"][0]["citation_id"]
        lab.drain(self.root)
        barrier = Barrier(2)

        def record(arm):
            barrier.wait(timeout=5)
            return lab.record_answer(self.root, request_id, arm, "投稿 " + arm, [citation])

        with ThreadPoolExecutor(max_workers=2) as pool:
            answers = list(pool.map(record, ("baseline", "recorder")))
        self.assertEqual(set(json.loads(self.stored_query(request_id)["answers"])), {"baseline", "recorder"})
        barrier = Barrier(2)

        def assess(answer):
            barrier.wait(timeout=5)
            return lab.assess(self.root, request_id, answer["answer_id"], "supported", "absent", "human:parallel-test")

        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(assess, answers))
        self.assertEqual(set(json.loads(self.stored_query(request_id)["assessments"])), {"baseline", "recorder"})

    def test_daily_shadow_budget_caps_sampled_queries(self):
        self.create()
        with patch.object(lab, "MAX_SHADOWS_PER_DAY", 2):
            requests = [lab.search(self.root, "投稿", sample_rate=1) for _ in range(3)]
        self.assertEqual([r["sampled"] for r in requests], [True, True, False])
        self.assertEqual(requests[-1]["sampling_skip_reason"], "daily_shadow_limit")
        self.assertEqual(lab.report(self.root)["pending_pairs"], 2)

    def test_lower_candidate_membership_change_requires_review(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=1)
        lab.drain(self.root)
        stored = self.stored_query(request["request_id"])
        shadow = json.loads(stored["shadow"])
        lower = copy.deepcopy(shadow["hits"][0])
        lower.update(citation_id="different-lower-candidate", rank=2)
        shadow["hits"].append(lower)
        with closing(sqlite3.connect(self.root / "measurements.sqlite")) as db, db:
            db.execute("UPDATE queries SET shadow=? WHERE id=?", (json.dumps(shadow), request["request_id"]))
        case = lab.report(self.root)["review_cases"][0]
        self.assertIn("candidate_membership_changed", case["reason"])

    def test_version_mismatch_is_failed_pair_not_comparison(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=1)
        with closing(sqlite3.connect(self.root / "measurements.sqlite")) as db, db:
            db.execute("UPDATE queries SET version=? WHERE id=?", ("other-version", request["request_id"]))
        outcome = lab.drain(self.root)
        self.assertEqual(outcome["processed"], 0)
        self.assertEqual(outcome["failed"], 1)
        stored = self.stored_query(request["request_id"])
        self.assertEqual(stored["job_state"], "error")
        self.assertIsNone(stored["shadow"])
        self.assertEqual(lab.report(self.root)["completed_pairs"], 0)

    def test_summary_only_term_is_unavailable_to_baseline(self):
        self.create()
        baseline = lab.search(self.root, "quasar", arm="baseline", sample_rate=0)
        recorder = lab.search(self.root, "quasar", arm="recorder", sample_rate=0)
        self.assertEqual(baseline["hits"], [])
        self.assertEqual(len(recorder["hits"]), 1)
        self.assertEqual(recorder["hits"][0]["text"], document()["text"])
        self.assertNotIn("quasar", recorder["hits"][0]["text"])

    def test_arms_return_identical_resolvable_raw_citations(self):
        self.create()
        results = [lab.search(self.root, "投稿", arm=arm, sample_rate=0)
                   for arm in ("baseline", "recorder")]
        a, b = (r["hits"][0] for r in results)
        self.assertEqual(a["citation_id"], b["citation_id"])
        citation = lab.read_citation(self.root, a["citation_id"])
        for key in ("source_id", "start_line", "end_line", "text"):
            self.assertEqual(citation[key], a[key])
        self.assertEqual(results[0]["snapshot_id"], results[1]["snapshot_id"])

    def test_snapshot_is_independent_of_manifest_mutation_and_exclusive(self):
        self.create()
        original = lab.search(self.root, "quasar", sample_rate=0)
        self.manifest["documents"][0]["text"] = "changed"
        self.manifest["documents"][0]["summaries"] = []
        current = lab.search(self.root, "quasar", sample_rate=0)
        self.assertEqual(current["hits"], original["hits"])
        self.assertEqual(current["snapshot_id"], original["snapshot_id"])
        with self.assertRaises((ValueError, FileExistsError)):
            lab.create_lab(self.root, self.manifest)

    def test_duplicate_spans_merge_summaries_without_multiplying_hits(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["documents"].append(document(summaries=["nebula"]))
        self.create(manifest)
        first = lab.search(self.root, "quasar", sample_rate=0)
        second = lab.search(self.root, "nebula", sample_rate=0)
        self.assertEqual(len(first["hits"]), 1)
        self.assertEqual(len(second["hits"]), 1)
        self.assertEqual(first["hits"][0]["citation_id"], second["hits"][0]["citation_id"])

    def test_conflicting_text_for_same_span_is_rejected(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["documents"].append(document(text="Different raw evidence"))
        with self.assertRaises(ValueError):
            self.create(manifest)

    def test_foreground_only_queues_and_worker_respects_job_budget(self):
        self.create()
        requests = [lab.search(self.root, "quasar", sample_rate=1) for _ in range(3)]
        self.assertTrue(all(r["sampled"] for r in requests))
        before = lab.report(self.root)
        self.assertEqual(before["completed_pairs"], 0)
        self.assertEqual(before["pending_pairs"], 3)
        first = lab.drain(self.root, max_jobs=1, max_seconds=10)
        self.assertEqual(first["processed"], 1)
        self.assertEqual(first["pending"], 2)
        second = lab.drain(self.root, max_jobs=5, max_seconds=10)
        self.assertEqual(second["processed"], 2)
        self.assertEqual(second["pending"], 0)
        self.assertEqual(lab.drain(self.root)["processed"], 0)
        self.assertEqual(lab.report(self.root)["total_queries"], 3)

    def test_zero_sampling_does_not_schedule_shadow(self):
        self.create()
        result = lab.search(self.root, "投稿", sample_rate=0)
        self.assertFalse(result["sampled"])
        self.assertEqual(lab.drain(self.root)["processed"], 0)
        self.assertEqual(lab.report(self.root)["pending_pairs"], 0)

    def test_silence_remains_unknown_until_explicit_feedback(self):
        self.create()
        request = lab.search(self.root, "投稿", sample_rate=0)
        self.assertEqual(lab.report(self.root)["feedback_unknown"], 1)
        lab.feedback(self.root, request["request_id"], "wrong_target")
        self.assertEqual(lab.report(self.root)["feedback_unknown"], 0)
        with self.assertRaises(ValueError):
            lab.feedback(self.root, request["request_id"], "silence_means_success")

    def test_one_sided_retrieval_is_review_case_not_declared_winner(self):
        self.create()
        request = lab.search(self.root, "quasar", sample_rate=1)
        lab.drain(self.root)
        report = lab.report(self.root)
        self.assertEqual(report["completed_pairs"], 1)
        case = next(c for c in report["review_cases"] if c["request_id"] == request["request_id"])
        self.assertTrue(case["reason"])
        self.assertIsInstance(case["reason"], list)
        self.assertNotIn("winner", case)
        self.assertEqual(report["feedback_unknown"], 1)

    def test_equivalent_no_hits_are_not_a_meaningful_difference(self):
        self.create()
        lab.search(self.root, "zzzzunfindable", sample_rate=1)
        lab.drain(self.root)
        self.assertEqual(lab.report(self.root)["review_cases"], [])

    def test_acknowledged_difference_reappears_only_when_evidence_changes(self):
        self.create()
        request = lab.search(self.root, "quasar", sample_rate=1)
        lab.drain(self.root)
        case = lab.report(self.root)["review_cases"][0]
        lab.acknowledge(self.root, request["request_id"], case["fingerprint"])
        self.assertEqual(lab.report(self.root)["review_cases"], [])
        self.assertEqual(lab.report(self.root)["reviewed_cases"], 1)
        self.assertEqual(len(lab.report(self.root, include_reviewed=True)["review_cases"]), 1)
        lab.feedback(self.root, request["request_id"], "wrong_target")
        self.assertEqual(len(lab.report(self.root)["review_cases"]), 1)
        with self.assertRaises(ValueError):
            lab.acknowledge(self.root, request["request_id"], case["fingerprint"])

    def test_unassessed_quality_rate_is_unknown(self):
        self.create()
        lab.search(self.root, "quasar", sample_rate=1)
        lab.drain(self.root)
        metrics = lab.report(self.root)["arm_metrics"]
        for arm in ("baseline", "recorder"):
            self.assertEqual(metrics[arm]["runs"], 1)
            self.assertIsNone(metrics[arm]["supported_fraction_of_assessed"])

    def test_unicode_delivery_metrics_and_unknown_provider_cost(self):
        self.create()
        result = lab.search(self.root, "投稿", sample_rate=0)
        metrics = result["metrics"]
        expected_bytes = sum(len(hit["text"].encode("utf-8")) for hit in result["hits"])
        self.assertEqual(metrics["returned_bytes"], expected_bytes)
        self.assertGreaterEqual(metrics["scanned_bytes"], expected_bytes)
        self.assertGreaterEqual(metrics["elapsed_ms"], 0)
        for key in ("input_tokens", "output_tokens", "cost_microusd"):
            self.assertIsNone(metrics[key])


if __name__ == "__main__":
    unittest.main()
