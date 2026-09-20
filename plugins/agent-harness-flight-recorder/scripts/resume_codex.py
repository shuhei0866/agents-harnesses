"""Isolated Codex adapter for offline proposal evaluation, without enabled tools."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import tomllib

TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
DISABLED_FEATURES = (
    "shell_tool", "unified_exec", "apps", "plugins", "memories", "chronicle",
    "multi_agent", "browser_use", "browser_use_external", "computer_use",
    "view_image", "image_generation", "hooks", "code_mode_host", "skill_search",
    "sleep_tool", "workspace_dependencies",
)


def _model_preference():
    # Read only the explicit top-level model preference; never forward configuration.
    path = Path.home() / ".codex" / "config.toml"
    try:
        with path.open("rb") as stream:
            value = tomllib.load(stream).get("model")
    except FileNotFoundError:
        return None
    if value is not None and (not isinstance(value, str) or not value.strip() or len(value) > 256):
        raise ValueError("invalid_model_preference")
    return value



def _auth_store_preference():
    path=Path.home()/'.codex/config.toml'
    try:
        with path.open('rb') as stream:value=tomllib.load(stream).get('cli_auth_credentials_store','auto')
    except FileNotFoundError:value='auto'
    if value not in ('auto','file','keyring'):raise ValueError('invalid_auth_store_preference')
    return value


def _cli_version(executable):
    try:
        result = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError):
        raise ValueError("codex_version_unavailable") from None
    return result.stdout.strip()[:256]


def build_codex_argv(executable, schema_path, result_path, token_budget, model=None):
    if type(token_budget) is not int or token_budget < 1:
        raise ValueError("positive_integer_token_budget_required")
    argv = [executable, "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--json", "--output-schema", str(schema_path),
            "--output-last-message", str(result_path)]
    for feature in DISABLED_FEATURES:
        argv += ["--disable", feature]
    argv += ["--enable", "skip_host_skill_discovery", "-c", "project_doc_max_bytes=0",
             "-c", 'web_search="disabled"', "-c", f"model_max_output_tokens={min(token_budget, 2000)}"]
    if model:
        argv += ["--model", model]
    return argv + ["-"]


def _bounded_json(path):
    with path.open("rb") as stream:
        raw = stream.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("codex_response_too_large_unknown_usage")
    return raw


def parse_events(raw):
    usage = None
    started = False
    startup_warnings = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            raise ValueError("invalid_codex_event_unknown_usage") from None
        if not isinstance(event, dict):
            raise ValueError("invalid_codex_event_unknown_usage")
        kind = event.get("type")
        if kind in ("item.started", "item.updated", "item.completed"):
            item = event.get("item")
            if isinstance(item,dict) and item.get("type")=="error" and not started:
                startup_warnings += 1
                continue
            if not isinstance(item, dict) or item.get("type") not in ("agent_message", "reasoning"):
                raise ValueError("unexpected_tool_or_item_unknown_usage")
        elif kind == "turn.completed":
            if usage is not None:
                raise ValueError("multiple_turns_unknown_usage")
            usage = event.get("usage")
            if not isinstance(usage, dict) or any(type(usage.get(key)) is not int or usage[key] < 0 for key in ("input_tokens", "cached_input_tokens", "output_tokens")):
                raise ValueError("invalid_or_missing_usage")
            if usage["cached_input_tokens"] > usage["input_tokens"]:
                raise ValueError("invalid_cached_usage")
        elif kind == "turn.started":
            started = True
        elif kind != "thread.started":
            raise ValueError("unexpected_event_unknown_usage")
    if usage is None:
        raise ValueError("missing_completed_turn_usage")
    return dict({key: usage[key] for key in ("input_tokens", "cached_input_tokens", "output_tokens")},startup_warnings=startup_warnings)


def call_codex(prompt, schema, token_budget, *, model=None):
    """Run a single bounded proposal; cumulative token gating belongs to caller.

    Output tokens are capped; actual input usage is observable only after execution.
    Subscription usage has no dollar quote, so reported_cost_usd remains unknown.
    """
    if not isinstance(prompt, str) or not prompt.strip() or not isinstance(schema, dict):
        raise ValueError("invalid_codex_request")
    executable = shutil.which("codex")
    if not executable:
        raise ValueError("codex_cli_unavailable")
    model, version = model or _model_preference(), _cli_version(executable)
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="resume-codex-") as temporary:
        directory = Path(temporary)
        cwd = directory / "empty"
        cwd.mkdir(mode=0o700)
        schema_path, result_path, events_path = (directory / name for name in ("schema.json", "result.json", "events.jsonl"))
        schema_path.write_text(json.dumps(schema))
        argv = build_codex_argv(executable, schema_path, result_path, token_budget, model)
        argv[-1:-1] = ["-c", "cli_auth_credentials_store="+json.dumps(_auth_store_preference())]
        with events_path.open("wb") as stream:
            process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=stream, stderr=subprocess.DEVNULL,
                                       cwd=str(cwd), start_new_session=True, close_fds=True)
            try:
                process.communicate(prompt.encode(), timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise ValueError("codex_timeout_unknown_usage") from None
        if process.returncode:
            raise ValueError("codex_failed_unknown_usage")
        usage = parse_events(_bounded_json(events_path))
        try:
            value = json.loads(_bounded_json(result_path))
        except (OSError, ValueError):
            raise ValueError("invalid_codex_structured_result") from None
        if not isinstance(value, dict):
            raise ValueError("codex_structured_result_must_be_object")
    metrics = dict(usage, elapsed_ms=round((time.monotonic() - started) * 1000),
                   reported_cost_usd=None, model=model, cli_version=version,
                   model_identity="configured_preference" if model else "cli_default_unresolved",
                   provider="codex", token_budget_exceeded=usage["input_tokens"] + usage["output_tokens"] > token_budget)
    return {"value": value, "metrics": metrics, "is_error": False}
