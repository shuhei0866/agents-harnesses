import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import resume_codex as adapter


class CodexAdapterTests(unittest.TestCase):
    def events(self):
        return [{"type": "thread.started", "thread_id": "synthetic"}, {"type": "turn.started"},
                {"type": "item.completed", "item": {"type": "agent_message", "text": '{"ok":true}'}},
                {"type": "turn.completed", "usage": {"input_tokens": 100, "cached_input_tokens": 20, "output_tokens": 15}}]

    def invoke(self, events=None, timeout=False):
        rows = self.events() if events is None else events
        captured = {}

        class FakeProcess:
            pid = 987654
            returncode = 0

            def __init__(self, argv, **kwargs):
                captured.update(argv=argv, kwargs=kwargs)
                Path(argv[argv.index("--output-last-message") + 1]).write_text('{"ok":true}')
                kwargs["stdout"].write(("\n".join(json.dumps(row) for row in rows) + "\n").encode())

            def communicate(self, data, timeout=None):
                captured["prompt"] = data
                if timeout and captured.get("timeout_test"):
                    raise subprocess.TimeoutExpired("codex", timeout)

            def wait(self):
                return 0

        captured["timeout_test"] = timeout
        with patch.object(adapter.shutil, "which", return_value="/synthetic/codex"), \
             patch.object(adapter, "_model_preference", return_value="configured-model"), \
             patch.object(adapter, "_auth_store_preference", return_value="keyring"), \
             patch.object(adapter, "_cli_version", return_value="codex synthetic"), \
             patch.object(adapter.subprocess, "Popen", FakeProcess), \
             patch.object(adapter.os, "killpg") as killed:
            if timeout:
                with self.assertRaisesRegex(ValueError, "timeout_unknown_usage"):
                    adapter.call_codex("synthetic prompt", {"type": "object"}, 5000)
                killed.assert_called_once()
                return None, captured
            return adapter.call_codex("synthetic prompt", {"type": "object"}, 5000), captured

    def test_isolated_tool_free_argv_and_real_usage(self):
        result, captured = self.invoke()
        argv = captured["argv"]
        for flag in ("--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--json"):
            self.assertIn(flag, argv)
        for feature in adapter.DISABLED_FEATURES:
            self.assertIn(["--disable", feature], [argv[i:i + 2] for i in range(len(argv) - 1)])
        self.assertEqual(argv[argv.index("--sandbox") + 1], "read-only")
        self.assertEqual(argv[argv.index("--model") + 1], "configured-model")
        self.assertTrue(captured["kwargs"]["start_new_session"])
        self.assertEqual(captured["prompt"], b"synthetic prompt")
        self.assertEqual(result["value"], {"ok": True})
        self.assertEqual(result["metrics"]["input_tokens"], 100)
        self.assertEqual(result["metrics"]["cached_input_tokens"], 20)
        self.assertEqual(result["metrics"]["output_tokens"], 15)
        self.assertIsNone(result["metrics"]["reported_cost_usd"])
        self.assertEqual(result["metrics"]["model"], "configured-model")
        self.assertEqual(result["metrics"]["cli_version"], "codex synthetic")

    def test_tool_execution_or_unknown_event_fails_closed(self):
        for event in ({"type": "item.started", "item": {"type": "command_execution"}}, {"type": "unknown.event"}):
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.invoke(self.events()[:-1] + [event] + self.events()[-1:])

    def test_missing_or_invalid_usage_is_not_zero(self):
        for usage in ({}, {"input_tokens": True, "cached_input_tokens": 0, "output_tokens": 1}):
            events = self.events()
            events[-1]["usage"] = usage
            with self.assertRaisesRegex(ValueError, "usage"):
                self.invoke(events)

    def test_timeout_kills_group_and_reports_unknown_usage(self):
        self.invoke(timeout=True)


    def test_startup_warning_is_counted_but_in_turn_error_rejected(self):
        event={'type':'item.completed','item':{'type':'error','message':'startup warning'}}
        result,_=self.invoke([event]+self.events())
        self.assertEqual(result['metrics']['startup_warnings'],1)
        with self.assertRaises(ValueError):self.invoke(self.events()[:-1]+[event]+self.events()[-1:])


if __name__ == "__main__":
    unittest.main()
