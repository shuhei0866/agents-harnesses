import concurrent.futures
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from session_bridge.runner import Events, command, dispatch, status
from session_bridge.store import ACTIVE, Store


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, {"CODEX_HOME": str(Path(self.tmp.name) / "config"),
                                     "SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD": "10"})
        env.start()
        self.addCleanup(env.stop)
        self.store = Store(Path(self.tmp.name) / "state")
        self.session = self.store.create("partner", "codex")

    def test_concurrent_retry_starts_one_job(self):
        def reserve(_):
            return Store(self.store.root).reserve("partner", "hello", "request-1")
        with concurrent.futures.ThreadPoolExecutor(8) as pool:
            results = list(pool.map(reserve, range(8)))
        self.assertEqual(len({j["id"] for j, _ in results}), 1)
        self.assertEqual(sum(fresh for _, fresh in results), 1)
        with self.assertRaisesRegex(ValueError, "different prompt"):
            self.store.reserve("partner", "changed", "request-1")
        with self.assertRaisesRegex(ValueError, "busy"):
            self.store.reserve("partner", "next", "request-2")

    def test_persistence_native_identity_and_history(self):
        job, _ = self.store.reserve("partner", "remember", "one")
        native = "1caf260c-9241-4cbb-8e91-a633f467d416"
        self.store.set_native(self.session["id"], native)
        self.store.update(job["id"], status="completed", response="remembered")
        restored = Store(self.store.root)
        self.assertEqual(restored.session("partner")["native_id"], native)
        self.assertEqual(restored.history("partner")[0]["response"], "remembered")
        with self.assertRaisesRegex(ValueError, "different native"):
            restored.set_native(self.session["id"], "ce33c71e-b694-4b66-955f-fb7caad1b46b")

    def test_stale_worker_is_uncertain_and_blocks_new_sends(self):
        job, _ = self.store.reserve("partner", "hello", "one")
        with self.store.db() as db:
            db.execute("UPDATE jobs SET updated=0 WHERE id=?", (job["id"],))
        self.assertEqual(status(self.store, job["id"])["status"], "uncertain")
        with self.assertRaisesRegex(ValueError, "uncertain"):
            self.store.reserve("partner", "hello again", "two")

    def test_claude_is_error_overrides_success_subtype(self):
        session = self.store.create("claude", "claude")
        job, _ = self.store.reserve("claude", "hello", "one")
        events = Events(self.store, session, job["id"])
        events.accept({"type": "result", "subtype": "success", "is_error": True,
                       "result": "Invalid API key"})
        self.assertFalse(events.completed)
        self.assertEqual(events.error, "Invalid API key")

    def test_resume_keeps_id_and_sandbox(self):
        self.store.set_native(self.session["id"], "1caf260c-9241-4cbb-8e91-a633f467d416")
        with patch("shutil.which", return_value="/bin/codex"):
            args = command(self.store.session("partner"))
        self.assertIn("resume", args)
        self.assertIn("read-only", args)
        self.assertIn("1caf260c-9241-4cbb-8e91-a633f467d416", args)

    def test_claude_stream_progress_preserves_auth_mode_and_effort(self):
        session = self.store.create("claude", "claude", "example-model")
        with patch("shutil.which", return_value="/bin/claude"):
            args = command(session)
        self.assertIn("--include-partial-messages", args)
        self.assertIn("--safe-mode", args)
        self.assertNotIn("--bare", args)
        self.assertNotIn("--effort", args)

    def test_claude_ten_dollar_cap_keeps_restricted_command_and_resume(self):
        session = self.store.create("claude-budget", "claude", "example-model")
        native = "1caf260c-9241-4cbb-8e91-a633f467d416"
        self.store.set_native(session["id"], native)
        with patch("shutil.which", return_value="/bin/claude"):
            args = command(self.store.session("claude-budget"))
        self.assertEqual(args, [
            "/bin/claude", "--safe-mode", "-p", "--tools", "", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-mode", "dontAsk",
            "--max-budget-usd", "10", "--resume", native, "--model", "example-model",
        ])

    def test_progress_counts_without_persisting_thinking_or_partial_answer(self):
        session = self.store.create("claude", "claude")
        job, _ = self.store.reserve("claude", "hello", "one")
        self.assertEqual(job["timeout"], 600)
        events = Events(self.store, session, job["id"])
        events.accept({"type": "system", "subtype": "init"})
        events.accept({"type": "stream_event", "event": {"type": "message_start"}})
        events.accept({"type": "stream_event", "event": {"type": "content_block_delta",
                      "delta": {"type": "thinking_delta", "thinking": "PRIVATE_REASONING_SENTINEL"}}})
        events.accept({"type": "stream_event", "event": {"type": "content_block_delta",
                      "delta": {"type": "text_delta", "text": "PARTIAL_ANSWER_SENTINEL"}}})
        events.flush(force=True)
        public = self.store.public_job(job["id"])
        self.assertEqual(public["progress"]["thinking_deltas"], 1)
        self.assertEqual(public["progress"]["answer_chars"], len("PARTIAL_ANSWER_SENTINEL"))
        self.assertEqual(public["progress"]["phase"], "writing")
        self.assertEqual(public["response"], "")
        self.assertFalse(events.completed)
        self.assertNotIn("SENTINEL", json.dumps(public))
        self.assertNotIn(b"SENTINEL", (self.store.root / "registry.sqlite3").read_bytes())
        events.accept({"type": "result", "subtype": "success", "is_error": False, "result": "final"})
        self.assertEqual(self.store.public_job(job["id"])["response"], "final")

    def test_heartbeat_does_not_advance_provider_progress(self):
        job, _ = self.store.reserve("partner", "hello", "one")
        events = Events(self.store, self.session, job["id"])
        events.accept({"type": "thread.started", "thread_id": "1caf260c-9241-4cbb-8e91-a633f467d416"})
        before = self.store.progress(job["id"])
        self.store.update(job["id"])
        self.assertEqual(before, self.store.progress(job["id"]))

    def test_claude_partial_stream_timeout_and_missing_result_never_succeed(self):
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        executable = bindir / "claude"
        executable.write_text('''#!/usr/bin/env python3
import json, sys, time
prompt = sys.stdin.read()
def emit(data):
    print(json.dumps(data), flush=True)
emit({"type":"system", "subtype":"init", "session_id":"1caf260c-9241-4cbb-8e91-a633f467d416"})
emit({"type":"stream_event", "event":{"type":"content_block_delta", "delta":{"type":"thinking_delta", "thinking":"DO_NOT_STORE_THIS"}}})
emit({"type":"stream_event", "event":{"type":"content_block_delta", "delta":{"type":"text_delta", "text":"unfinished"}}})
if "timeout-test" in prompt:
    time.sleep(60)
''')
        executable.chmod(0o755)
        self.store.create("claude", "claude")
        with patch.dict(os.environ, {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}):
            for prompt, expected in [("timeout-test", "timed_out"), ("missing-result", "failed")]:
                job = dispatch(self.store, "claude", prompt, prompt, 5)
                until = time.monotonic() + 12
                while time.monotonic() < until:
                    current = status(self.store, job["id"])
                    if current["status"] not in ACTIVE:
                        break
                    time.sleep(0.05)
                self.assertEqual(current["status"], expected, current)
                self.assertEqual(current["response"], "")
                self.assertEqual(current["progress"]["thinking_deltas"], 1)
                self.assertEqual(current["progress"]["phase"], "writing")
                if expected == "timed_out":
                    self.assertIn("exceeded 5s", current["error"])
                    self.assertIn("thinking_deltas=1", current["error"])
                repeat = dispatch(self.store, "claude", prompt, prompt, 5)
                self.assertEqual(repeat["id"], job["id"])
                self.assertEqual(repeat["status"], expected)

    def test_worker_completion_failure_and_interrupt(self):
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        executable = bindir / "codex"
        executable.write_text('''#!/usr/bin/env python3
import json, sys, time
prompt = sys.stdin.read()
print(json.dumps({"type":"thread.started", "thread_id":"1caf260c-9241-4cbb-8e91-a633f467d416"}), flush=True)
if "sleep-test" in prompt or "timeout-test" in prompt:
    time.sleep(60)
if "failure-test" in prompt:
    print(json.dumps({"type":"turn.failed","error":{"message":"provider failed"}}), flush=True)
    sys.exit(1)
if "missing-result" not in prompt:
    print(json.dumps({"type":"item.completed", "item":{"type":"agent_message","text":"OK"}}), flush=True)
    print(json.dumps({"type":"turn.completed"}), flush=True)
''')
        executable.chmod(0o755)
        env = {"PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
        with patch.dict(os.environ, env):
            for i, (prompt, expected) in enumerate((("hello", "completed"), ("failure-test", "failed"),
                                                    ("missing-result", "failed"), ("sleep-test", "interrupted"),
                                                    ("timeout-test", "timed_out"))):
                job = dispatch(self.store, "partner", prompt, str(i), 5)
                until = time.monotonic() + 12
                while time.monotonic() < until:
                    current = status(self.store, job["id"])
                    if prompt == "sleep-test" and current["status"] == "running":
                        self.store.update(job["id"], cancel=1)
                    if current["status"] not in ACTIVE:
                        break
                    time.sleep(0.05)
                self.assertEqual(current["status"], expected, current)
                if expected == "timed_out":
                    self.assertIn("exceeded 5s", current["error"])

    def test_missing_native_identity_fails_and_unread_stdin_times_out(self):
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        executable = bindir / "codex"
        executable.write_text("""#!/usr/bin/env python3
import json, os, time
if os.environ.get("BRIDGE_TEST_MODE") == "no-read":
    time.sleep(60)
else:
    print(json.dumps({"type":"turn.completed"}), flush=True)
""")
        executable.chmod(0o755)
        for mode, expected in (("no-id", "failed"), ("no-read", "timed_out")):
            env = {"PATH": str(bindir) + os.pathsep + os.environ["PATH"], "BRIDGE_TEST_MODE": mode}
            with patch.dict(os.environ, env):
                job = dispatch(self.store, "partner", "界" * 32000, mode, 5)
                until = time.monotonic() + 12
                while time.monotonic() < until:
                    current = status(self.store, job["id"])
                    if current["status"] not in ACTIVE:
                        break
                    time.sleep(0.05)
                self.assertEqual(current["status"], expected, current)
                if mode == "no-id":
                    self.assertIn("native session ID", current["error"])


if __name__ == "__main__":
    unittest.main()
