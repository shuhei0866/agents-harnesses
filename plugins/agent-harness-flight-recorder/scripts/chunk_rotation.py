#!/usr/bin/env python3
"""Rotate plaintext hook events into immutable, recipient-encrypted chunks."""

from __future__ import annotations

import base64
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
import re
import secrets
import stat
import tempfile
import uuid
from pathlib import Path
from typing import Any

from vault import (
    DEVICE_IDENTITY_PATH,
    HASH_KEY_PATH,
    VaultError,
    GITIGNORE,
    GIT_SYNC_ALLOWLIST,
    LEGACY_GITIGNORE,
    CONFIG_NAME,
    all_recipients,
    derive_recipient,
    ensure_safe_existing_root,
    fsync_directory,
    json_bytes,
    load_config,
    run,
    vault_lock,
    verify_recipient_state_hmac,
)


DIGEST_DOMAIN = b"agent-harness-flight-recorder/chunk-v1\0"
HASH_FIELDS = ("session_id_hash", "turn_id_hash", "workspace_id")
NULLABLE_STRINGS = ("model", "permission_mode", "tool")
EVENT_KINDS = {
    "session.started",
    "turn.prompted",
    "tool.completed",
    "turn.completed",
    "hook.observed",
}
METRIC_NAMES = {
    "duration_ms",
    "duration_api_ms",
    "tool_duration_ms",
    "num_turns",
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "total_cost_usd",
}
EVENT_FIELDS = {
    "schema_version",
    "event_id",
    "recorded_at",
    "harness",
    "source_event",
    "event_kind",
    *HASH_FIELDS,
    *NULLABLE_STRINGS,
    "metrics",
    "outcome",
}
RELATIONSHIP_CONTEXT_FIELDS = {
    "task_id_hash",
    "task_source",
    "branch_or_worktree_id",
    "changed_file_fingerprints",
    "changed_files_state",
}
EVENT_V2_FIELDS = EVENT_FIELDS | {"relationship_context"}
RFC3339_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}"
    r"(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def canonical_json(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def parse_time(value: object) -> dt.datetime:
    if not isinstance(value, str) or not RFC3339_RE.fullmatch(value):
        raise ValueError("recorded_at must be an RFC 3339 date-time string")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("recorded_at must be a valid date-time") from error
    if parsed.tzinfo is None:
        raise ValueError("recorded_at must include a timezone")
    return parsed


def validate_event(value: object) -> dict[str, Any]:
    if not isinstance(value, dict) or value.get("schema_version") not in (1, 2):
        raise ValueError("unsupported event schema_version")
    version = value["schema_version"]
    expected_fields = EVENT_FIELDS if version == 1 else EVENT_V2_FIELDS
    if set(value) != expected_fields:
        raise ValueError(f"event does not match event-v{version} fields")
    try:
        uuid.UUID(value["event_id"])
    except (TypeError, ValueError, AttributeError) as error:
        raise ValueError("event_id must be a UUID") from error
    parse_time(value["recorded_at"])
    if value["harness"] not in ("claude-code", "codex"):
        raise ValueError("invalid harness")
    if not isinstance(value["source_event"], str):
        raise ValueError("source_event must be a string")
    if value["event_kind"] not in EVENT_KINDS:
        raise ValueError("invalid event_kind")
    for field in HASH_FIELDS:
        item = value[field]
        if item is not None and (
            not isinstance(item, str)
            or len(item) != 31
            or not item.startswith("sha256:")
            or any(character not in "0123456789abcdef" for character in item[7:])
        ):
            raise ValueError(f"invalid {field}")
    for field in NULLABLE_STRINGS:
        if value[field] is not None and not isinstance(value[field], str):
            raise ValueError(f"invalid {field}")
    metrics = value["metrics"]
    if metrics is not None:
        if not isinstance(metrics, dict) or not set(metrics).issubset(METRIC_NAMES):
            raise ValueError("invalid metrics")
        for item in metrics.values():
            if (
                isinstance(item, bool)
                or not isinstance(item, (int, float))
                or item < 0
                or (isinstance(item, float) and not math.isfinite(item))
            ):
                raise ValueError("invalid metric value")
    outcome = value["outcome"]
    if outcome is not None:
        if (
            not isinstance(outcome, dict)
            or not set(outcome).issubset({"status", "exit_code"})
            or (
                "status" in outcome
                and outcome["status"] not in ("success", "failure", "unknown")
            )
            or (
                "exit_code" in outcome
                and outcome["exit_code"] is not None
                and (
                    isinstance(outcome["exit_code"], bool)
                    or not isinstance(outcome["exit_code"], int)
                )
            )
        ):
            raise ValueError("invalid outcome")
    if version == 2:
        context = value["relationship_context"]
        if not isinstance(context, dict) or set(context) != RELATIONSHIP_CONTEXT_FIELDS:
            raise ValueError("invalid relationship_context")
        for field in ("task_id_hash", "branch_or_worktree_id"):
            item = context[field]
            if item is not None and (
                not isinstance(item, str)
                or not re.fullmatch(r"sha256:[0-9a-f]{24}", item)
            ):
                raise ValueError(f"invalid relationship {field}")
        task_source = context["task_source"]
        if (context["task_id_hash"] is None and task_source is not None) or (
            context["task_id_hash"] is not None
            and task_source not in ("payload", "env", "branch")
        ):
            raise ValueError("invalid relationship task_source")
        fingerprints = context["changed_file_fingerprints"]
        if (
            not isinstance(fingerprints, list)
            or len(fingerprints) > 128
            or fingerprints != sorted(set(fingerprints))
            or any(
                not isinstance(item, str)
                or not re.fullmatch(r"sha256:[0-9a-f]{24}", item)
                for item in fingerprints
            )
        ):
            raise ValueError("invalid changed_file_fingerprints")
        state = context["changed_files_state"]
        if state not in ("complete", "truncated", "missing"):
            raise ValueError("invalid changed_files_state")
        if state == "missing" and fingerprints:
            raise ValueError("missing changed files cannot have fingerprints")
    return value


def safe_subdirectory(root: Path, *parts: str) -> Path:
    """Create a local-state path without traversing a symlinked component."""
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise VaultError(f"unsafe local state directory: {part}")
        try:
            current.mkdir(mode=0o700)
        except FileExistsError:
            if not current.is_dir():
                raise VaultError(f"unsafe local state directory: {part}")
        os.chmod(current, 0o700)
    return current


def acquire_inbox(root: Path) -> list[Path]:
    """Detach the current append file while holding only the stable inbox lock."""
    inbox = safe_subdirectory(root, "inbox")
    queue = safe_subdirectory(root, "queue")
    lock_path = inbox / "events.lock"
    lock_flags = os.O_CREAT | os.O_RDWR
    lock_flags |= getattr(os, "O_CLOEXEC", 0)
    lock_flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, lock_flags, 0o600)
    except OSError as error:
        raise VaultError("event inbox lock is unavailable or unsafe") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise VaultError("event inbox lock is unsafe")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        live = inbox / "events.jsonl"
        legacy = root / "events.jsonl"
        sources = [path for path in (legacy, live) if path.is_file()]
        if any(path.is_symlink() for path in (legacy, live)):
            raise VaultError("event inbox is unsafe")
        if not sources:
            # Establish the append target without producing an empty job.
            file_descriptor = os.open(live, os.O_CREAT | os.O_WRONLY, 0o600)
            os.close(file_descriptor)
            return []
        jobs: list[Path] = []
        # Detach each generation independently. Every transition is a rename,
        # so a crash between legacy migration and live rotation cannot copy an
        # event into two retry jobs.
        for source in sources:
            job = queue / f"{uuid.uuid4()}.jsonl.pending"
            os.replace(source, job)
            # A durable rename requires both directory entries to reach disk.
            fsync_directory(source.parent)
            fsync_directory(queue)
            jobs.append(job)
        file_descriptor = os.open(live, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(file_descriptor)
        fsync_directory(queue)
        fsync_directory(inbox)
        return jobs
    finally:
        os.close(descriptor)


def quarantine_rows(root: Path, job: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    directory = safe_subdirectory(root, "quarantine")
    target = directory / f"{job.name.removesuffix('.jsonl.pending')}.jsonl"
    data = b"".join(canonical_json(row) + b"\n" for row in rows)
    atomic_replace(target, data)


def atomic_replace(path: Path, data: bytes) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_job(root: Path, job: Path) -> list[dict[str, Any]]:
    valid: list[dict[str, Any]] = []
    invalid: list[dict[str, Any]] = []
    raw = job.read_bytes()
    # split(b"\n") preserves a final partial line while ignoring a normal final LF.
    lines = raw.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    for number, line in enumerate(lines, 1):
        try:
            decoded = line.decode("utf-8")
            event = validate_event(json.loads(decoded))
        except (UnicodeError, json.JSONDecodeError, ValueError) as error:
            invalid.append(
                {
                    "line_number": number,
                    "reason": str(error),
                    "raw_base64": base64.b64encode(line).decode("ascii"),
                }
            )
        else:
            valid.append(event)
    quarantine_rows(root, job, invalid)
    return valid


def local_device(config: dict[str, object], root: Path) -> tuple[str, Path]:
    identity = root / DEVICE_IDENTITY_PATH
    if identity.is_symlink() or not identity.is_file():
        raise VaultError("local device identity is missing or unsafe")
    recipient = derive_recipient(identity)
    devices = config["devices"]
    assert isinstance(devices, list)
    matches = [item["device_id"] for item in devices if item["recipient"] == recipient]
    if len(matches) != 1:
        raise VaultError("local device identity is not uniquely enrolled")
    return matches[0], identity


def encrypt_chunk(plaintext: bytes, recipients: list[str], output: Path) -> None:
    command = ["age", "-o", str(output)]
    for recipient in recipients:
        command.extend(["-r", recipient])
    run(command, stdin=plaintext)
    if output.is_symlink() or not output.is_file():
        raise VaultError("age did not create a chunk")
    os.chmod(output, 0o600)
    descriptor = os.open(output, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def publish(root: Path, config: dict[str, object], identity: Path, events: list[dict[str, Any]]) -> None:
    vault_id = config["vault_id"]
    assert isinstance(vault_id, str)
    device_id, _ = local_device(config, root)
    canonical_events = b"".join(canonical_json(event) + b"\n" for event in events)
    digest = hashlib.sha256(
        DIGEST_DOMAIN
        + vault_id.encode()
        + b"\0"
        + device_id.encode()
        + b"\0"
        + canonical_events
    ).hexdigest()
    first_time = parse_time(events[0]["recorded_at"]).astimezone(dt.timezone.utc)
    created_at = first_time.isoformat().replace("+00:00", "Z")
    event_version = events[0]["schema_version"]
    if any(event["schema_version"] != event_version for event in events):
        raise VaultError("chunk events must have one schema version")
    header = {
        "record_type": "chunk_header",
        "schema_version": 1,
        "event_schema_version": event_version,
        "chunk_id": f"sha256:{digest}",
        "vault_id": vault_id,
        "device_id": device_id,
        "created_at": created_at,
        "event_count": len(events),
    }
    plaintext = canonical_json(header) + b"\n" + canonical_events
    directory = safe_subdirectory(
        root,
        "devices",
        device_id,
        f"{first_time.year:04d}",
        f"{first_time.month:02d}",
        f"{first_time.day:02d}",
    )
    final = directory / f"{digest}.jsonl.age"
    if final.exists():
        if final.is_symlink() or not final.is_file():
            raise VaultError("chunk destination is unsafe")
        existing = run(["age", "-d", "-i", str(identity), str(final)])
        if not secrets.compare_digest(existing, plaintext):
            raise VaultError("immutable chunk conflict")
        return
    descriptor, temporary_name = tempfile.mkstemp(prefix=".chunk.", dir=directory)
    os.close(descriptor)
    temporary = Path(temporary_name)
    temporary.unlink()
    try:
        encrypt_chunk(plaintext, all_recipients(config), temporary)
        try:
            os.link(temporary, final)
        except FileExistsError:
            existing = run(["age", "-d", "-i", str(identity), str(final)])
            if not secrets.compare_digest(existing, plaintext):
                raise VaultError("immutable chunk conflict")
        fsync_directory(directory)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def process_job(root: Path, config: dict[str, object], identity: Path, job: Path) -> None:
    events = read_job(root, job)
    for version in (1, 2):
        homogeneous = [event for event in events if event["schema_version"] == version]
        if homogeneous:
            publish(root, config, identity, homogeneous)
    job.unlink()
    fsync_directory(job.parent)


def rotate_locked(root: Path) -> None:
    ensure_safe_existing_root(root)
    config = load_config(root)
    key_path = root / HASH_KEY_PATH
    if key_path.is_symlink() or not key_path.is_file():
        raise VaultError("local correlation key is missing or unsafe")
    key = key_path.read_bytes()
    if len(key) != 32:
        raise VaultError("local correlation key has an invalid length")
    verify_recipient_state_hmac(config, key)
    gitignore = root / ".gitignore"
    if gitignore.is_symlink():
        raise VaultError("vault Git ignore file is unsafe")
    if not gitignore.is_file():
        raise VaultError("vault Git ignore file is missing or unsafe")
    gitignore_contents = gitignore.read_text(encoding="utf-8")
    if gitignore_contents == LEGACY_GITIGNORE:
        atomic_replace(gitignore, GITIGNORE.encode("utf-8"))
    elif gitignore_contents != GITIGNORE:
        raise VaultError("vault Git ignore file is not managed by this version")
    if config["git_sync_allowlist"] != GIT_SYNC_ALLOWLIST:
        config["git_sync_allowlist"] = GIT_SYNC_ALLOWLIST
        atomic_replace(root / CONFIG_NAME, json_bytes(config))
    _, identity = local_device(config, root)

    queue = safe_subdirectory(root, "queue")
    # Retry detached jobs before detaching the current inbox.
    for job in sorted(queue.glob("*.jsonl.pending")):
        if job.is_symlink() or not job.is_file():
            raise VaultError("pending rotation job is unsafe")
        process_job(root, config, identity, job)
    for job in acquire_inbox(root):
        process_job(root, config, identity, job)


def rotate(root: Path) -> None:
    # Serialize rotations and recipient mutations without touching the hook's
    # short-lived inbox lock. Encryption therefore never blocks event capture.
    with vault_lock(root):
        rotate_locked(root)
