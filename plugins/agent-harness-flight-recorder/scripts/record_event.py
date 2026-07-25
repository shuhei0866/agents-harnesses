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
import re
import secrets
import selectors
import stat
import subprocess
import sys
import time
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


def hash_relationship_identifier(
    value: Any, key: bytes | None, domain: str
) -> str | None:
    text = safe_string(value)
    if text is None or key is None:
        return None
    digest = hmac.new(
        key,
        b"agent-harness-flight-recorder/relationship-v1\0"
        + domain.encode("ascii")
        + b"\0"
        + text.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return f"sha256:{digest[:24]}"


MAX_CHANGED_FILES = 128
MAX_GIT_OUTPUT_BYTES = 64 * 1024
GIT_TIMEOUT_SECONDS = 0.075
CHANGED_FILE_SUFFIXES = {
    ".c", ".cc", ".cpp", ".css", ".go", ".h", ".hpp", ".html", ".java",
    ".js", ".json", ".jsx", ".kt", ".md", ".mjs", ".py", ".rb", ".rs",
    ".sh", ".sql", ".swift", ".toml", ".ts", ".tsx", ".yaml", ".yml",
}
SECRET_PATH_PARTS = {
    ".git", ".env", ".ssh", "__pycache__", "build", "coverage", "dist",
    "keys", "node_modules", "secrets", "target", "vendor",
}
ISSUE_TOKEN_RE = re.compile(
    r"(?<![A-Za-z0-9])([A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,8})(?![A-Za-z0-9])"
)


def allowlisted_changed_path(value: object) -> str | None:
    path = safe_string(value)
    if (
        path is None
        or path.startswith(("/", "\\"))
        or any(ord(character) < 32 for character in path)
    ):
        return None
    normalized = path.replace("\\", "/")
    parts = normalized.split("/")
    if (
        len(parts) > 32
        or any(
            not part
            or part in (".", "..")
            or part.startswith(".")
            or part.lower() in SECRET_PATH_PARTS
            for part in parts
        )
    ):
        return None
    suffix = os.path.splitext(normalized)[1].lower()
    if suffix not in CHANGED_FILE_SUFFIXES and parts[-1] not in (
        "Dockerfile", "Makefile"
    ):
        return None
    return normalized


def _run_git_bounded(
    path: str, arguments: list[str], deadline: float
) -> tuple[int, bytes] | None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return None
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "LC_ALL": "C",
        }
    )
    process = subprocess.Popen(
        ["git", "-C", path, *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        shell=False,
        env=environment,
    )
    assert process.stdout is not None
    descriptor = process.stdout.fileno()
    os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(descriptor, selectors.EVENT_READ)
    output = bytearray()
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                process.kill()
                process.wait()
                return None
            ready = selector.select(remaining)
            if not ready:
                process.kill()
                process.wait()
                return None
            chunk = os.read(
                descriptor,
                min(8192, MAX_GIT_OUTPUT_BYTES + 1 - len(output)),
            )
            if chunk:
                output.extend(chunk)
                if len(output) > MAX_GIT_OUTPUT_BYTES:
                    process.kill()
                    process.wait()
                    return None
                continue
            return process.wait(), bytes(output)
    finally:
        selector.close()
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()


def _git_relationship_metadata(cwd: object) -> tuple[str | None, list[str], str]:
    """Collect bounded repository metadata without ever making recording fail."""
    path = safe_string(cwd)
    if path is None or not os.path.isabs(path):
        return None, [], "missing"
    try:
        result = _run_git_bounded(
            path,
            [
                "status", "--porcelain=v1", "-z", "--branch",
                "--untracked-files=all", "--no-renames",
            ],
            time.monotonic() + GIT_TIMEOUT_SECONDS * 2,
        )
        if result is None or result[0] != 0:
            return None, [], "missing"
        items = result[1].decode("utf-8").split("\0")
        branch_value = None
        if items and items[0].startswith("## "):
            branch_text = items.pop(0)[3:]
            if branch_text.startswith("No commits yet on "):
                branch_text = branch_text.removeprefix("No commits yet on ")
            elif branch_text.startswith("Initial commit on "):
                branch_text = branch_text.removeprefix("Initial commit on ")
            branch_text = branch_text.split("...", 1)[0]
            if branch_text not in ("HEAD (no branch)", "HEAD"):
                branch_value = safe_string(branch_text)
        names: list[str] = []
        for item in items:
            if not item:
                continue
            name = item[3:] if len(item) >= 4 else ""
            candidate = allowlisted_changed_path(name)
            if candidate is not None:
                names.append(candidate)
        names = sorted(set(names))
        state = "truncated" if len(names) > MAX_CHANGED_FILES else "complete"
        return branch_value, names[:MAX_CHANGED_FILES], state
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None, [], "missing"


def relationship_context(
    payload: dict[str, Any], key: bytes | None
) -> dict[str, Any]:
    task = next(
        (
            value
            for field in ("task_id", "issue_id")
            if (value := safe_string(payload.get(field))) is not None
        ),
        None,
    )
    task_source = "payload" if task is not None else None
    if task is None:
        for field in (
            "FLIGHT_RECORDER_TASK_ID", "LINEAR_ISSUE_ID", "GITHUB_ISSUE"
        ):
            value = safe_string(os.environ.get(field))
            if value is not None:
                task, task_source = value, "env"
                break
    branch = safe_string(payload.get("branch_or_worktree"))
    supplied_files = payload.get("changed_files")
    files: list[str] | None = None
    files_state = "missing"
    if isinstance(supplied_files, list):
        values = [
            allowed
            for item in supplied_files
            if (allowed := allowlisted_changed_path(item)) is not None
        ]
        files = sorted(set(values))
        files_state = (
            "truncated" if len(files) > MAX_CHANGED_FILES else "complete"
        )
        files = files[:MAX_CHANGED_FILES]
    if branch is None or files is None:
        git_branch, git_files, git_state = _git_relationship_metadata(
            payload.get("cwd")
        )
        if branch is None:
            branch = git_branch
        if files is None:
            files, files_state = git_files, git_state
    if task is None and branch is not None:
        candidates = sorted(set(ISSUE_TOKEN_RE.findall(branch)))
        if len(candidates) == 1:
            task, task_source = candidates[0], "branch"
    fingerprints = sorted(
        fingerprint
        for item in files
        if (
            fingerprint := hash_relationship_identifier(
                item, key, "changed_file"
            )
        ) is not None
    )
    if key is None:
        files_state = "missing"
    task_hash = hash_relationship_identifier(task, key, "task")
    return {
        "task_id_hash": task_hash,
        "task_source": task_source if task_hash is not None else None,
        "branch_or_worktree_id": hash_relationship_identifier(
            branch, key, "branch_or_worktree"
        ),
        "changed_file_fingerprints": fingerprints,
        "changed_files_state": files_state,
    }


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
    vault_root = os.environ.get("FLIGHT_RECORDER_STATE_DIR")
    if vault_root:
        normalized_root = os.path.expanduser(vault_root)
        if not os.path.isabs(normalized_root):
            return None
        return os.path.join(normalized_root, "inbox", "events.jsonl")
    state_home = os.environ.get("XDG_STATE_HOME")
    if not state_home:
        home = os.environ.get("HOME")
        if not home:
            return None
        state_home = os.path.join(home, ".local", "state")
    return os.path.join(
        state_home, "agent-harness-flight-recorder", "inbox", "events.jsonl"
    )


def write_all(descriptor: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("short write")
        view = view[written:]


def fsync_directory(path: str) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def correlation_key(event_path: str) -> bytes | None:
    override = os.environ.get("AGENT_FLIGHT_RECORDER_HASH_KEY")
    if override:
        return hashlib.sha256(override.encode("utf-8")).digest()

    key_path = os.environ.get("AGENT_FLIGHT_RECORDER_KEY_PATH")
    if not key_path:
        vault_root = os.environ.get("FLIGHT_RECORDER_STATE_DIR")
        if vault_root:
            key_path = os.path.join(vault_root, "hash.key")
        elif not os.environ.get("AGENT_FLIGHT_RECORDER_PATH"):
            # The managed XDG/HOME destination is <vault>/inbox/events.jsonl,
            # while the Vault-wide key intentionally remains at <vault>/hash.key.
            key_path = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(event_path))),
                "hash.key",
            )
        else:
            key_path = os.path.join(
                os.path.dirname(os.path.abspath(event_path)), "hash.key"
            )
    parent = os.path.dirname(os.path.abspath(key_path))
    os.makedirs(parent, mode=0o700, exist_ok=True)
    created = False
    safe_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | getattr(
        os, "O_NOFOLLOW", 0
    )
    try:
        descriptor = os.open(key_path, safe_flags | os.O_CREAT | os.O_EXCL, 0o600)
        created = True
    except FileExistsError:
        descriptor = os.open(key_path, safe_flags)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.fchmod(descriptor, 0o600)
        existing = os.read(descriptor, 33)
        if len(existing) == 32:
            return existing
        # Never replace an existing malformed key: it may be the local half of
        # an encrypted Vault whose envelope would then diverge. Recording stays
        # fail-open without correlated identifiers until the user repairs it.
        if not created:
            return None
        key = secrets.token_bytes(32)
        os.lseek(descriptor, 0, os.SEEK_SET)
        os.ftruncate(descriptor, 0)
        write_all(descriptor, key)
        os.fsync(descriptor)
        return key
    finally:
        os.close(descriptor)
        if created:
            fsync_directory(parent)


def normalize(
    payload: dict[str, Any], harness: str, key: bytes | None
) -> dict[str, Any]:
    source = safe_string(payload.get("hook_event_name"))
    known_source = source if source in EVENT_KINDS else "unknown"
    event = {
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
    # New writes are Event v2. Event v1 remains reader/chunk compatible.
    event["schema_version"] = 2
    event["relationship_context"] = relationship_context(payload, key)
    return event


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
    absolute_path = os.path.abspath(path)
    parent = os.path.dirname(absolute_path)
    data_name = os.path.basename(absolute_path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    line = (json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(parent, directory_flags)
    lock_flags = os.O_CREAT | os.O_RDWR
    lock_flags |= getattr(os, "O_CLOEXEC", 0)
    lock_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        lock_descriptor = os.open(
            "events.lock", lock_flags, 0o600, dir_fd=parent_descriptor
        )
    except BaseException:
        os.close(parent_descriptor)
        raise
    try:
        lock_metadata = os.fstat(lock_descriptor)
        if (
            not stat.S_ISREG(lock_metadata.st_mode)
            or lock_metadata.st_nlink != 1
            or lock_metadata.st_uid != os.geteuid()
        ):
            raise OSError("unsafe event lock")
        os.fchmod(lock_descriptor, 0o600)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        data_flags = os.O_APPEND | os.O_WRONLY
        data_flags |= getattr(os, "O_CLOEXEC", 0)
        data_flags |= getattr(os, "O_NOFOLLOW", 0)
        created = False
        try:
            descriptor = os.open(
                data_name,
                data_flags | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=parent_descriptor,
            )
            created = True
        except FileExistsError:
            descriptor = os.open(data_name, data_flags, dir_fd=parent_descriptor)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid():
                raise OSError("unsafe event file")
            os.fchmod(descriptor, 0o600)
            write_all(descriptor, line)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if created:
            os.fsync(parent_descriptor)
    finally:
        os.close(lock_descriptor)
        os.close(parent_descriptor)


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
