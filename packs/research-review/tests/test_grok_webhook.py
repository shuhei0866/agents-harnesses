"""HTTP protocol mocks, deliberately not a live Grok test."""
import io
import http.client
import json
import socket
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import grok_webhook as gw
import research_review as rr


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.bundle = {"task": {"id": "synthetic-task", "recipient": "Coordinator",
                               "question": "Public research"}}
        self.key = "synthetic-test-key"
        self.url = "https://example.org/research-webhook"
        self.origin = "https://example.org"

    def send(self, endpoint=None, key=None, **kwargs):
        return gw.send_once(self.bundle, endpoint or self.url,
                            self.key if key is None else key, self.origin, **kwargs)

    def response(self, status):
        response = Mock(status=status)
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=False)
        opener = Mock()
        opener.open.return_value = response
        return opener, response

    def test_one_post_acceptance_does_not_mean_completion(self):
        opener, response = self.response(200)
        result = self.send(opener=opener)
        self.assertEqual(result["status"], "accepted")
        self.assertFalse(result["research_complete"])
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.get_header("Authorization"), "Bearer " + self.key)
        self.assertEqual(json.loads(request.data)["task_id"], "synthetic-task")
        response.read.assert_not_called()
        self.assertNotIn(self.key, json.dumps(result))
        self.assertNotIn(self.url, json.dumps(result))

    def test_timeout_and_ambiguous_transport_never_retry(self):
        for error in (socket.timeout(), urllib.error.URLError("private diagnostic"),
                      http.client.BadStatusLine("private diagnostic")):
            opener = Mock()
            opener.open.side_effect = error
            result = self.send(opener=opener)
            self.assertEqual(result["status"], "unknown")
            self.assertFalse(result["automatic_retry"])
            opener.open.assert_called_once()
            self.assertNotIn("private diagnostic", json.dumps(result))

    def test_unexpected_responses_do_not_prove_rejection_or_completion(self):
        opener, _ = self.response(202)
        self.assertEqual(self.send(opener=opener)["status"], "unknown")
        opener.open.side_effect = urllib.error.HTTPError(self.url, 503, "hidden", {}, io.BytesIO())
        self.assertEqual(self.send(opener=opener)["status"], "unknown")
        opener.open.side_effect = urllib.error.HTTPError(self.url, 401, "hidden", {}, io.BytesIO())
        self.assertEqual(self.send(opener=opener)["status"], "not_accepted")

    def test_redirect_handler_never_builds_redirected_request(self):
        handler = gw.NoRedirect()
        self.assertIsNone(handler.redirect_request(None, None, 302, "", {},
                                                   "https://other.example/"))

    def test_bad_configuration_does_not_call_network(self):
        opener = Mock()
        for endpoint, key in (("http://example.org", self.key),
                              ("https://user:pass@example.org", self.key),
                              (self.url + "#fragment", self.key),
                              ("https://other.example/endpoint", self.key),
                              ("https://example.org:444/endpoint", self.key),
                              (self.url, ""), (self.url, "key\nInjected: value"),
                              (self.url + "/調査", self.key), (self.url, "キー")):
            result = self.send(endpoint=endpoint, key=key, opener=opener)
            self.assertEqual(result["status"], "not_sent")
        opener.open.assert_not_called()

    def test_cli_invalid_encoding_never_reserves_attempt(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            rr.initialize(Mock(directory=str(run), question="public",
                               recipient="Coordinator", max_chars=None))
            for endpoint, key in ((self.url + "/調査", self.key), (self.url, "キー")):
                config = {"GROK_BOT_WEBHOOK_URL": endpoint, "GROK_BOT_WEBHOOK_KEY": key,
                          "GROK_BOT_WEBHOOK_ORIGIN": self.origin}
                with patch.object(sys, "argv", ["grok_webhook", str(run / "bundle.json")]), \
                        patch.dict(gw.os.environ, config), \
                        patch.object(gw, "send_once") as send, \
                        patch("sys.stdout", new_callable=io.StringIO) as output:
                    self.assertEqual(gw.main(), 2)
                    self.assertEqual(json.loads(output.getvalue())["status"], "not_sent")
                    send.assert_not_called()
                    self.assertFalse((run / ".grok-webhook-attempt.json").exists())

    def test_cli_dry_run_needs_no_provider_configuration(self):
        with tempfile.TemporaryDirectory() as root:
            scripts = Path(gw.__file__).parent
            run = Path(root) / "run"
            subprocess.run([sys.executable, str(scripts / "research_review.py"), "init",
                            str(run), "--question", "example", "--recipient", "Coordinator"],
                           capture_output=True, check=True)
            result = subprocess.run([sys.executable, str(scripts / "grok_webhook.py"),
                                     str(run / "bundle.json"), "--dry-run"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["network_calls"], 0)
            self.assertNotIn("example", result.stdout)

    def test_cli_reserves_attempt_before_network_and_refuses_repeat(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            args = Mock(directory=str(run), question="public", recipient="Coordinator", max_chars=None)
            rr.initialize(args)
            path = run / "bundle.json"
            config = {"GROK_BOT_WEBHOOK_URL": self.url, "GROK_BOT_WEBHOOK_KEY": self.key,
                      "GROK_BOT_WEBHOOK_ORIGIN": self.origin}
            marker = run / ".grok-webhook-attempt.json"
            def observed_send(*args, **kwargs):
                self.assertTrue(marker.exists())
                return {"status": "unknown", "research_complete": False}
            with patch.object(sys, "argv", ["grok_webhook", str(path)]), \
                    patch.dict(gw.os.environ, config), \
                    patch.object(gw, "send_once", side_effect=observed_send) as send, \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(gw.main(), 75)
                saved = marker.read_text()
                self.assertNotIn(self.key, saved)
                self.assertNotIn(self.url, saved)
                self.assertEqual(gw.main(), 2)
                send.assert_called_once()
                self.assertIn("attempt_already_reserved", output.getvalue())

    def test_stdin_configuration_validation_keeps_secrets_out_of_output(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            rr.initialize(Mock(directory=str(run), question="public",
                               recipient="Coordinator", max_chars=None))
            data = json.dumps({"endpoint": self.url, "key": self.key}).encode()
            with patch.object(sys, "argv", ["grok_webhook", str(run / "bundle.json"),
                                            "--credentials-stdin", "--dry-run"]), \
                    patch.object(sys, "stdin", Mock(buffer=io.BytesIO(data))), \
                    patch.dict(gw.os.environ, {"GROK_BOT_WEBHOOK_ORIGIN": self.origin}, clear=True), \
                    patch.object(gw, "send_once") as send, \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(gw.main(), 0)
                result = json.loads(output.getvalue())
                self.assertTrue(result["configuration_validated"])
                self.assertEqual(result["network_calls"], 0)
                self.assertNotIn(self.key, output.getvalue())
                self.assertNotIn(self.url, output.getvalue())
                self.assertFalse((run / ".grok-webhook-attempt.json").exists())
                send.assert_not_called()

    def test_invalid_stdin_is_bounded_and_never_reserves_or_sends(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            rr.initialize(Mock(directory=str(run), question="public",
                               recipient="Coordinator", max_chars=None))
            cases = [b'{"endpoint": 7, "key": "secret"}', b'[]', b'{',
                     b'{"endpoint":"x","endpoint":"y","key":"secret"}',
                     b'{"endpoint":"x","key":"secret","extra":true}',
                     b'x' * (gw.INPUT_LIMIT + 100), b'[' * 2000 + b']' * 2000]
            for data in cases:
                stream = Mock(wraps=io.BytesIO(data))
                with patch.object(sys, "argv", ["grok_webhook", str(run / "bundle.json"),
                                                "--credentials-stdin"]), \
                        patch.object(sys, "stdin", Mock(buffer=stream)), \
                        patch.object(gw, "send_once") as send, \
                        patch("sys.stderr", new_callable=io.StringIO) as error:
                    self.assertEqual(gw.main(), 2)
                    self.assertEqual(json.loads(error.getvalue())["status"], "not_sent")
                    self.assertNotIn("secret", error.getvalue())
                    stream.read.assert_called_once_with(gw.INPUT_LIMIT + 1)
                    self.assertFalse((run / ".grok-webhook-attempt.json").exists())
                    send.assert_not_called()

    def test_one_reconciled_retry_retains_original_and_reserves_before_send(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            rr.initialize(Mock(directory=str(run), question="public",
                               recipient="Coordinator", max_chars=None))
            path = run / "bundle.json"
            original = run / ".grok-webhook-attempt.json"
            retry = run / ".grok-webhook-retry-attempt.json"
            record = run / "operator-reconciliation.json"
            config = {"GROK_BOT_WEBHOOK_URL": self.url, "GROK_BOT_WEBHOOK_KEY": self.key,
                      "GROK_BOT_WEBHOOK_ORIGIN": self.origin}
            with patch.dict(gw.os.environ, config), \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                with patch.object(sys, "argv", ["grok_webhook", str(path)]), \
                        patch.object(gw, "send_once", return_value={"status": "unknown"}):
                    self.assertEqual(gw.main(), 75)
                prior = original.read_bytes()
                observed = json.loads(prior)
                record.write_text(json.dumps({
                    "task_id": observed["task_id"],
                    "request_sha256": observed["request_sha256"],
                    "prior_marker_sha256": gw.sha(prior), "decision": "retry_once",
                    "observed_at": "2026-01-01T12:00:00+00:00",
                    "observation": "Owning Bot reports no run; individual server logs unavailable.",
                    "user_instruction": "Operator explicitly approved one retry after this check."}))
                def observed_retry(*args, **kwargs):
                    self.assertTrue(retry.exists())
                    self.assertEqual(original.read_bytes(), prior)
                    self.assertEqual(json.loads(retry.read_text())["retry_of"], gw.sha(prior))
                    return {"status": "accepted", "research_complete": False}
                with patch.object(sys, "argv", ["grok_webhook", str(path),
                                                "--reconciled-retry", str(record)]), \
                        patch.object(gw, "send_once", side_effect=observed_retry) as send:
                    self.assertEqual(gw.main(), 0)
                    self.assertEqual(gw.main(), 2)
                    send.assert_called_once()
                self.assertEqual(original.read_bytes(), prior)
                self.assertNotIn(self.key, retry.read_text() + output.getvalue())
                self.assertNotIn(self.url, retry.read_text() + output.getvalue())

    def test_reconciliation_must_bind_exact_original_task_payload_and_marker(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "run"
            rr.initialize(Mock(directory=str(run), question="public",
                               recipient="Coordinator", max_chars=None))
            path = run / "bundle.json"
            record = run / "operator-reconciliation.json"
            config = {"GROK_BOT_WEBHOOK_URL": self.url, "GROK_BOT_WEBHOOK_KEY": self.key,
                      "GROK_BOT_WEBHOOK_ORIGIN": self.origin}
            with patch.dict(gw.os.environ, config), patch("sys.stdout", new_callable=io.StringIO):
                with patch.object(sys, "argv", ["grok_webhook", str(path)]), \
                        patch.object(gw, "send_once", return_value={"status": "unknown"}):
                    self.assertEqual(gw.main(), 75)
                prior = (run / ".grok-webhook-attempt.json").read_bytes()
                observed = json.loads(prior)
                valid = {"task_id": observed["task_id"],
                         "request_sha256": observed["request_sha256"],
                         "prior_marker_sha256": gw.sha(prior), "decision": "retry_once",
                         "observed_at": "2026-01-01T12:00:00+00:00",
                         "observation": "No run observed", "user_instruction": "Retry approved"}
                for change in ({"task_id": "other"}, {"request_sha256": "other"},
                               {"prior_marker_sha256": "other"}, {"decision": "automatic"},
                               {"observation": ""}, {"user_instruction": ""},
                               {"observed_at": "2026-01-01T12:00:00"}):
                    record.write_text(json.dumps({**valid, **change}))
                    with patch.object(sys, "argv", ["grok_webhook", str(path),
                                                    "--reconciled-retry", str(record)]), \
                            patch.object(gw, "send_once") as send, \
                            patch("sys.stderr", new_callable=io.StringIO):
                        self.assertEqual(gw.main(), 2)
                        send.assert_not_called()
                        self.assertFalse((run / ".grok-webhook-retry-attempt.json").exists())
                record.write_text(json.dumps(valid))
                with patch.object(sys, "argv", ["grok_webhook", str(path),
                                                "--reconciled-retry", str(record)]), \
                        patch.dict(gw.os.environ, {"GROK_BOT_WEBHOOK_ORIGIN": self.origin + ":443"}), \
                        patch.object(gw, "send_once") as send, \
                        patch("sys.stderr", new_callable=io.StringIO):
                    self.assertEqual(gw.main(), 2)
                    send.assert_not_called()


if __name__ == "__main__":
    unittest.main()
