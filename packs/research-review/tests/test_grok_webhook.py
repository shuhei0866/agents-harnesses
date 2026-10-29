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
                              (self.url, ""), (self.url, "key\nInjected: value")):
            result = self.send(endpoint=endpoint, key=key, opener=opener)
            self.assertEqual(result["status"], "not_sent")
        opener.open.assert_not_called()

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


if __name__ == "__main__":
    unittest.main()
