"""Offline runtime boundaries. No real credentials, Drive or provider calls."""
import copy
import http.client
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest.mock import patch, Mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import grok_runtime as rt
import materialize_drive_file as materialize
from research_review import ContractError

ORIGIN = "https://example.org"
ENDPOINT = ORIGIN + "/routine/example"
FOLDER = "https://drive.google.com/drive/folders/example-output"
SECRET = "synthetic-key-never-print"


class FakeKeychain:
    def get(self, account):
        return rt.encoded({"endpoint": ENDPOINT, "key": SECRET})


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "runtime"
        rt.configure(self.root, ORIGIN, FOLDER)
        cfg = rt.config(self.root)
        cfg["endpoint_sha256"] = rt.sha(ENDPOINT.encode())
        rt.save(self.root / "profile.json", cfg)
        self.calls = []

    def prepare(self):
        return rt.prepare(self.root, "Public documentation and reported limits", "last 7 days")["task_id"]

    def sender(self, bundle, endpoint, key, origin, payload):
        self.calls.append(payload)
        # Both durable guards must exist before dispatch, not after the result.
        task_id = bundle["task"]["id"]
        self.assertTrue((self.root / "pending.json").exists())
        self.assertTrue((rt.job_path(self.root, task_id) / "attempt.json").exists())
        return {"status": "accepted", "task_id": task_id, "automatic_retry": False,
                "http_status": 200, "research_complete": False}

    def submit(self, task_id, sender=None, now=None):
        return rt.submit(self.root, task_id, FakeKeychain(), sender or self.sender, now)

    def envelope(self, task_id):
        request, _ = rt.read_json(rt.job_path(self.root, task_id) / "request.json")
        bundle = copy.deepcopy(request["bundle_template"])
        bundle["sources"] = [{"id": "S1", "url": "https://example.org/doc", "speaker": "Publisher",
            "published_at": "unknown", "retrieved_at": "2026-01-01T00:00:00Z", "by": "Researcher",
            "method": "browser", "outcome": "read", "conditions": "Synthetic only", "excerpt": "Text"}]
        bundle["claims"] = [{"id": "C1", "statement": "A sourced claim", "kind": "fact",
            "speaker": "Publisher", "causal_status": "not_asserted", "conditions": "Synthetic",
            "source_ids": ["S1"]}]
        bundle["artifacts"][0]["claim_ids"] = ["C1"]
        return {"schema_version": 1, "task_id": task_id, "task_sha256": request["task_sha256"],
                "bundle": bundle, "files": {"report.md": "An attributed claim.\n"}}

    def collect(self, task_id, envelope):
        path = Path(self.tmp.name) / "actual-download.json"
        path.write_bytes(rt.encoded(envelope))
        return rt.collect(self.root, task_id, path, FOLDER, "synthetic-file-id")

    def test_prepare_does_not_read_keychain_or_send(self):
        with patch.object(rt, "MacKeychain", side_effect=AssertionError("secret access")):
            task = self.prepare()
        raw = (rt.job_path(self.root, task) / "request.json").read_bytes()
        self.assertNotIn(SECRET.encode(), raw)
        self.assertNotIn(ENDPOINT.encode(), raw)
        self.assertFalse((self.root / "pending.json").exists())

    def test_one_send_pending_and_no_secret_files(self):
        task = self.prepare()
        self.assertEqual(self.submit(task)["status"], "accepted")
        with self.assertRaises(ContractError):
            self.submit(task)
        with self.assertRaises(ContractError):
            self.submit(self.prepare())
        self.assertEqual(len(self.calls), 1)
        for path in self.root.rglob("*.json"):
            self.assertNotIn(SECRET.encode(), path.read_bytes())
            self.assertNotIn(ENDPOINT.encode(), path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_timeout_and_process_failure_leave_no_retry_path(self):
        for result in ("unknown", "crash"):
            with self.subTest(result=result):
                if (self.root / "pending.json").exists():
                    old, _ = rt.read_json(self.root / "pending.json")
                    rt.reconcile(self.root, old["task_id"], "Operator observed cancelled in Bot")
                task = self.prepare()
                def sender(*args, **kwargs):
                    if result == "crash":
                        raise OSError("synthetic interruption")
                    return {"status": "unknown", "task_id": task, "automatic_retry": False}
                if result == "crash":
                    with self.assertRaises(OSError):
                        self.submit(task, sender)
                else:
                    self.submit(task, sender)
                with self.assertRaises(ContractError):
                    self.submit(task)
                self.assertEqual(rt.status(self.root)["pending"]["task_id"], task)

    def test_rejection_consumes_daily_reservation_but_frees_slot(self):
        now = datetime(2026, 1, 1, tzinfo=timezone.utc)
        def reject(*args, **kwargs):
            return {"status": "not_accepted", "http_status": 400}
        for _ in range(3):
            self.submit(self.prepare(), reject, now)
        with self.assertRaises(ContractError):
            self.submit(self.prepare(), reject, now)
        next_day = datetime(2026, 1, 2, tzinfo=timezone.utc)
        self.assertEqual(self.submit(self.prepare(), reject, next_day)["status"], "not_accepted")

    def test_endpoint_pin_rejects_same_host_different_routine(self):
        class WrongRoutine:
            def get(self, account):
                return rt.encoded({"endpoint": ORIGIN + "/routine/other", "key": SECRET})
        with self.assertRaises(ContractError):
            rt.submit(self.root, self.prepare(), WrongRoutine(), self.sender)
        self.assertEqual(self.calls, [])

    def test_receive_preserves_actual_bytes_and_requires_source_review(self):
        task = self.prepare()
        self.submit(task)
        value = self.envelope(task)
        result = self.collect(task, value)
        self.assertEqual(result["status"], "received")
        self.assertFalse(result["research_complete"])
        self.assertFalse(result["structurally_complete"])
        path = rt.job_path(self.root, task) / "received"
        self.assertEqual((path / "report.md").read_bytes(), value["files"]["report.md"].encode())
        self.assertEqual(rt.sha((path / "raw-return.json").read_bytes()), result["raw_return_sha256"])
        self.assertIsNone(rt.status(self.root)["pending"])

    def test_mismatch_traversal_oversize_missing_file_keep_pending(self):
        task = self.prepare()
        self.submit(task)
        original = self.envelope(task)
        variants = []
        wrong = copy.deepcopy(original)
        wrong["task_id"] = "b" * 32
        variants.append(wrong)
        wrong = copy.deepcopy(original)
        wrong["bundle"]["task"]["question"] = "Different task"
        variants.append(wrong)
        wrong = copy.deepcopy(original)
        wrong["bundle"]["artifacts"][0]["path"] = "../profile.json"
        wrong["files"] = {"../profile.json": "overwrite"}
        variants.append(wrong)
        wrong = copy.deepcopy(original)
        wrong["files"] = {"report.md": "x" * 1300}
        variants.append(wrong)
        wrong = copy.deepcopy(original)
        wrong["files"] = {"other.md": "wrong"}
        variants.append(wrong)
        for value in variants:
            with self.assertRaises(ContractError):
                self.collect(task, value)
            self.assertEqual(rt.status(self.root)["pending"]["task_id"], task)
        self.assertFalse((rt.job_path(self.root, task) / "received").exists())

    def test_busy_lock_and_nonprivate_root_refuse(self):
        with rt.locked(self.root):
            with self.assertRaises(ContractError):
                self.prepare()
        os.chmod(self.root, 0o755)
        with self.assertRaises(ContractError):
            self.prepare()

    def test_reconcile_recovers_after_interruption(self):
        task = self.prepare()
        self.submit(task)
        original_save = rt.save
        def interrupt(path, value):
            if path.name == "state.json":
                raise OSError("interrupted after recording observation")
            return original_save(path, value)
        note = "Observed this exact task cancelled in the routine"
        with patch.object(rt, "save", side_effect=interrupt):
            with self.assertRaises(OSError):
                rt.reconcile(self.root, task, note)
        rt.reconcile(self.root, task, note)
        self.assertIsNone(rt.status(self.root)["pending"])
        self.assertEqual(len(self.calls), 1)

    def test_collect_recovers_after_finalizing_files(self):
        task = self.prepare()
        self.submit(task)
        value = self.envelope(task)
        original_save = rt.save
        def interrupt(path, data):
            if path.name == "state.json":
                raise OSError("interrupted after rename")
            return original_save(path, data)
        with patch.object(rt, "save", side_effect=interrupt):
            with self.assertRaises(OSError):
                self.collect(task, value)
        self.assertTrue((rt.job_path(self.root, task) / "received" / "receipt.json").exists())
        self.assertEqual(self.collect(task, value)["status"], "received")
        self.assertIsNone(rt.status(self.root)["pending"])
        self.assertEqual(len(self.calls), 1)

    def test_materializer_requires_connector_host_and_bounds_before_write(self):
        class Response:
            status = 200
            def __init__(self, raw):
                self.raw = raw
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass
            def read(self, count):
                self.count = count
                return self.raw[:count]
        class Opener:
            def __init__(self, response):
                self.response = response
            def open(self, url, timeout):
                return self.response
        path = Path(self.tmp.name) / "raw.json"
        for url in ("http://files.oaiusercontent.com/x", "https://evil.example/x",
                    "https://files.oaiusercontent.com.evil.example/x", "https://user@files.oaiusercontent.com/x"):
            with self.assertRaises(ContractError):
                materialize.download({"download_url": url}, path)
        reference = {"download_url": "https://files.oaiusercontent.com/example?signature=synthetic"}
        response = Response(b"x" * (rt.LIMIT + 1))
        with self.assertRaises(ContractError):
            materialize.download(reference, path, Opener(response))
        self.assertFalse(path.exists())
        raw = b'{"synthetic":true}\n'
        result = materialize.download(reference, path, Opener(Response(raw)))
        self.assertEqual(path.read_bytes(), raw)
        self.assertEqual(result["sha256"], rt.sha(raw))
        with self.assertRaises(ContractError):
            materialize.download(reference, path, Opener(Response(b"overwrite")))

    def test_bad_input_does_not_traceback_or_echo(self):
        (self.root / "profile.json").write_text("[\"" + SECRET + "\"]")
        result = subprocess.run([sys.executable, str(SCRIPTS / "grok_runtime.py"), "--root",
                                 str(self.root), "status"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(SECRET, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_materializer_protocol_errors_do_not_echo_bearer_or_traceback(self):
        for failure in (http.client.BadStatusLine(SECRET), http.client.IncompleteRead(SECRET.encode())):
            stream = Mock()
            stream.isatty.return_value = False
            stream.buffer = io.BytesIO(b'{"download_url":"https://files.oaiusercontent.com/test"}\n')
            out, err = io.StringIO(), io.StringIO()
            with patch.object(sys, "stdin", stream), patch.object(sys, "argv", ["materialize", "/unused"]), \
                    patch.object(materialize, "download", side_effect=failure), \
                    redirect_stdout(out), redirect_stderr(err):
                self.assertEqual(materialize.main(), 2)
            self.assertNotIn(SECRET, out.getvalue() + err.getvalue())
            self.assertNotIn("Traceback", err.getvalue())
            self.assertFalse(json.loads(err.getvalue())["materialized"])


if __name__ == "__main__":
    unittest.main()
