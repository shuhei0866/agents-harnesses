#!/usr/bin/env python3
"""Manually synchronize encrypted Flight Recorder chunks through Git."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
from pathlib import Path

from chunk_rotation import (
    DIGEST_DOMAIN,
    atomic_replace,
    canonical_json,
    local_device,
    parse_time,
    rotate_locked,
    safe_subdirectory,
    validate_event,
)
from vault import (
    CONFIG_NAME,
    ENVELOPE_PATH,
    GIT_SYNC_ALLOWLIST,
    HASH_KEY_PATH,
    VaultError,
    authorized_key,
    load_config,
    run,
    vault_lock,
    verify_recipient_state_hmac,
)


CHUNK_PATH_RE = re.compile(
    r"^devices/"
    r"(?P<device>[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12})/"
    r"(?P<year>\d{4})/(?P<month>\d{2})/(?P<day>\d{2})/"
    r"(?P<digest>[0-9a-f]{64})\.jsonl\.age$"
)
FIXED_TRACKED = {".gitignore", CONFIG_NAME, str(ENVELOPE_PATH)}
HEADER_FIELDS = {
    "record_type",
    "schema_version",
    "event_schema_version",
    "chunk_id",
    "vault_id",
    "device_id",
    "created_at",
    "event_count",
}
PENDING_PATH = Path("queue/pending-sync.json")
RECEIPT_PATH = Path("index/imported-chunks.json")


class SyncFailure(VaultError):
    """A secret-free classification for background retry decisions."""

    def __init__(
        self,
        message: str,
        *,
        failure_class: str,
        diagnostic_code: str,
        next_action_code: str,
    ) -> None:
        super().__init__(message)
        self.failure_class = failure_class
        self.diagnostic_code = diagnostic_code
        self.next_action_code = next_action_code


def transient_remote_failure() -> SyncFailure:
    return SyncFailure(
        "remote synchronization is unavailable",
        failure_class="transient",
        diagnostic_code="remote_unavailable",
        next_action_code="retry_automatically",
    )


def permanent_sync_failure(
    diagnostic_code: str = "local_integrity_invalid",
) -> SyncFailure:
    return SyncFailure(
        "synchronization requires local repair",
        failure_class="permanent",
        diagnostic_code=diagnostic_code,
        next_action_code="repair_configuration",
    )


def git(
    root: Path,
    arguments: list[str],
    *,
    allowed: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            shell=False,
        )
    except FileNotFoundError as error:
        raise VaultError("required command is unavailable: git") from error
    if result.returncode not in allowed:
        # Remote URLs, paths, and hook output can contain secrets. Never relay
        # Git stderr through this privacy-sensitive command.
        raise VaultError("git synchronization failed")
    return result


def text_output(result: subprocess.CompletedProcess[bytes]) -> str:
    try:
        return result.stdout.decode("utf-8")
    except UnicodeError as error:
        raise VaultError("git returned invalid output") from error


def ensure_repository(root: Path, remote: str) -> None:
    git_dir = root / ".git"
    if git_dir.is_symlink() or (git_dir.exists() and not git_dir.is_dir()):
        raise VaultError("Vault Git metadata is unsafe")
    if not git_dir.exists():
        git(root, ["init", "-q"])
    top = text_output(git(root, ["rev-parse", "--show-toplevel"])).strip()
    try:
        resolved_top = Path(top).resolve(strict=True)
        resolved_root = root.resolve(strict=True)
    except OSError as error:
        raise VaultError("Vault Git root is invalid") from error
    if resolved_top != resolved_root:
        raise VaultError("Git repository must be rooted at the Vault")

    origin = git(root, ["remote", "get-url", "origin"], allowed=(0, 2))
    if origin.returncode == 2:
        git(root, ["remote", "add", "origin", remote])
    elif text_output(origin).strip() != remote:
        raise permanent_sync_failure("origin_mismatch")
    push_urls = [
        value
        for value in text_output(
            git(root, ["remote", "get-url", "--push", "--all", "origin"])
        ).splitlines()
        if value
    ]
    if push_urls != [remote]:
        raise permanent_sync_failure("origin_mismatch")


def tracked_paths(root: Path) -> list[str]:
    output = git(root, ["ls-files", "-z"]).stdout
    try:
        paths = output.decode("utf-8").split("\0")
    except UnicodeError as error:
        raise VaultError("Git index contains an invalid path") from error
    return [path for path in paths if path]


def allowed_path(path: str) -> bool:
    return path in FIXED_TRACKED or CHUNK_PATH_RE.fullmatch(path) is not None


def strict_preflight(root: Path) -> dict[str, str]:
    stage_output = git(root, ["ls-files", "--stage", "-z"]).stdout
    try:
        entries = stage_output.decode("utf-8").split("\0")
    except UnicodeError as error:
        raise VaultError("Git index contains an invalid entry") from error
    indexed: dict[str, str] = {}
    for entry in (item for item in entries if item):
        try:
            metadata, path = entry.split("\t", 1)
            mode, oid, stage_number = metadata.split(" ", 2)
        except ValueError as error:
            raise VaultError("Git index contains an invalid entry") from error
        if (
            mode != "100644"
            or stage_number != "0"
            or not allowed_path(path)
            or path in indexed
        ):
            raise VaultError("Git index contains an unsafe entry")
        indexed[path] = oid
    if (root / ".gitmodules").exists():
        raise VaultError("Git submodules are not allowed in a Vault")
    for relative in FIXED_TRACKED:
        candidate = root / relative
        try:
            metadata = candidate.lstat()
        except OSError as error:
            raise VaultError("required Git sync file is missing") from error
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise VaultError("required Git sync file is unsafe")
    config = load_config(root)
    if config["git_sync_allowlist"] != GIT_SYNC_ALLOWLIST:
        raise VaultError("Vault Git allowlist is not current")
    key_path = root / HASH_KEY_PATH
    try:
        key_metadata = key_path.lstat()
    except OSError as error:
        raise VaultError("local correlation key is missing") from error
    if not stat.S_ISREG(key_metadata.st_mode) or key_metadata.st_nlink != 1:
        raise VaultError("local correlation key is unsafe")
    key = key_path.read_bytes()
    envelope_key = authorized_key(root, None)
    if len(key) != 32 or not secrets.compare_digest(key, envelope_key):
        raise VaultError("encrypted correlation key does not match local authority")
    verify_recipient_state_hmac(config, key)
    local_device(config, root)
    return indexed


def stage_allowlist(root: Path) -> None:
    paths = [".gitignore", CONFIG_NAME, str(ENVELOPE_PATH)]
    devices = root / "devices"
    if devices.is_symlink():
        raise VaultError("encrypted chunk directory is unsafe")
    if devices.is_dir():
        for candidate in sorted(devices.rglob("*.jsonl.age")):
            if candidate.is_symlink() or not candidate.is_file():
                raise VaultError("encrypted chunk is unsafe")
            relative = candidate.relative_to(root).as_posix()
            if not CHUNK_PATH_RE.fullmatch(relative):
                raise VaultError("encrypted chunk path is invalid")
            paths.append(relative)
    git(root, ["add", "--", *paths])
    strict_preflight(root)


def commit_if_needed(root: Path) -> bool:
    changed = git(root, ["diff", "--cached", "--quiet"], allowed=(0, 1))
    if changed.returncode == 0:
        return False
    git(
        root,
        [
            "-c",
            "user.name=Flight Recorder",
            "-c",
            "user.email=flight-recorder@localhost",
            "commit",
            "-q",
            "-m",
            "Sync encrypted flight recorder artifacts",
        ],
    )
    return True


def changed_artifact_paths(root: Path) -> list[str]:
    output = git(
        root,
        ["show", "--format=", "--name-only", "-z", "HEAD"],
    ).stdout
    try:
        paths = output.decode("utf-8").split("\0")
    except UnicodeError as error:
        raise VaultError("Git commit contains an invalid path") from error
    return sorted(
        path for path in paths if path and CHUNK_PATH_RE.fullmatch(path)
    )


def load_pending(root: Path) -> dict[str, object] | None:
    path = root / PENDING_PATH
    if not path.exists():
        return None
    if path.is_symlink() or not path.is_file():
        raise VaultError("pending sync state is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("pending sync state is invalid") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise VaultError("pending sync state is invalid")
    return value


def write_pending(
    root: Path,
    *,
    device_id: str,
    phase: str,
    artifact_paths: list[str],
    error_category: str | None,
    increment_attempt: bool = False,
) -> None:
    queue = safe_subdirectory(root, "queue")
    path = root / PENDING_PATH
    head = text_output(git(root, ["rev-parse", "HEAD"])).strip()
    previous = load_pending(root)
    previous_attempts = (
        previous.get("attempt_count", 0) if previous is not None else 0
    )
    if isinstance(previous_attempts, bool) or not isinstance(previous_attempts, int):
        raise VaultError("pending sync state is invalid")
    previous_paths = previous.get("artifact_paths", []) if previous else []
    if not isinstance(previous_paths, list) or any(
        not isinstance(item, str) or not CHUNK_PATH_RE.fullmatch(item)
        for item in previous_paths
    ):
        raise VaultError("pending sync state is invalid")
    combined_paths = sorted(set(previous_paths) | set(artifact_paths))
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    state = {
        "schema_version": 1,
        "device_id": device_id,
        "phase": phase,
        "commit_oid": head,
        "artifact_paths": combined_paths,
        "attempt_count": previous_attempts + (1 if increment_attempt else 0),
        "last_error_category": error_category,
        "updated_at": now.isoformat().replace("+00:00", "Z"),
    }
    data = canonical_json(state) + b"\n"
    atomic_replace(path, data)
    os.chmod(queue, 0o700)


def remote_has_main(root: Path) -> bool:
    result = git(
        root,
        ["ls-remote", "--exit-code", "--heads", "origin", "refs/heads/main"],
        allowed=(0, 2),
    )
    return result.returncode == 0


def pull_rebase(root: Path) -> None:
    if remote_has_main(root):
        try:
            git(root, ["pull", "--rebase", "-q", "origin", "main"])
        except VaultError as error:
            git_dir = root / ".git"
            conflict = (git_dir / "rebase-merge").exists() or (
                git_dir / "rebase-apply"
            ).exists()
            if conflict:
                try:
                    git(root, ["rebase", "--abort"])
                except VaultError:
                    pass
                raise permanent_sync_failure("rebase_conflict") from error
            raise transient_remote_failure() from error


def verify_after_pull(root: Path, expected_remote: str) -> dict[str, object]:
    config = load_config(root)
    if config["remote"] != expected_remote:
        raise VaultError("pulled Vault remote does not match local authority")
    origin = git(root, ["remote", "get-url", "origin"])
    if text_output(origin).strip() != expected_remote:
        raise VaultError("Git origin changed during synchronization")
    key_path = root / HASH_KEY_PATH
    if key_path.is_symlink() or not key_path.is_file():
        raise VaultError("local correlation key is missing or unsafe")
    key = key_path.read_bytes()
    if len(key) != 32:
        raise VaultError("local correlation key has an invalid length")
    verify_recipient_state_hmac(config, key)
    local_device(config, root)
    return config


def load_receipts(root: Path) -> dict[str, dict[str, str]]:
    path = root / RECEIPT_PATH
    if not path.exists():
        return {}
    if path.is_symlink() or not path.is_file():
        raise VaultError("import receipt is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("import receipt is invalid") from error
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != 1
        or not isinstance(value.get("chunks"), dict)
        or any(
            not valid_receipt(key, receipt)
            for key, receipt in value["chunks"].items()
        )
    ):
        raise VaultError("import receipt is invalid")
    return value["chunks"]


def valid_receipt(path: object, receipt: object) -> bool:
    return (
        isinstance(path, str)
        and CHUNK_PATH_RE.fullmatch(path) is not None
        and isinstance(receipt, dict)
        and set(receipt) == {"blob_oid", "chunk_id"}
        and isinstance(receipt["blob_oid"], str)
        and re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", receipt["blob_oid"])
        is not None
        and isinstance(receipt["chunk_id"], str)
        and re.fullmatch(r"sha256:[0-9a-f]{64}", receipt["chunk_id"]) is not None
    )


def working_blob_oid(root: Path, relative: str) -> str:
    return text_output(git(root, ["hash-object", "--", relative])).strip()


def indexed_blob_oid(root: Path, relative: str) -> str:
    return text_output(git(root, ["rev-parse", f":{relative}"])).strip()


def validate_candidate_chunks(root: Path) -> None:
    config = load_config(root)
    _, identity = local_device(config, root)
    receipts = load_receipts(root)
    devices = root / "devices"
    if not devices.exists():
        return
    if devices.is_symlink() or not devices.is_dir():
        raise VaultError("encrypted chunk directory is unsafe")
    for artifact in sorted(devices.rglob("*.jsonl.age")):
        if artifact.is_symlink() or not artifact.is_file():
            raise VaultError("encrypted chunk is unsafe")
        relative = artifact.relative_to(root).as_posix()
        match = CHUNK_PATH_RE.fullmatch(relative)
        if match is None:
            raise VaultError("encrypted chunk path is invalid")
        blob_oid = working_blob_oid(root, relative)
        receipt = receipts.get(relative)
        if receipt is not None and receipt["blob_oid"] != blob_oid:
            raise VaultError("immutable encrypted chunk was replaced")
        plaintext = run(["age", "-d", "-i", str(identity), str(artifact)])
        validate_plaintext(plaintext, match, config)


def validate_plaintext(
    plaintext: bytes,
    match: re.Match[str],
    config: dict[str, object],
) -> tuple[bytes, str]:
    if not plaintext.endswith(b"\n"):
        raise VaultError("decrypted chunk is not canonical JSONL")
    lines = plaintext[:-1].split(b"\n")
    if len(lines) < 2:
        raise VaultError("decrypted chunk is incomplete")
    try:
        header = json.loads(lines[0].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("chunk header is invalid") from error
    if not isinstance(header, dict) or set(header) != HEADER_FIELDS:
        raise VaultError("chunk header is invalid")
    try:
        events = [
            validate_event(json.loads(line.decode("utf-8"))) for line in lines[1:]
        ]
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise VaultError("chunk event is invalid") from error
    if lines[0] != canonical_json(header) or any(
        line != canonical_json(event) for line, event in zip(lines[1:], events)
    ):
        raise VaultError("decrypted chunk is not canonical JSONL")

    device_id = match.group("device")
    digest = match.group("digest")
    canonical_events = b"".join(canonical_json(event) + b"\n" for event in events)
    expected_digest = hashlib.sha256(
        DIGEST_DOMAIN
        + str(config["vault_id"]).encode()
        + b"\0"
        + device_id.encode()
        + b"\0"
        + canonical_events
    ).hexdigest()
    first = parse_time(events[0]["recorded_at"]).astimezone(dt.timezone.utc)
    event_version = events[0]["schema_version"]
    if any(event["schema_version"] != event_version for event in events):
        raise VaultError("chunk mixes event schema versions")
    expected_header = {
        "record_type": "chunk_header",
        "schema_version": 1,
        "event_schema_version": event_version,
        "chunk_id": f"sha256:{digest}",
        "vault_id": config["vault_id"],
        "device_id": device_id,
        "created_at": first.isoformat().replace("+00:00", "Z"),
        "event_count": len(events),
    }
    devices = config["devices"]
    assert isinstance(devices, list)
    if (
        header != expected_header
        or digest != expected_digest
        or match.group("year") != f"{first.year:04d}"
        or match.group("month") != f"{first.month:02d}"
        or match.group("day") != f"{first.day:02d}"
        or device_id not in {item["device_id"] for item in devices}
    ):
        raise VaultError("chunk path, header, or digest does not match")
    return plaintext, digest


def import_chunks(root: Path) -> None:
    config = load_config(root)
    _, identity = local_device(config, root)
    receipts = load_receipts(root)
    receipt_directory = safe_subdirectory(root, "index")
    safe_subdirectory(root, "cache", "imported")
    plans: list[tuple[str, re.Match[str], bytes, str, str, Path]] = []
    for relative in tracked_paths(root):
        match = CHUNK_PATH_RE.fullmatch(relative)
        if match is None:
            continue
        artifact = root / relative
        if artifact.is_symlink() or not artifact.is_file():
            raise VaultError("tracked encrypted chunk is missing or unsafe")
        blob_oid = indexed_blob_oid(root, relative)
        receipt = receipts.get(relative)
        if receipt is not None and receipt["blob_oid"] != blob_oid:
            raise VaultError("immutable encrypted chunk was replaced")
        plaintext = run(["age", "-d", "-i", str(identity), str(artifact)])
        canonical_plaintext, digest = validate_plaintext(plaintext, match, config)
        if receipt is not None and receipt["chunk_id"] != f"sha256:{digest}":
            raise VaultError("immutable encrypted chunk receipt conflicts")
        target_directory = (
            root
            / "cache"
            / "imported"
            / match.group("device")
            / match.group("year")
            / match.group("month")
            / match.group("day")
        )
        target = target_directory / f"{digest}.jsonl"
        if target.exists():
            if target.is_symlink() or not target.is_file():
                raise VaultError("imported chunk cache is unsafe")
            if receipt is not None and not secrets.compare_digest(
                target.read_bytes(), canonical_plaintext
            ):
                raise VaultError("imported chunk cache conflicts")
        plans.append(
            (relative, match, canonical_plaintext, digest, blob_oid, target)
        )

    changed = False
    for relative, match, canonical_plaintext, digest, blob_oid, target in plans:
        target_directory = safe_subdirectory(
            root,
            "cache",
            "imported",
            match.group("device"),
            match.group("year"),
            match.group("month"),
            match.group("day"),
        )
        assert target.parent == target_directory
        if not target.exists() or receipts.get(relative) is None:
            # The cache is derived state. Publish atomically so a crash before
            # the receipt update leaves either a complete cache entry or an
            # unreceipted entry that can be safely rebuilt on the next sync.
            atomic_replace(target, canonical_plaintext)
        expected_receipt = {
            "blob_oid": blob_oid,
            "chunk_id": f"sha256:{digest}",
        }
        if receipts.get(relative) != expected_receipt:
            receipts[relative] = expected_receipt
            changed = True
    if changed or not (root / RECEIPT_PATH).exists():
        data = canonical_json({"schema_version": 1, "chunks": receipts}) + b"\n"
        atomic_replace(root / RECEIPT_PATH, data)
        os.chmod(receipt_directory, 0o700)


def push(root: Path) -> None:
    git(root, ["push", "-q", "-u", "origin", "HEAD:main"])


def clear_pending(root: Path) -> None:
    path = root / PENDING_PATH
    try:
        path.unlink()
    except FileNotFoundError:
        return
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_locked(root: Path) -> None:
    rotate_locked(root)
    config = load_config(root)
    remote = config["remote"]
    assert isinstance(remote, str)
    ensure_repository(root, remote)
    pending = root / PENDING_PATH
    device_id, _ = local_device(config, root)
    try:
        strict_preflight(root)
        # Validate allowed-looking files before they ever enter the Git index.
        # This also compares imported artifacts with their immutable blob OID.
        validate_candidate_chunks(root)
        stage_allowlist(root)
        committed = commit_if_needed(root)
    except VaultError as error:
        if pending.exists():
            write_pending(
                root,
                device_id=device_id,
                phase="preflight_pending",
                artifact_paths=[],
                error_category="integrity",
                increment_attempt=True,
            )
        if isinstance(error, SyncFailure):
            raise
        raise permanent_sync_failure() from error
    artifact_paths = changed_artifact_paths(root) if committed else []
    # Record intent before every network operation, including a no-change pull.
    # This makes remote/auth failures observable without involving the hook.
    write_pending(
        root,
        device_id=device_id,
        phase="pull_pending",
        artifact_paths=artifact_paths,
        error_category=None,
    )
    try:
        pull_rebase(root)
    except VaultError as error:
        if pending.exists():
            write_pending(
                root,
                device_id=device_id,
                phase="pull_pending",
                artifact_paths=artifact_paths,
                error_category="rebase",
                increment_attempt=True,
            )
        if isinstance(error, SyncFailure):
            raise
        raise transient_remote_failure() from error
    try:
        strict_preflight(root)
        verify_after_pull(root, remote)
        import_chunks(root)
    except VaultError as error:
        if pending.exists():
            write_pending(
                root,
                device_id=device_id,
                phase="import_pending",
                artifact_paths=artifact_paths,
                error_category="integrity",
                increment_attempt=True,
            )
        if isinstance(error, SyncFailure):
            raise
        raise permanent_sync_failure() from error
    if pending.exists():
        write_pending(
            root,
            device_id=device_id,
            phase="push_pending",
            artifact_paths=artifact_paths,
            error_category=None,
        )
    try:
        push(root)
    except VaultError as error:
        if pending.exists():
            write_pending(
                root,
                device_id=device_id,
                phase="push_pending",
                artifact_paths=artifact_paths,
                error_category="remote",
                increment_attempt=True,
            )
        if isinstance(error, SyncFailure):
            raise
        raise transient_remote_failure() from error
    clear_pending(root)


def sync(root: Path) -> None:
    with vault_lock(root):
        sync_locked(root)
