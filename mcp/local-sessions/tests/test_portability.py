import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from session_bridge.runner import Events, claude_budget, command
from session_bridge.store import Store, default_state_root


class PortabilityTests(unittest.TestCase):
    def test_state_defaults_outside_package_and_obeys_explicit_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(os.environ, {"XDG_DATA_HOME": tmp, "SESSION_BRIDGE_HOME": ""}):
                self.assertEqual(default_state_root(), Path(tmp) / "local-session-bridge")
            with patch.dict(os.environ, {"SESSION_BRIDGE_HOME": str(Path(tmp) / "chosen")}):
                self.assertEqual(default_state_root(), Path(tmp) / "chosen")
            with patch.dict(os.environ, {"SESSION_BRIDGE_HOME": "relative"}):
                with self.assertRaisesRegex(ValueError, "absolute"):
                    default_state_root()
            with patch.dict(os.environ, {"XDG_DATA_HOME": "relative", "SESSION_BRIDGE_HOME": ""}):
                self.assertEqual(default_state_root(), Path.home() / ".local/share/local-session-bridge")

    def test_budget_is_explicit_finite_and_positive(self):
        for value in ("0", "-1", "nan", "inf", "not-a-number", ""):
            with self.subTest(value=value), patch.dict(os.environ, {"SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD": value}):
                with self.assertRaisesRegex(ValueError, "positive and finite"):
                    claude_budget()
        with patch.dict(os.environ, {"SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD": "0.5"}):
            self.assertEqual(claude_budget(), "0.5")

    def test_codex_only_inherits_model_and_auth_preferences(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "config.toml").write_text(
                'model="example-model"\nmodel_reasoning_effort="medium"\n'
                'cli_auth_credentials_store="file"\n[mcp_servers.recursive]\ncommand="unsafe"\n'
            )
            with patch.dict(os.environ, {"CODEX_HOME": tmp}), patch("shutil.which", return_value="/bin/codex"):
                args = command({"provider": "codex", "model": None, "native_id": None})
            self.assertIn("example-model", args)
            self.assertIn("--ignore-user-config", args)
            self.assertIn("read-only", args)
            self.assertNotIn("unsafe", " ".join(args))

    def test_native_id_must_be_observed_even_on_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = Store(tmp)
            session = store.create("partner", "codex")
            job, _ = store.reserve("partner", "hello", "one")
            events = Events(store, session, job["id"])
            events.accept({"type": "turn.completed"})
            self.assertFalse(events.native_id_observed)
            events.accept({"type": "thread.started", "thread_id": "00000000-0000-4000-8000-000000000001"})
            self.assertTrue(events.native_id_observed)


if __name__ == "__main__":
    unittest.main()
