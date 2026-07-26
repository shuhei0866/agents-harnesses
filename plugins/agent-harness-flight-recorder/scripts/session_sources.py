#!/usr/bin/env python3
"""Register owner-controlled raw session logs as local-only source references."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import stat
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, safe_subdirectory
from vault import (
    VaultError,
    atomic_replace,
    authorized_key,
    ensure_managed_gitignore,
    ensure_safe_existing_root,
    load_config,
    vault_lock,
)


OUTPUT_VERSION = 1
RECORD_VERSION = 1
SUPPORTED_ADAPTERS = {"claude-code", "codex"}
MAX_REGISTRATION_BYTES = 16 * 1024
SOURCE_REF_RE = re.compile(r"^hmac-sha256:[0-9a-f]{64}$")
CONTENT_HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
RECORD_FIELDS = {
    "schema_version",
    "source_ref",
    "adapter",
    "path",
    "content_sha256",
    "size_bytes",
    "device",
    "inode",
    "modified_ns",
    "changed_ns",
}


def _source_ref(
    root: Path, adapter: str, path: Path, content_sha256: str
) -> str:
    key = authorized_key(root, None)
    payload = canonical_json(
        {
            "schema_version": 1,
            "adapter": adapter,
            "path": str(path),
            "content_sha256": content_sha256,
        }
    )
    return "hmac-sha256:" + hmac.new(key, payload, hashlib.sha256).hexdigest()


def _read_source(path_argument: Path) -> tuple[Path, str, os.stat_result]:
    if not path_argument.is_absolute():
        raise VaultError("session source path must be absolute")
    if path_argument.is_symlink():
        raise VaultError("session source is unavailable or unsafe")
    try:
        path = path_argument.resolve(strict=True)
    except OSError as error:
        raise VaultError("session source is unavailable or unsafe") from error

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
        ):
            raise VaultError("session source is unavailable or unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            digest = hashlib.sha256()
            size_bytes = 0
            while True:
                chunk = stream.read(64 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                size_bytes += len(chunk)
        after = path.lstat()
    except OSError as error:
        raise VaultError("session source is unavailable or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        not stat.S_ISREG(after.st_mode)
        or after.st_uid != os.geteuid()
        or after.st_nlink != 1
        or after.st_dev != before.st_dev
        or after.st_ino != before.st_ino
        or after.st_size != before.st_size
        or after.st_mtime_ns != before.st_mtime_ns
        or after.st_ctime_ns != before.st_ctime_ns
        or size_bytes != before.st_size
    ):
        raise VaultError("session source changed during registration")
    return path, "sha256:" + digest.hexdigest(), before


def _validate_record(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != RECORD_FIELDS
        or value.get("schema_version") != RECORD_VERSION
        or value.get("adapter") not in SUPPORTED_ADAPTERS
        or not isinstance(value.get("path"), str)
        or not Path(value["path"]).is_absolute()
        or len(value["path"]) > 4096
        or not isinstance(value.get("source_ref"), str)
        or SOURCE_REF_RE.fullmatch(value["source_ref"]) is None
        or not isinstance(value.get("content_sha256"), str)
        or CONTENT_HASH_RE.fullmatch(value["content_sha256"]) is None
    ):
        raise VaultError("stored session source registration is invalid")
    for field in ("size_bytes", "device", "inode", "modified_ns", "changed_ns"):
        item = value.get(field)
        if isinstance(item, bool) or not isinstance(item, int) or item < 0:
            raise VaultError("stored session source registration is invalid")
    return value


def _record_path(root: Path, source_ref: str) -> Path:
    directory = safe_subdirectory(root, "session-sources")
    return directory / f"{source_ref.removeprefix('hmac-sha256:')}.json"


def _read_registration(target: Path) -> dict[str, Any]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(target, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o022
            or metadata.st_size > MAX_REGISTRATION_BYTES
        ):
            raise VaultError("stored session source registration is unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_REGISTRATION_BYTES + 1)
        after = target.lstat()
        if (
            after.st_dev != metadata.st_dev
            or after.st_ino != metadata.st_ino
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
        ):
            raise VaultError("stored session source registration changed")
        value = json.loads(raw)
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError(
            "stored session source registration is unsafe"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return _validate_record(value)


def register(root: Path, adapter: str, path_argument: Path) -> dict[str, Any]:
    if adapter not in SUPPORTED_ADAPTERS:
        raise VaultError("session source adapter is unsupported")
    ensure_safe_existing_root(root)
    load_config(root)
    path, content_sha256, metadata = _read_source(path_argument)
    source_ref = _source_ref(root, adapter, path, content_sha256)
    record: dict[str, Any] = {
        "schema_version": RECORD_VERSION,
        "source_ref": source_ref,
        "adapter": adapter,
        "path": str(path),
        "content_sha256": content_sha256,
        "size_bytes": metadata.st_size,
        "device": metadata.st_dev,
        "inode": metadata.st_ino,
        "modified_ns": metadata.st_mtime_ns,
        "changed_ns": metadata.st_ctime_ns,
    }
    with vault_lock(root):
        ensure_managed_gitignore(root)
        target = _record_path(root, source_ref)
        if target.exists() or target.is_symlink():
            if _read_registration(target) != record:
                raise VaultError("session source registration changed")
        else:
            atomic_replace(target, canonical_json(record) + b"\n")
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "source register",
        "source_ref": source_ref,
        "adapter": adapter,
        "content_sha256": record["content_sha256"],
        "size_bytes": record["size_bytes"],
    }


def load_registered_source(root: Path, source_ref: str) -> dict[str, Any]:
    if (
        not isinstance(source_ref, str)
        or SOURCE_REF_RE.fullmatch(source_ref) is None
    ):
        raise VaultError("session source reference is invalid")
    target = _record_path(root, source_ref)
    record = _read_registration(target)
    if record["source_ref"] != source_ref:
        raise VaultError("session source registration is unavailable or invalid")
    return record


def render_register(value: dict[str, Any]) -> str:
    return "\n".join(
        (
            "Session source registered",
            f"Source ref: {value['source_ref']}",
            f"Adapter: {value['adapter']}",
            f"Content: {value['content_sha256']}",
            f"Size: {value['size_bytes']} bytes",
        )
    )
