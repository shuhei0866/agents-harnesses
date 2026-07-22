#!/usr/bin/env python3
"""Fail-open event normalization for agent harness hooks."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import math
import os
import secrets
import sys
import uuid
from typing import Any


EVENT_KINDS = {
    "SessionStart": "session.started",
    "UserPromptSubmit": "turn.prompted",
    "PostToolUse": "tool.completed",
    "Stop": "turn.completed",
}

MAX_INPUT_BYTES = 1024 * 1024

METRIC_NAMES = (
    "duration_ms",
    "duration_api_ms",
    "tool_duration_ms",
    "num_turns",
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "total_cost_usd",
)


def safe_string(value: Any) -> str | None:
    if not isinstance(value, str) or not value or len(value) > 256:
        return None
    return value


def hash_identifier(value: Any, key: bytes | None) -> str | None:
    text = safe_string(value)
    if text is None or key is None:
        return None
    digest = hmac.new(key, text.encode("utf-8"), hashlib.sha256).hexdigest()
    return f"sha256:{digest[:24]}"


def metric_value(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    if value < 0:
        return None
    return value


def metrics_from(payload: dict[str, Any]) -> dict[str, int | float] | None:
    nested = payload.get("metrics")
    sources = (payload, nested) if isinstance(nested, dict) else (payload,)
    metrics: dict[str, int | float] = {}
    for name in METRIC_NAMES:
        for source in sources:
            value = metric_value(source.get(name))
            if value is not None:
                metrics[name] = value
                break
    return metrics or None


def recorded_at() -> str:
    override = safe_string(os.environ.get("AGENT_FLIGHT_RECORDER_NOW"))
    if override is not None:
        try:
            parsed = dt.datetime.fromisoformat(override.replace("Z", "+00:00"))
            if parsed.tzinfo is not None:
                return override
        except ValueError:
            pass
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    return now.isoformat().replace("+00:00", "Z")


def destination() -> str | None:
    explicit = os.environ.get("AGENT_FLIGHT_RECORDER_PATH")
    if explicit:
        return explicit
    state_home = os.environ.get("XDG_STATE_HOME")
    if not state_home:
        home = os.environ.get("HOME")
        if not home:
            return None
        state_home = os.path.join(home, ".local", "state")
    return os.path.join(state_home, "agent-harness-flight-recorder", "events.jsonl")


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def correlation_key(event_path: str) -> bytes | None:
    override = os.environ.get("AGENT_FLIGHT_RECORDER_HASH_KEY")
    if override:
        return hashlib.sha256(override.encode("utf-8")).digest()

    key_path = os.environ.get("AGENT_FLIGHT_RECORDER_KEY_PATH")
    if not key_path:
        key_path = os.path.join(os.path.dirname(os.path.abspath(event_path)), "hash.key")
    parent = os.path.dirname(os.path.abspath(key_path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    descriptor = os.open(key_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.fchmod(descriptor, 0o600)
        existing = os.read(descriptor, 32)
        if len(existing) == 32:
            return existing
        key = secrets.token_bytes(32)
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        write_all(descriptor, key)
        return key
    finally:
        os.close(descriptor)


def normalize(
    payload: dict[str, Any], harness: str, key: bytes | None
) -> dict[str, Any]:
    source = safe_string(payload.get("hook_event_name"))
    known_source = source if source in EVENT_KINDS else "unknown"
    return {
        "schema_version": 1,
        "event_id": str(uuid.uuid4()),
        "recorded_at": recorded_at(),
        "harness": harness,
        "source_event": known_source,
        "event_kind": EVENT_KINDS.get(source, "hook.observed"),
        "session_id_hash": hash_identifier(payload.get("session_id"), key),
        "turn_id_hash": hash_identifier(payload.get("turn_id"), key),
        "workspace_id": hash_identifier(payload.get("cwd"), key),
        "model": safe_string(payload.get("model")),
        "permission_mode": safe_string(payload.get("permission_mode")),
        "tool": safe_string(payload.get("tool_name")),
        "metrics": metrics_from(payload),
        "outcome": None,
    }


def resolve_harness(requested: str) -> str:
    if requested != "auto":
        return requested
    # Codex sets PLUGIN_ROOT in addition to its Claude-compatible environment
    # variables. Payload fields overlap between the harnesses and are not a
    # reliable discriminator.
    if os.environ.get("PLUGIN_ROOT"):
        return "codex"
    return "claude-code"


def append_event(path: str, event: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    line = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    descriptor = os.open(path, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        write_all(descriptor, line)
    finally:
        os.close(descriptor)


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(
        "--harness", required=True, choices=("auto", "claude-code", "codex")
    )
    args, _ = parser.parse_known_args()

    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if not raw.strip():
        return
    if len(raw) > MAX_INPUT_BYTES:
        return
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        return
    path = destination()
    if path is None:
        return
    key = correlation_key(path)
    append_event(path, normalize(payload, resolve_harness(args.harness), key))


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
