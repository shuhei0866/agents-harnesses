#!/usr/bin/env python3
"""Local, hook-assisted automatic Semantic Receipt generation."""

from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import stat
from pathlib import Path
from typing import Any, Iterator

from chunk_rotation import canonical_json, safe_subdirectory
from record_event import hash_identifier
from semantic_receipts import (
    _load_rubric,
    _prepare_receipt,
    _store_prepared_receipt,
    _validate_prepared_record,
    _validate_prepared_receipt,
    load_semantic_receipts,
)
from evaluation import BUNDLED_EVALUATORS, _executable_identity
from session_sources import register
from vault import (
    VaultError,
    atomic_replace,
    authorized_key,
    ensure_managed_gitignore,
    ensure_safe_existing_root,
    load_config as load_vault_config,
    vault_lock,
)


CONFIG_PATH = Path("receipt-automation/config.json")
HINTS_PATH = Path("receipt-automation/hints.jsonl")
ATTEMPTS_PATH = Path("receipt-automation/attempts.json")
STATUS_PATH = Path("receipt-automation/status.json")
LOCK_PATH = Path("receipt-automation/run.lock")
CONFIG_FIELDS = {
    "schema_version",
    "enabled",
    "claude_code_root",
    "codex_root",
    "evaluator",
    "model",
    "rubric_path",
    "policy_version",
    "quiescence_seconds",
    "max_receipts_per_run",
    "max_cost_microusd_per_run",
}
MAX_QUIESCENCE_SECONDS = 30 * 24 * 60 * 60
MAX_RECEIPTS_PER_RUN = 100
MAX_COST_MICROUSD_PER_RUN = 1_000_000_000_000
MAX_SOURCE_PREFIX_BYTES = 64 * 1024 * 1024
MAX_SOURCE_LINES = 200_000
MAX_HINTS_BYTES = 64 * 1024 * 1024
MAX_HINTS = 100_000
HINT_COMPACTION_THRESHOLD = 100
MAX_STATE_BYTES = 32 * 1024 * 1024
MAX_ATTEMPTS = 100_000
# A prepared Receipt is capped at 128 KiB; its snapshot duplicates the bounded
# source IDs and may additionally contain 10,000 evidence digests. Four MiB is
# a conservative ceiling for that legal envelope. The validator enforces and
# the provider preflight reserves this same ceiling.
MAX_PREPARED_ATTEMPT_BYTES = 4 * 1024 * 1024
FINGERPRINT_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
AUTOMATION_STATES = {"idle", "completed", "attention", "error"}
DIAGNOSTIC_CODES = {None, "configuration_invalid", "evaluator_failed"}
DEFAULT_EVALUATOR_TIMEOUT_SECONDS = 60
BUNDLED_EVALUATOR_TIMEOUT_SECONDS = 240


def _evaluator_timeout_seconds(evaluator_path: Path) -> int:
    bundled_directory = Path(__file__).resolve().parent
    bundled_paths = {
        (bundled_directory / evaluator).resolve()
        for evaluator in BUNDLED_EVALUATORS
    }
    if evaluator_path in bundled_paths:
        return BUNDLED_EVALUATOR_TIMEOUT_SECONDS
    return DEFAULT_EVALUATOR_TIMEOUT_SECONDS


def _absolute_directory(path: Path, description: str) -> Path:
    selected = path.expanduser()
    if not selected.is_absolute() or selected.is_symlink():
        raise VaultError(f"{description} must be a safe absolute directory")
    try:
        resolved = selected.resolve(strict=True)
        metadata = resolved.lstat()
    except OSError as error:
        raise VaultError(f"{description} must be a safe absolute directory") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
    ):
        raise VaultError(f"{description} must be a safe absolute directory")
    return selected.absolute()


def _absolute_file(path: Path, description: str) -> Path:
    selected = path.expanduser()
    if not selected.is_absolute() or selected.is_symlink():
        raise VaultError(f"{description} must be a safe absolute file")
    try:
        resolved = selected.resolve(strict=True)
        metadata = resolved.lstat()
    except OSError as error:
        raise VaultError(f"{description} must be a safe absolute file") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
    ):
        raise VaultError(f"{description} must be a safe absolute file")
    return selected.absolute()


def _validate_config(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != CONFIG_FIELDS
        or value.get("schema_version") != 1
        or value.get("enabled") is not True
    ):
        raise VaultError("receipt automation config is invalid")
    for field in ("claude_code_root", "codex_root", "rubric_path"):
        item = value.get(field)
        if not isinstance(item, str) or not Path(item).is_absolute():
            raise VaultError("receipt automation config is invalid")
    for field in ("evaluator", "model", "policy_version"):
        item = value.get(field)
        if (
            not isinstance(item, str)
            or not item
            or len(item) > 256
            or any(character in item for character in "\r\n\0")
        ):
            raise VaultError("receipt automation config is invalid")
    quiescence = value.get("quiescence_seconds")
    maximum = value.get("max_receipts_per_run")
    cost = value.get("max_cost_microusd_per_run")
    if (
        isinstance(quiescence, bool)
        or not isinstance(quiescence, int)
        or not 0 <= quiescence <= MAX_QUIESCENCE_SECONDS
        or isinstance(maximum, bool)
        or not isinstance(maximum, int)
        or not 1 <= maximum <= MAX_RECEIPTS_PER_RUN
        or isinstance(cost, bool)
        or not isinstance(cost, int)
        or not 0 <= cost <= MAX_COST_MICROUSD_PER_RUN
    ):
        raise VaultError("receipt automation limits are invalid")
    return value


def configure(
    root: Path,
    claude_code_root: Path,
    codex_root: Path,
    evaluator: str,
    model: str,
    rubric_path: Path,
    policy_version: str,
    quiescence_seconds: int,
    max_receipts_per_run: int,
    max_cost_microusd_per_run: int,
) -> dict[str, Any]:
    ensure_safe_existing_root(root)
    load_vault_config(root)
    config = _validate_config(
        {
            "schema_version": 1,
            "enabled": True,
            "claude_code_root": str(
                _absolute_directory(claude_code_root, "Claude Code root")
            ),
            "codex_root": str(_absolute_directory(codex_root, "Codex root")),
            "evaluator": evaluator,
            "model": model,
            "rubric_path": str(_absolute_file(rubric_path, "receipt rubric")),
            "policy_version": policy_version,
            "quiescence_seconds": quiescence_seconds,
            "max_receipts_per_run": max_receipts_per_run,
            "max_cost_microusd_per_run": max_cost_microusd_per_run,
        }
    )
    with vault_lock(root):
        ensure_managed_gitignore(root)
        directory = safe_subdirectory(root, "receipt-automation")
        directory.chmod(0o700)
        atomic_replace(root / CONFIG_PATH, canonical_json(config) + b"\n")
    return {
        "schema_version": 1,
        "command": "receipt-auto configure",
        "config": {
            "enabled": True,
            "claude_code_root_configured": True,
            "codex_root_configured": True,
            "rubric_configured": True,
        },
    }


def load_config(root: Path) -> dict[str, Any]:
    path = root / CONFIG_PATH
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("receipt automation config is unsafe")
        return _validate_config(json.loads(path.read_text(encoding="utf-8")))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError) as error:
        raise VaultError("receipt automation config is unavailable") from error


def _read_json_file(path: Path, default: object) -> object:
    if not path.exists() and not path.is_symlink():
        return default
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
            or metadata.st_size > MAX_STATE_BYTES
        ):
            raise VaultError("receipt automation state is unsafe")
        return json.loads(path.read_text(encoding="utf-8"))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError) as error:
        raise VaultError("receipt automation state is invalid") from error


def _hints(root: Path) -> list[dict[str, Any]]:
    path = root / HINTS_PATH
    if not path.exists() and not path.is_symlink():
        return []
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
            or metadata.st_size > MAX_HINTS_BYTES
        ):
            raise VaultError("receipt automation hints are unsafe")
        values = [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError) as error:
        raise VaultError("receipt automation hints are invalid") from error
    if len(values) > MAX_HINTS:
        raise VaultError("receipt automation hints exceed the size limit")
    return [item for item in values if isinstance(item, dict)]


def _compact_hints(root: Path, terminal_event_ids: set[str]) -> None:
    if not terminal_event_ids:
        return
    directory = safe_subdirectory(root, "receipt-automation")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    parent_descriptor = os.open(directory, directory_flags)
    lock_flags = os.O_CREAT | os.O_RDWR
    lock_flags |= getattr(os, "O_CLOEXEC", 0)
    lock_flags |= getattr(os, "O_NOFOLLOW", 0)
    lock_descriptor = -1
    try:
        lock_descriptor = os.open(
            "events.lock", lock_flags, 0o600, dir_fd=parent_descriptor
        )
        metadata = os.fstat(lock_descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
        ):
            raise VaultError("receipt automation hint lock is unsafe")
        os.fchmod(lock_descriptor, 0o600)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
        current = _hints(root)
        retained = [
            hint
            for hint in current
            if hint.get("event_id") not in terminal_event_ids
        ]
        if len(retained) == len(current):
            return
        data = b"".join(canonical_json(hint) + b"\n" for hint in retained)
        atomic_replace(root / HINTS_PATH, data)
    except VaultError:
        raise
    except OSError as error:
        raise VaultError("receipt automation hints could not be compacted") from error
    finally:
        if lock_descriptor >= 0:
            os.close(lock_descriptor)
        os.close(parent_descriptor)


def _validate_attempt_item(value: object) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VaultError("receipt automation attempts are invalid")
    state = value.get("state")
    fingerprint = value.get("fingerprint")
    if (
        state not in {"pending", "prepared", "failed", "completed"}
        or not isinstance(fingerprint, str)
        or FINGERPRINT_RE.fullmatch(fingerprint) is None
    ):
        raise VaultError("receipt automation attempts are invalid")
    if state != "prepared":
        allowed_fields = {"fingerprint", "state"}
        if state == "completed" and set(value) == {
            "fingerprint",
            "state",
            "event_id",
            "episode_id",
        }:
            event_id = value.get("event_id")
            episode_id = value.get("episode_id")
            if (
                not isinstance(event_id, str)
                or not event_id
                or len(event_id) > 256
                or any(character in event_id for character in "\r\n\0")
                or not isinstance(episode_id, str)
                or FINGERPRINT_RE.fullmatch(episode_id) is None
            ):
                raise VaultError("receipt automation attempts are invalid")
            return value
        if set(value) != allowed_fields:
            raise VaultError("receipt automation attempts are invalid")
        return value
    if set(value) != {
        "fingerprint",
        "state",
        "event_id",
        "episode_id",
        "prepared",
    }:
        raise VaultError("receipt automation attempts are invalid")
    event_id = value.get("event_id")
    episode_id = value.get("episode_id")
    if (
        not isinstance(event_id, str)
        or not event_id
        or len(event_id) > 256
        or any(character in event_id for character in "\r\n\0")
        or not isinstance(episode_id, str)
        or FINGERPRINT_RE.fullmatch(episode_id) is None
    ):
        raise VaultError("receipt automation attempts are invalid")
    prepared = _validate_prepared_record(value.get("prepared"))
    if (
        prepared["result"]["receipt"]["episode_id"] != episode_id
        or event_id not in prepared["snapshot"]["source_event_ids"]
        or len(canonical_json(value)) > MAX_PREPARED_ATTEMPT_BYTES
    ):
        raise VaultError("receipt automation attempts are invalid")
    return value


def _attempts(root: Path) -> dict[str, dict[str, Any]]:
    value = _read_json_file(root / ATTEMPTS_PATH, {"schema_version": 1, "items": []})
    items = value.get("items") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "items"}
        or value.get("schema_version") != 1
        or not isinstance(items, list)
        or len(items) > MAX_ATTEMPTS
    ):
        raise VaultError("receipt automation attempts are invalid")
    checked = [_validate_attempt_item(item) for item in items]
    if len({item["fingerprint"] for item in checked}) != len(checked):
        raise VaultError("receipt automation attempts are invalid")
    return {item["fingerprint"]: item for item in checked}


def _encoded_attempts(attempts: dict[str, dict[str, Any]]) -> bytes:
    if len(attempts) > MAX_ATTEMPTS:
        raise VaultError("receipt automation attempts exceed the size limit")
    checked = [_validate_attempt_item(item) for item in attempts.values()]
    value = {
        "schema_version": 1,
        "items": sorted(checked, key=lambda item: item["fingerprint"]),
    }
    data = canonical_json(value) + b"\n"
    if len(data) > MAX_STATE_BYTES:
        raise VaultError("receipt automation attempts exceed the size limit")
    return data


def _store_attempts(root: Path, attempts: dict[str, dict[str, Any]]) -> None:
    data = _encoded_attempts(attempts)
    atomic_replace(root / ATTEMPTS_PATH, data)


def _reserve_prepared_attempt(
    attempts: dict[str, dict[str, Any]], fingerprint: str
) -> None:
    reserved = dict(attempts)
    reserved[fingerprint] = {
        "fingerprint": fingerprint,
        "state": "pending",
    }
    if (
        len(_encoded_attempts(reserved)) + MAX_PREPARED_ATTEMPT_BYTES
        > MAX_STATE_BYTES
    ):
        raise VaultError("receipt automation attempts lack prepared capacity")


def _write_status(root: Path, value: dict[str, Any]) -> None:
    atomic_replace(root / STATUS_PATH, canonical_json(value) + b"\n")


def record_failure(root: Path, diagnostic_code: str) -> None:
    if diagnostic_code != "configuration_invalid":
        raise VaultError("receipt automation diagnostic code is invalid")
    value = _empty_status(True)
    value.update(
        {
            "state": "error",
            "diagnostic_code": diagnostic_code,
        }
    )
    with vault_lock(root):
        safe_subdirectory(root, "receipt-automation")
        _write_status(root, value)


@contextlib.contextmanager
def run_lock(root: Path, *, blocking: bool) -> Iterator[bool]:
    directory = safe_subdirectory(root, "receipt-automation")
    path = root / LOCK_PATH
    descriptor = os.open(
        path,
        os.O_CREAT
        | os.O_RDWR
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
        ):
            raise VaultError("receipt automation run lock is unsafe")
        os.fchmod(descriptor, 0o600)
        try:
            flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
            fcntl.flock(descriptor, flags)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(descriptor)
        directory.chmod(0o700)


def remove_episode_attempts(
    root: Path, episode_id: str
) -> bytes | None:
    """Remove identifiable Receipt attempts under caller-held locks."""
    path = root / ATTEMPTS_PATH
    if not path.exists() and not path.is_symlink():
        return None
    attempts = _attempts(root)
    snapshot = path.read_bytes()
    remaining = {
        fingerprint: item
        for fingerprint, item in attempts.items()
        if item.get("episode_id") != episode_id
    }
    _store_attempts(root, remaining)
    return snapshot


def restore_attempts(root: Path, snapshot: bytes | None) -> None:
    """Restore the exact Receipt attempt ledger after failed purge."""
    path = root / ATTEMPTS_PATH
    if snapshot is None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return
    if len(snapshot) > MAX_STATE_BYTES:
        raise VaultError("receipt automation attempts exceed the size limit")
    atomic_replace(path, snapshot)


def _safe_source(
    hint: dict[str, Any], config: dict[str, Any]
) -> tuple[str, Path, os.stat_result, bytes] | tuple[str, None, None, None]:
    adapter = hint.get("harness")
    if adapter not in {"claude-code", "codex"}:
        return "ambiguous", None, None, None
    source_value = hint.get("source_path")
    captured = hint.get("captured_size_bytes")
    identity = hint.get("source_identity")
    if (
        not isinstance(source_value, str)
        or not Path(source_value).is_absolute()
        or isinstance(captured, bool)
        or not isinstance(captured, int)
        or captured <= 0
        or captured > MAX_SOURCE_PREFIX_BYTES
        or not isinstance(identity, dict)
    ):
        return "ambiguous", None, None, None
    source = Path(source_value)
    configured_root = Path(
        config["claude_code_root" if adapter == "claude-code" else "codex_root"]
    ).resolve()
    try:
        resolved = source.resolve(strict=True)
        if not resolved.is_relative_to(configured_root):
            return "ambiguous", None, None, None
        metadata = resolved.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_dev != identity.get("device")
            or metadata.st_ino != identity.get("inode")
            or metadata.st_size < captured
        ):
            return "ambiguous", None, None, None
        if (
            dt.datetime.now(dt.timezone.utc).timestamp()
            - metadata.st_mtime
            < config["quiescence_seconds"]
        ):
            return "active", None, None, None
        with resolved.open("rb") as stream:
            prefix = stream.read(captured)
        if len(prefix) != captured:
            return "missing", None, None, None
    except FileNotFoundError:
        return "missing", None, None, None
    except OSError:
        return "ambiguous", None, None, None
    return "candidate", resolved, metadata, prefix


def _json_lines(prefix: bytes) -> list[dict[str, Any]] | None:
    try:
        text = prefix.decode("utf-8")
        rows = [
            json.loads(line)
            for line in text.splitlines()
            if line.strip()
        ]
        return rows if len(rows) <= MAX_SOURCE_LINES else None
    except (UnicodeError, ValueError):
        return None


def _matches_hash(value: object, expected: object, key: bytes) -> bool:
    return isinstance(expected, str) and hash_identifier(value, key) == expected


def _claude_span(
    rows: list[dict[str, Any]], hint: dict[str, Any], key: bytes
) -> tuple[str, int | None, int | None]:
    if not rows or any(not isinstance(row, dict) for row in rows):
        return "ambiguous", None, None
    markers = [
        (index, row)
        for index, row in enumerate(rows)
        if row.get("type") == "last-prompt"
        and _matches_hash(
            row.get("sessionId"), hint.get("session_id_hash"), key
        )
        and isinstance(row.get("leafUuid"), str)
    ]
    if not markers:
        return "ambiguous", None, None
    marker_index, marker = markers[-1]
    uuid_rows = [
        (row["uuid"], index, row)
        for index, row in enumerate(rows[:marker_index])
        if isinstance(row.get("uuid"), str)
    ]
    if len({uuid for uuid, _index, _row in uuid_rows}) != len(uuid_rows):
        return "ambiguous", None, None
    by_uuid = {
        uuid: (index, row) for uuid, index, row in uuid_rows
    }
    selected: list[int] = []
    current = marker["leafUuid"]
    seen: set[str] = set()
    found_prompt = False
    while current is not None:
        if current in seen or current not in by_uuid:
            return "ambiguous", None, None
        seen.add(current)
        index, row = by_uuid[current]
        if not _matches_hash(
            row.get("sessionId"), hint.get("session_id_hash"), key
        ):
            return "ambiguous", None, None
        selected.append(index)
        message = row.get("message")
        if (
            row.get("type") == "user"
            and isinstance(message, dict)
            and message.get("role") == "user"
            and isinstance(message.get("content"), str)
            and not row.get("isMeta", False)
            and "toolUseResult" not in row
        ):
            found_prompt = True
            break
        parent = row.get("parentUuid")
        if parent is not None and not isinstance(parent, str):
            return "ambiguous", None, None
        current = parent
    selected.reverse()
    if not selected or not found_prompt:
        return "ambiguous", None, None
    first = selected[0]
    first_row = rows[first]
    message = first_row.get("message")
    if (
        first_row.get("type") != "user"
        or not isinstance(message, dict)
        or message.get("role") != "user"
        or isinstance(message.get("content"), list)
    ):
        return "ambiguous", None, None
    leaf_row = rows[selected[-1]]
    leaf_message = leaf_row.get("message")
    if (
        leaf_row.get("type") != "assistant"
        or not isinstance(leaf_message, dict)
        or leaf_message.get("role") != "assistant"
    ):
        return "ambiguous", None, None
    selected_set = set(selected)
    for index in range(selected[0], selected[-1] + 1):
        if index not in selected_set and rows[index].get("type") in {
            "user",
            "assistant",
        }:
            return "ambiguous", None, None
    return "exact", selected[0] + 1, selected[-1] + 1


def _codex_span(
    rows: list[dict[str, Any]], hint: dict[str, Any], key: bytes
) -> tuple[str, int | None, int | None]:
    session_matches = [
        row
        for row in rows
        if row.get("type") == "session_meta"
        and isinstance(row.get("payload"), dict)
        and _matches_hash(
            (
                row["payload"].get("session_id")
                if row["payload"].get("session_id") is not None
                else row["payload"].get("id")
            ),
            hint.get("session_id_hash"),
            key,
        )
    ]
    if len(session_matches) != 1 or not isinstance(
        hint.get("turn_id_hash"), str
    ):
        return "ambiguous", None, None
    starts: list[int] = []
    ends: list[int] = []
    for index, row in enumerate(rows):
        payload = row.get("payload")
        if not isinstance(payload, dict) or not _matches_hash(
            payload.get("turn_id"), hint["turn_id_hash"], key
        ):
            continue
        if payload.get("type") == "task_started":
            starts.append(index)
        elif payload.get("type") == "task_complete":
            ends.append(index)
    pairs = [(start, end) for start in starts for end in ends if start < end]
    if len(pairs) != 1:
        return "ambiguous", None, None
    return "exact", pairs[0][0] + 1, pairs[0][1] + 1


def _classify_episode(
    event_id: object,
    hint: dict[str, Any],
    result: dict[str, Any] | None,
) -> tuple[str, dict[str, Any] | None]:
    if not isinstance(event_id, str):
        return "missing", None
    if result is None:
        return "missing", None
    members = result["members"]
    harness = hint.get("harness")
    session_hash = hint.get("session_id_hash")
    turn_hash = hint.get("turn_id_hash")
    if (
        not members
        or harness not in {"claude-code", "codex"}
        or not isinstance(session_hash, str)
        or not any(
            member[0] == event_id and member[2] == "Stop"
            for member in members
        )
        or any(member[1] != harness for member in members)
        or any(member[3] != session_hash for member in members)
        or (
            harness == "codex"
            and (
                not isinstance(turn_hash, str)
                or any(member[4] != turn_hash for member in members)
            )
        )
    ):
        return "ambiguous", None
    return (
        "exact",
        {
            "episode_id": result["episode_id"],
            "source_event_ids": [member[0] for member in members],
            "evidence_ids": result["evidence_ids"],
        },
    )


def _episode_for_event(
    root: Path,
    event_id: object,
    policy: str,
    hint: dict[str, Any],
) -> tuple[str, dict[str, Any] | None]:
    if not isinstance(event_id, str):
        return "missing", None
    from reporting import _authenticated_query

    def query(
        connection: sqlite3.Connection, _policy: dict[str, Any]
    ) -> dict[str, Any] | None:
        row = connection.execute(
            "SELECT episode_id FROM episode_members "
            "WHERE policy_version = ? AND event_id = ?",
            (policy, event_id),
        ).fetchone()
        if row is None:
            return None
        episode_id = row[0]
        members = list(
            connection.execute(
                "SELECT e.event_id, e.harness, e.source_event, "
                "e.session_id_hash, e.turn_id_hash "
                "FROM episode_members AS m "
                "JOIN source_events AS e ON e.event_id = m.event_id "
                "WHERE m.policy_version = ? AND m.episode_id = ? "
                "ORDER BY m.ordinal",
                (policy, episode_id),
            )
        )
        evidence_ids = [
            item[0]
            for item in connection.execute(
                "SELECT d.evidence_id "
                "FROM deterministic_evidence AS d "
                "JOIN episode_members AS m "
                "ON m.event_id = d.source_event_id "
                "WHERE m.policy_version = ? AND m.episode_id = ? "
                "ORDER BY d.evidence_id",
                (policy, episode_id),
            )
        ]
        return {
            "episode_id": episode_id,
            "members": members,
            "evidence_ids": evidence_ids,
        }

    result = _authenticated_query(root, policy, query)
    return _classify_episode(event_id, hint, result)


def _authenticated_episode_snapshot(
    root: Path,
    policy: str,
    event_ids: set[str],
) -> dict[str, dict[str, Any]]:
    """Authenticate the graph once and snapshot candidate Episodes."""
    from reporting import (
        _authenticated_query,
        _edges_by_episode,
        _episode_card,
    )
    from retention_state import load_forgotten

    def query(
        connection: sqlite3.Connection, stored_policy: dict[str, Any]
    ) -> dict[str, dict[str, Any]]:
        members_by_episode: dict[str, list[tuple[Any, ...]]] = {}
        selected_episode_ids: set[str] = set()
        for member in connection.execute(
            "SELECT m.episode_id, e.event_id, e.harness, e.source_event, "
            "e.session_id_hash, e.turn_id_hash "
            "FROM episode_members AS m "
            "JOIN source_events AS e ON e.event_id = m.event_id "
            "WHERE m.policy_version = ? ORDER BY m.episode_id, m.ordinal",
            (policy,),
        ):
            episode_id = member[0]
            event = tuple(member[1:])
            members_by_episode.setdefault(episode_id, []).append(event)
            if event[0] in event_ids:
                selected_episode_ids.add(episode_id)

        evidence_by_episode: dict[str, list[str]] = {}
        for episode_id, evidence_id in connection.execute(
            "SELECT DISTINCT m.episode_id, d.evidence_id "
            "FROM deterministic_evidence AS d "
            "JOIN episode_members AS m ON m.event_id = d.source_event_id "
            "WHERE m.policy_version = ? "
            "ORDER BY m.episode_id, d.evidence_id",
            (policy,),
        ):
            evidence_by_episode.setdefault(episode_id, []).append(evidence_id)

        forgotten = load_forgotten(root)
        edges_by_episode = _edges_by_episode(connection, policy)
        snapshot: dict[str, dict[str, Any]] = {}
        for episode_id in sorted(selected_episode_ids):
            members = members_by_episode[episode_id]
            card = None
            if (policy, episode_id) not in forgotten:
                card, _edges = _episode_card(
                    root,
                    connection,
                    stored_policy,
                    episode_id,
                    edges_by_episode,
                )
                load_semantic_receipts(
                    root,
                    policy,
                    episode_id,
                    card["source_event_ids"],
                    {
                        item["evidence_id"]
                        for item in card["deterministic_evidence"]
                    },
                )
            episode_snapshot = {
                "policy_version": policy,
                "card": card,
            }
            episode = {
                "episode_id": episode_id,
                "members": members,
                "evidence_ids": evidence_by_episode.get(episode_id, []),
                "episode_snapshot": episode_snapshot,
            }
            for member in members:
                snapshot[member[0]] = episode
        return snapshot

    return _authenticated_query(root, policy, query)


def _episode_from_snapshot(
    snapshot: dict[str, dict[str, Any]],
    event_id: object,
    hint: dict[str, Any],
) -> tuple[str, dict[str, Any] | None]:
    if not isinstance(event_id, str):
        return "missing", None
    result = snapshot.get(event_id)
    state, episode = _classify_episode(event_id, hint, result)
    if state != "exact" or episode is None:
        return state, episode
    if result["episode_snapshot"]["card"] is None:
        return "ambiguous", None
    episode["episode_snapshot"] = result["episode_snapshot"]
    return state, episode


def _commit_staged_receipts(
    root: Path,
    policy: str,
    staged: list[dict[str, Any]],
) -> None:
    from reporting import (
        _authenticated_query_locked,
        _edges_by_episode,
        _episode_card,
    )
    from retention_state import load_forgotten

    def query(
        connection: sqlite3.Connection, stored_policy: dict[str, Any]
    ) -> None:
        forgotten = load_forgotten(root)
        episode_ids = {
            item["episode_id"] for item in staged
        }
        if any((policy, episode_id) in forgotten for episode_id in episode_ids):
            raise VaultError("episode was forgotten during receipt generation")

        edges_by_episode = _edges_by_episode(connection, policy)
        inspections: dict[str, dict[str, Any]] = {}
        for episode_id in sorted(episode_ids):
            card, _edges = _episode_card(
                root,
                connection,
                stored_policy,
                episode_id,
                edges_by_episode,
            )
            evidence_ids = {
                item["evidence_id"]
                for item in card["deterministic_evidence"]
            }
            load_semantic_receipts(
                root,
                policy,
                episode_id,
                card["source_event_ids"],
                evidence_ids,
            )
            inspections[episode_id] = {
                "policy_version": policy,
                "card": card,
            }

        for item in staged:
            _validate_prepared_receipt(
                root,
                item["prepared"],
                inspections[item["episode_id"]],
            )
        for item in staged:
            _store_prepared_receipt(root, item["prepared"])

    with vault_lock(root):
        _authenticated_query_locked(root, policy, query)


def _fingerprint(
    hint: dict[str, Any],
    prefix: bytes,
    config: dict[str, Any],
    start: int,
    end: int,
    evaluator_sha256: str,
    rubric_sha256: str,
    episode: dict[str, Any],
) -> str:
    payload = {
        "event_id": hint.get("event_id"),
        "episode_id": episode["episode_id"],
        "source_event_ids": episode["source_event_ids"],
        "evidence_ids": episode["evidence_ids"],
        "source_prefix_sha256": hashlib.sha256(prefix).hexdigest(),
        "start_line": start,
        "end_line": end,
        "evaluator_sha256": evaluator_sha256,
        "model": config["model"],
        "rubric_sha256": rubric_sha256,
        "policy_version": config["policy_version"],
    }
    return "sha256:" + hashlib.sha256(canonical_json(payload)).hexdigest()


def _empty_status(enabled: bool) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "state": "idle",
        "enabled": enabled,
        "discovered": 0,
        "matched": 0,
        "ambiguous": 0,
        "missing": 0,
        "active": 0,
        "queued": 0,
        "generated": 0,
        "failed": 0,
        "measured_cost_microusd": 0,
        "diagnostic_code": None,
        "attempt_count": 0,
    }


def status(root: Path) -> dict[str, Any]:
    enabled = (root / CONFIG_PATH).exists() and not (root / CONFIG_PATH).is_symlink()
    value = _read_json_file(root / STATUS_PATH, _empty_status(enabled))
    if (
        not isinstance(value, dict)
        or set(value) != set(_empty_status(enabled))
        or value.get("schema_version") != 1
        or value.get("state") not in AUTOMATION_STATES
        or not isinstance(value.get("enabled"), bool)
        or value.get("diagnostic_code") not in DIAGNOSTIC_CODES
        or any(
            isinstance(value.get(field), bool)
            or not isinstance(value.get(field), int)
            or value[field] < 0
            for field in (
                "discovered",
                "matched",
                "ambiguous",
                "missing",
                "active",
                "queued",
                "generated",
                "failed",
                "measured_cost_microusd",
                "attempt_count",
            )
        )
    ):
        raise VaultError("receipt automation status is invalid")
    public = _empty_status(enabled)
    for field in public:
        if field in value:
            public[field] = value[field]
    public["enabled"] = enabled
    return public


def run(root: Path) -> dict[str, Any]:
    ensure_safe_existing_root(root)
    config = load_config(root)
    load_vault_config(root)
    ensure_managed_gitignore(root)
    with run_lock(root, blocking=False) as acquired:
        if not acquired:
            return {
                "schema_version": 1,
                "command": "receipt-auto run",
                "state": "attention",
                "matched_count": 0,
                "generated_count": 0,
                "idempotent_skip_count": 0,
                "attempt_skip_count": 0,
                "ambiguous_count": 0,
                "missing_count": 0,
                "active_count": 0,
                "failed_count": 0,
                "measured_cost_microusd": 0,
            }
        hints = _hints(root)
        attempts = _attempts(root)
        key = authorized_key(root, None)
        evaluator_path, evaluator_sha256 = _executable_identity(
            config["evaluator"]
        )
        _rubric, rubric_sha256 = _load_rubric(Path(config["rubric_path"]))
        counts = {
            "matched": 0,
            "generated": 0,
            "idempotent_skip": 0,
            "attempt_skip": 0,
            "ambiguous": 0,
            "missing": 0,
            "active": 0,
            "failed": 0,
        }
        measured_cost = 0
        terminal_event_ids: set[str] = set()
        staged: list[dict[str, Any]] = []
        staged_fingerprints: set[str] = set()
        episode_snapshot: dict[str, dict[str, Any]] | None = None
        hinted_event_ids = {
            event_id
            for hint in hints
            if isinstance((event_id := hint.get("event_id")), str)
        }
        for hint in hints:
            event_id = hint.get("event_id")
            classification, source, _metadata, prefix = _safe_source(hint, config)
            if classification != "candidate":
                counts[classification] += 1
                if (
                    classification != "active"
                    and isinstance(event_id, str)
                ):
                    terminal_event_ids.add(event_id)
                continue
            assert source is not None and prefix is not None
            rows = _json_lines(prefix)
            if rows is None:
                counts["ambiguous"] += 1
                if isinstance(event_id, str):
                    terminal_event_ids.add(event_id)
                continue
            if hint.get("harness") == "claude-code":
                match, start, end = _claude_span(rows, hint, key)
            else:
                match, start, end = _codex_span(rows, hint, key)
            if match != "exact" or start is None or end is None:
                counts["ambiguous"] += 1
                if isinstance(event_id, str):
                    terminal_event_ids.add(event_id)
                continue
            if episode_snapshot is None:
                episode_snapshot = _authenticated_episode_snapshot(
                    root,
                    config["policy_version"],
                    hinted_event_ids,
                )
            episode_state, episode = _episode_from_snapshot(
                episode_snapshot, hint.get("event_id"), hint
            )
            if episode_state != "exact" or episode is None:
                counts[episode_state] += 1
                if isinstance(event_id, str):
                    terminal_event_ids.add(event_id)
                continue
            counts["matched"] += 1
            fingerprint = _fingerprint(
                hint,
                prefix,
                config,
                start,
                end,
                evaluator_sha256,
                rubric_sha256,
                episode,
            )
            previous = attempts.get(fingerprint)
            if previous is not None:
                if previous["state"] == "completed":
                    counts["idempotent_skip"] += 1
                    if isinstance(event_id, str):
                        terminal_event_ids.add(event_id)
                elif previous["state"] == "prepared":
                    if fingerprint in staged_fingerprints:
                        counts["attempt_skip"] += 1
                        continue
                    if len(staged) >= config["max_receipts_per_run"]:
                        continue
                    staged.append(
                        {
                            "episode_id": episode["episode_id"],
                            "event_id": event_id,
                            "fingerprint": fingerprint,
                            "prepared": previous["prepared"],
                        }
                    )
                    staged_fingerprints.add(fingerprint)
                else:
                    counts["attempt_skip"] += 1
                continue
            if (
                len(staged) + counts["failed"]
                >= config["max_receipts_per_run"]
                or measured_cost >= config["max_cost_microusd_per_run"]
            ):
                continue
            _reserve_prepared_attempt(attempts, fingerprint)
            attempts[fingerprint] = {
                "fingerprint": fingerprint,
                "state": "pending",
            }
            _store_attempts(root, attempts)
            try:
                source_result = register(root, hint["harness"], source)
                prepared = _prepare_receipt(
                    root,
                    episode["episode_snapshot"],
                    episode["episode_id"],
                    source_result["source_ref"],
                    start,
                    end,
                    config["evaluator"],
                    config["model"],
                    Path(config["rubric_path"]),
                    _evaluator_timeout_seconds(evaluator_path),
                    config["max_cost_microusd_per_run"] - measured_cost,
                )
            except VaultError:
                attempts[fingerprint]["state"] = "failed"
                _store_attempts(root, attempts)
                counts["failed"] += 1
                if isinstance(event_id, str):
                    terminal_event_ids.add(event_id)
                break
            measured_cost += prepared["result"]["measured_cost_microusd"]
            attempts[fingerprint] = {
                "fingerprint": fingerprint,
                "state": "prepared",
                "event_id": event_id,
                "episode_id": episode["episode_id"],
                "prepared": prepared,
            }
            _store_attempts(root, attempts)
            staged.append(
                {
                    "episode_id": episode["episode_id"],
                    "event_id": event_id,
                    "fingerprint": fingerprint,
                    "prepared": prepared,
                }
            )
            staged_fingerprints.add(fingerprint)
        if staged:
            try:
                _commit_staged_receipts(
                    root, config["policy_version"], staged
                )
            except VaultError:
                counts["failed"] += len(staged)
            else:
                for item in staged:
                    attempts[item["fingerprint"]] = {
                        "fingerprint": item["fingerprint"],
                        "state": "completed",
                        "event_id": item["event_id"],
                        "episode_id": item["episode_id"],
                    }
                    if isinstance(item["event_id"], str):
                        terminal_event_ids.add(item["event_id"])
                        for old_fingerprint, old in list(attempts.items()):
                            if (
                                old_fingerprint != item["fingerprint"]
                                and old.get("state") == "prepared"
                                and old.get("event_id") == item["event_id"]
                            ):
                                attempts.pop(old_fingerprint)
                counts["generated"] += len(staged)
            _store_attempts(root, attempts)
        if len(hints) >= HINT_COMPACTION_THRESHOLD:
            _compact_hints(root, terminal_event_ids)
        state = (
            "error"
            if counts["failed"]
            else "attention"
            if counts["ambiguous"] or counts["missing"] or counts["active"]
            else "completed"
        )
        local_status = {
            "schema_version": 1,
            "state": state,
            "enabled": True,
            "discovered": len(hints),
            "matched": counts["matched"],
            "ambiguous": counts["ambiguous"],
            "missing": counts["missing"],
            "active": counts["active"],
            "queued": max(
                0,
                counts["matched"]
                - counts["generated"]
                - counts["idempotent_skip"]
                - counts["attempt_skip"],
            ),
            "generated": counts["generated"],
            "failed": counts["failed"],
            "measured_cost_microusd": measured_cost,
            "diagnostic_code": (
                "evaluator_failed" if counts["failed"] else None
            ),
            "attempt_count": counts["generated"] + counts["failed"],
        }
        _write_status(root, local_status)
        return {
            "schema_version": 1,
            "command": "receipt-auto run",
            "state": state,
            "matched_count": counts["matched"],
            "generated_count": counts["generated"],
            "idempotent_skip_count": counts["idempotent_skip"],
            "attempt_skip_count": counts["attempt_skip"],
            "ambiguous_count": counts["ambiguous"],
            "missing_count": counts["missing"],
            "active_count": counts["active"],
            "failed_count": counts["failed"],
            "measured_cost_microusd": measured_cost,
        }
