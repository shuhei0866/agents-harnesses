#!/usr/bin/env python3
"""Coalesced, bounded automatic Evidence Index refresh state."""

from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
import stat
import time
from pathlib import Path
from typing import Any, Iterator

from chunk_rotation import (
    MAX_EVENTS_PER_CHUNK,
    atomic_replace,
    canonical_json,
    safe_subdirectory,
)
from vault import VaultError, vault_lock


STATE_PATH = Path("index/refresh-state.json")
LOCK_PATH = Path("index/refresh.lock")
MAX_REFRESH_CHUNKS = 2
MAX_REFRESH_EVENTS = MAX_EVENTS_PER_CHUNK
STATES = {"refresh_required", "refreshing", "ready", "error"}
DIAGNOSTICS = {
    None,
    "source_inventory_drift",
    "refresh_in_progress",
    "incremental_refresh_failed",
    "full_rebuild_required",
}
FIELDS = {
    "schema_version",
    "state",
    "diagnostic_code",
    "requested_at",
    "last_attempt_at",
    "last_success_at",
    "last_refresh_duration_ms",
    "last_vault_lock_duration_ms",
}


def _timestamp() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _empty(state: str, diagnostic: str | None) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "state": state,
        "diagnostic_code": diagnostic,
        "requested_at": None,
        "last_attempt_at": None,
        "last_success_at": None,
        "last_refresh_duration_ms": None,
        "last_vault_lock_duration_ms": None,
    }


def _validate(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != FIELDS
        or value.get("schema_version") != 1
        or value.get("state") not in STATES
        or value.get("diagnostic_code") not in DIAGNOSTICS
    ):
        raise VaultError("index refresh state is invalid")
    for field in ("requested_at", "last_attempt_at", "last_success_at"):
        item = value[field]
        if item is not None:
            if not isinstance(item, str):
                raise VaultError("index refresh state is invalid")
            try:
                dt.datetime.strptime(item, "%Y-%m-%dT%H:%M:%SZ")
            except ValueError as error:
                raise VaultError("index refresh state is invalid") from error
    for field in ("last_refresh_duration_ms", "last_vault_lock_duration_ms"):
        item = value[field]
        if item is not None and (
            isinstance(item, bool) or not isinstance(item, int) or item < 0
        ):
            raise VaultError("index refresh state is invalid")
    return dict(value)


def _read(root: Path) -> dict[str, Any] | None:
    directory = root / STATE_PATH.parent
    try:
        directory_metadata = directory.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise VaultError("index refresh state is unsafe") from error
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.geteuid()
        or directory_metadata.st_mode & 0o077
    ):
        raise VaultError("index refresh state is unsafe")
    path = root / STATE_PATH
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise VaultError("index refresh state is unsafe") from error
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_size > 16 * 1024
        ):
            raise VaultError("index refresh state is unsafe")
        raw = os.read(descriptor, 16 * 1024 + 1)
        after = os.fstat(descriptor)
        stable_fields = (
            "st_dev", "st_ino", "st_size", "st_mtime_ns", "st_mode",
            "st_uid", "st_nlink",
        )
        if (
            len(raw) != before.st_size
            or any(getattr(before, field) != getattr(after, field)
                   for field in stable_fields)
        ):
            raise VaultError("index refresh state is unsafe")
        return _validate(json.loads(raw))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError) as error:
        raise VaultError("index refresh state is invalid") from error
    finally:
        os.close(descriptor)


def _write(root: Path, value: dict[str, Any]) -> dict[str, Any]:
    selected = _validate(value)
    directory = safe_subdirectory(root, "index")
    path = root / STATE_PATH
    atomic_replace(path, canonical_json(selected) + b"\n")
    path.chmod(0o600)
    directory.chmod(0o700)
    return selected


def _probe_without_state(root: Path) -> tuple[str, str | None]:
    """Classify a pre-freshness index without persisting migration state."""
    from evidence_index import (
        INDEX_VERSION,
        _open_sealed_readonly,
        _validate_sealed_source_inventory,
        load_index_seal,
    )

    try:
        with vault_lock(root):
            seal = load_index_seal(root)
            connection = _open_sealed_readonly(root, seal)
            try:
                schema_version = int(
                    connection.execute("PRAGMA user_version").fetchone()[0]
                )
            finally:
                connection.close()
            if schema_version != INDEX_VERSION:
                return "error", "full_rebuild_required"
            try:
                _validate_sealed_source_inventory(root, seal)
            except VaultError:
                return "refresh_required", "source_inventory_drift"
    except (OSError, ValueError, TypeError, VaultError):
        return "error", "full_rebuild_required"
    return "ready", None


def status(root: Path) -> dict[str, Any]:
    existing = _read(root)
    if existing is not None:
        return existing
    state, diagnostic = _probe_without_state(root)
    return _empty(state, diagnostic)


def mark_manual_rebuild_ready_locked(root: Path) -> dict[str, Any]:
    """Publish readiness only after a manual rebuild and seal both succeed."""
    previous = _read(root)
    value = dict(previous or _empty("ready", None))
    value.update(
        {
            "state": "ready",
            "diagnostic_code": None,
            "last_success_at": _timestamp(),
        }
    )
    return _write(root, value)


def request_refresh_locked(root: Path) -> dict[str, Any]:
    previous = _read(root)
    if (
        previous is not None
        and previous["state"] == "error"
        and previous["diagnostic_code"] == "full_rebuild_required"
    ):
        return previous
    if previous is not None and previous["state"] == "refresh_required":
        return previous
    value = dict(previous or _empty("refresh_required", None))
    value.update(
        {
            "state": "refresh_required",
            "diagnostic_code": "source_inventory_drift",
            "requested_at": _timestamp(),
        }
    )
    return _write(root, value)


@contextlib.contextmanager
def _refresh_lock(root: Path, *, blocking: bool) -> Iterator[bool]:
    directory = safe_subdirectory(root, "index")
    path = root / LOCK_PATH
    try:
        descriptor = os.open(
            path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
        )
    except OSError as error:
        raise VaultError("index refresh lock is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("index refresh lock is unsafe")
        try:
            operation = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
            fcntl.flock(descriptor, operation)
        except BlockingIOError:
            yield False
            return
        yield True
    finally:
        os.close(descriptor)
        directory.chmod(0o700)


def authenticate_incremental_base(root: Path) -> None:
    from evidence_index import _authenticate_existing_index_for_write

    _authenticate_existing_index_for_write(root, source_may_advance=True)


def rebuild_incremental_bounded(
    root: Path, *, max_chunks: int, max_events: int
) -> bool:
    from evidence_index import rebuild_incremental_bounded as rebuild

    return rebuild(root, max_chunks=max_chunks, max_events=max_events)


def run_pending_refresh(root: Path) -> dict[str, Any]:
    with _refresh_lock(root, blocking=False) as acquired:
        if not acquired:
            return status(root)
        previous = status(root)
        if previous["state"] not in {"refresh_required", "refreshing"}:
            return previous
        started = time.monotonic()
        attempt_at = _timestamp()
        refreshing = {
            **previous,
            "state": "refreshing",
            "diagnostic_code": "refresh_in_progress",
            "last_attempt_at": attempt_at,
        }
        _write(root, refreshing)
        lock_started = time.monotonic()
        with vault_lock(root):
            try:
                authenticate_incremental_base(root)
                more = rebuild_incremental_bounded(
                    root,
                    max_chunks=MAX_REFRESH_CHUNKS,
                    max_events=MAX_REFRESH_EVENTS,
                )
            except VaultError as error:
                lock_ms = max(0, int((time.monotonic() - lock_started) * 1000))
                total_ms = max(
                    lock_ms, int((time.monotonic() - started) * 1000)
                )
                diagnostic = (
                    "full_rebuild_required"
                    if "seal" in str(error).lower()
                    or "full rebuild" in str(error).lower()
                    else "incremental_refresh_failed"
                )
                return _write(
                    root,
                    {
                        **refreshing,
                        "state": "error",
                        "diagnostic_code": diagnostic,
                        "last_refresh_duration_ms": total_ms,
                        "last_vault_lock_duration_ms": lock_ms,
                    },
                )
            lock_ms = max(0, int((time.monotonic() - lock_started) * 1000))
            total_ms = max(
                lock_ms, int((time.monotonic() - started) * 1000)
            )
            return _write(
                root,
                {
                    **refreshing,
                    "state": "refresh_required" if more else "ready",
                    "diagnostic_code": (
                        "source_inventory_drift" if more else None
                    ),
                    "last_success_at": (
                        previous["last_success_at"] if more else _timestamp()
                    ),
                    "last_refresh_duration_ms": total_ms,
                    "last_vault_lock_duration_ms": lock_ms,
                },
            )
