#!/usr/bin/env python3
"""Build the local, derived SQLite evidence index from imported chunks."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import sqlite3
import stat
import tempfile
import datetime as dt
import re
import secrets
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from chunk_rotation import (
    atomic_replace,
    canonical_json,
    local_device,
    safe_subdirectory,
)
from sync import (
    CHUNK_PATH_RE,
    git,
    indexed_blob_oid,
    load_receipts,
    strict_preflight,
    validate_plaintext,
    working_blob_oid,
)
from vault import (
    HASH_KEY_PATH,
    VaultError,
    authorized_key,
    ensure_safe_existing_root,
    fsync_directory,
    load_config,
    vault_lock,
    verify_recipient_state_hmac,
)


DATABASE_PATH = Path("index/vault.sqlite")
INDEX_SEAL_PATH = Path("index/index-seal.json")
INDEX_SEAL_CONTRACT = "authenticated-evidence-index-seal-v1"
MAX_INDEX_SEAL_BYTES = 64 * 1024
FILE_DIGEST_CHUNK_BYTES = 1024 * 1024
GENERATION_NAMESPACE = "authenticated_index_seal"
GENERATION_KEY = "projection_generation"
GENERATION_POLICY = "_global"
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
INDEX_VERSION = 5


class FullRebuildRequired(VaultError):
    """A legal source shape that bounded incremental refresh cannot absorb."""

    diagnostic_code = "full_rebuild_required"


DETERMINISTIC_COLLECTOR_VERSION = "deterministic-v1"
DETERMINISTIC_METRICS = (
    "duration_ms",
    "duration_api_ms",
    "tool_duration_ms",
    "num_turns",
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
    "total_cost_usd",
    "retry_count",
)
SCHEMA = """
CREATE TABLE schema_metadata (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE source_chunks (
    chunk_id TEXT PRIMARY KEY NOT NULL,
    source_path TEXT UNIQUE NOT NULL,
    git_blob_oid TEXT NOT NULL,
    vault_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    event_schema_version INTEGER NOT NULL,
    event_count INTEGER NOT NULL CHECK (event_count > 0),
    canonical_plaintext_sha256 TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE source_events (
    event_id TEXT PRIMARY KEY NOT NULL,
    chunk_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    schema_version INTEGER NOT NULL,
    recorded_at TEXT NOT NULL,
    harness TEXT NOT NULL,
    source_event TEXT NOT NULL,
    event_kind TEXT NOT NULL,
    session_id_hash TEXT,
    turn_id_hash TEXT,
    workspace_id TEXT,
    model TEXT,
    permission_mode TEXT,
    tool TEXT,
    metrics_json TEXT,
    outcome_json TEXT,
    operation_kind TEXT CHECK (
        operation_kind IS NULL OR operation_kind IN (
            'test', 'build', 'lint', 'git_commit', 'pull_request'
        )
    ),
    relationship_task_id_hash TEXT,
    relationship_task_source TEXT,
    relationship_branch_or_worktree_id TEXT,
    relationship_changed_file_fingerprints_json TEXT,
    relationship_changed_files_state TEXT,
    canonical_event_json TEXT NOT NULL,
    UNIQUE (chunk_id, ordinal),
    FOREIGN KEY (chunk_id) REFERENCES source_chunks(chunk_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE import_provenance (
    chunk_id TEXT PRIMARY KEY NOT NULL,
    source_path TEXT UNIQUE NOT NULL,
    git_blob_oid TEXT NOT NULL,
    cache_path TEXT UNIQUE NOT NULL,
    receipt_schema_version INTEGER NOT NULL,
    index_schema_version INTEGER NOT NULL,
    FOREIGN KEY (chunk_id) REFERENCES source_chunks(chunk_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE deterministic_evidence (
    evidence_id TEXT PRIMARY KEY NOT NULL,
    source_event_id TEXT NOT NULL,
    collector_version TEXT NOT NULL,
    collected_at TEXT NOT NULL,
    evidence_type TEXT NOT NULL,
    state TEXT NOT NULL CHECK (
        state IN ('present', 'success', 'failure', 'unknown', 'missing')
    ),
    value_json TEXT,
    UNIQUE (source_event_id, collector_version, evidence_type),
    FOREIGN KEY (source_event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE derived_state (
    namespace TEXT NOT NULL,
    key TEXT NOT NULL,
    policy_version TEXT NOT NULL,
    value_json TEXT NOT NULL,
    PRIMARY KEY (namespace, key, policy_version)
) WITHOUT ROWID;
CREATE TABLE relationship_policies (
    policy_version TEXT PRIMARY KEY NOT NULL,
    schema_version INTEGER NOT NULL,
    policy_sha256 TEXT NOT NULL,
    policy_json TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE relationship_evidence (
    policy_version TEXT NOT NULL,
    evidence_id TEXT NOT NULL,
    evidence_json TEXT NOT NULL,
    PRIMARY KEY (policy_version, evidence_id),
    UNIQUE (policy_version, evidence_json),
    FOREIGN KEY (policy_version) REFERENCES relationship_policies(policy_version)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE relationship_edges (
    policy_version TEXT NOT NULL,
    left_event_id TEXT NOT NULL,
    right_event_id TEXT NOT NULL,
    score INTEGER NOT NULL,
    decision TEXT NOT NULL CHECK (
        decision IN ('link', 'no_link', 'hard_veto', 'component_conflict')
    ),
    evidence_id TEXT NOT NULL,
    PRIMARY KEY (policy_version, left_event_id, right_event_id),
    CHECK (left_event_id < right_event_id),
    FOREIGN KEY (policy_version) REFERENCES relationship_policies(policy_version)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (left_event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (right_event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (policy_version, evidence_id)
        REFERENCES relationship_evidence(policy_version, evidence_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE INDEX relationship_edges_link_candidates
ON relationship_edges (
    policy_version, score DESC, left_event_id, right_event_id, decision
)
WHERE decision IN ('link', 'component_conflict');
CREATE TABLE episodes (
    policy_version TEXT NOT NULL,
    episode_id TEXT NOT NULL,
    member_count INTEGER NOT NULL CHECK (member_count > 0),
    PRIMARY KEY (policy_version, episode_id),
    FOREIGN KEY (policy_version) REFERENCES relationship_policies(policy_version)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE episode_members (
    policy_version TEXT NOT NULL,
    episode_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
    PRIMARY KEY (policy_version, episode_id, event_id),
    UNIQUE (policy_version, event_id),
    UNIQUE (policy_version, episode_id, ordinal),
    FOREIGN KEY (policy_version, episode_id)
        REFERENCES episodes(policy_version, episode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE TABLE session_atlas_facets (
    policy_version TEXT NOT NULL,
    episode_id TEXT NOT NULL,
    context_identity_state TEXT NOT NULL CHECK (
        context_identity_state IN ('present', 'mixed', 'unknown')
    ),
    context_identity_value_json TEXT,
    event_lifecycle_state TEXT NOT NULL CHECK (
        event_lifecycle_state IN ('present', 'mixed', 'unknown')
    ),
    event_lifecycle_value_json TEXT,
    operation_state TEXT NOT NULL CHECK (
        operation_state IN ('present', 'mixed', 'unknown')
    ),
    operation_value_json TEXT,
    artifact_change_state TEXT NOT NULL CHECK (
        artifact_change_state IN ('present', 'mixed', 'unknown')
    ),
    artifact_change_value_json TEXT,
    PRIMARY KEY (policy_version, episode_id),
    FOREIGN KEY (policy_version, episode_id)
        REFERENCES episodes(policy_version, episode_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
CREATE INDEX source_chunks_by_device_time
    ON source_chunks(device_id, created_at);
CREATE INDEX source_events_by_time
    ON source_events(recorded_at);
CREATE INDEX source_events_by_kind_time
    ON source_events(event_kind, recorded_at);
CREATE INDEX source_events_by_session_time
    ON source_events(session_id_hash, recorded_at);
CREATE INDEX source_events_by_workspace_time
    ON source_events(workspace_id, recorded_at);
CREATE INDEX deterministic_evidence_by_source
    ON deterministic_evidence(source_event_id, evidence_type);
CREATE INDEX session_atlas_by_context
    ON session_atlas_facets(
        policy_version, context_identity_state,
        context_identity_value_json, episode_id
    );
CREATE INDEX session_atlas_by_lifecycle
    ON session_atlas_facets(
        policy_version, event_lifecycle_state,
        event_lifecycle_value_json, episode_id
    );
CREATE INDEX session_atlas_by_operation
    ON session_atlas_facets(
        policy_version, operation_state, operation_value_json, episode_id
    );
CREATE INDEX session_atlas_by_artifact
    ON session_atlas_facets(
        policy_version, artifact_change_state,
        artifact_change_value_json, episode_id
    );
"""
METADATA = (
    ("event_schema_versions", "1,2,3"),
    ("index_role", "derived_rebuildable"),
    ("schema_version", "5"),
    ("source_of_truth", "encrypted_chunk_v1_event_v1_v2_v3"),
)


@dataclass(frozen=True)
class Chunk:
    chunk_row: tuple[Any, ...]
    event_rows: tuple[tuple[Any, ...], ...]
    provenance_row: tuple[Any, ...]


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _stream_file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) != 0o600
        ):
            raise VaultError(
                "evidence index digest input is unsafe; run a full rebuild"
            )
        while True:
            chunk = os.read(descriptor, FILE_DIGEST_CHUNK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mtime_ns",
            "st_mode",
            "st_uid",
            "st_nlink",
        )
        if any(
            getattr(before, field) != getattr(after, field)
            for field in stable_fields
        ):
            raise VaultError("evidence index changed while hashing")
    except VaultError:
        raise
    except OSError as error:
        raise VaultError("evidence index digest failed; run a full rebuild") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return "sha256:" + digest.hexdigest()


def _derive_database_generation(connection: sqlite3.Connection) -> str:
    """Derive a stable generation without materializing the relationship graph."""
    digest = hashlib.sha256()
    digest.update(b"flight-recorder-index-generation-v1\0")
    for table, query in (
        (
            "source_chunks",
            "SELECT chunk_id,source_path,git_blob_oid,canonical_plaintext_sha256 "
            "FROM source_chunks ORDER BY chunk_id",
        ),
        (
            "relationship_policies",
            "SELECT policy_version,schema_version,policy_sha256,policy_json "
            "FROM relationship_policies ORDER BY policy_version",
        ),
    ):
        digest.update(table.encode("ascii") + b"\0")
        for row in connection.execute(query):
            digest.update(canonical_json(tuple(row)) + b"\n")
    return "sha256:" + digest.hexdigest()


def _write_database_generation(
    connection: sqlite3.Connection, generation: str | None = None
) -> str:
    selected = generation or _derive_database_generation(connection)
    connection.execute(
        "INSERT OR REPLACE INTO derived_state "
        "(namespace,key,policy_version,value_json) VALUES (?,?,?,?)",
        (
            GENERATION_NAMESPACE,
            GENERATION_KEY,
            GENERATION_POLICY,
            json.dumps(selected),
        ),
    )
    return selected


def read_database_generation(connection: sqlite3.Connection) -> str:
    row = connection.execute(
        "SELECT value_json FROM derived_state "
        "WHERE namespace=? AND key=? AND policy_version=?",
        (GENERATION_NAMESPACE, GENERATION_KEY, GENERATION_POLICY),
    ).fetchone()
    try:
        value = json.loads(row[0]) if row is not None else None
    except (TypeError, json.JSONDecodeError) as error:
        raise VaultError("evidence index generation is invalid; run a full rebuild") from error
    if (
        not isinstance(value, str)
        or not value.startswith("sha256:")
        or len(value) != 71
    ):
        raise VaultError("evidence index generation is missing; run a full rebuild")
    return value


def _authorized_seal_key(root: Path) -> tuple[dict[str, object], bytes]:
    config = load_config(root)
    key_path = root / HASH_KEY_PATH
    descriptor = -1
    try:
        descriptor = os.open(
            key_path,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        key = os.read(descriptor, 33)
    except OSError as error:
        raise VaultError("local correlation key is missing or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    envelope_key = authorized_key(root, None)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or len(key) != 32
        or not secrets.compare_digest(key, envelope_key)
    ):
        raise VaultError("local correlation key does not match the envelope")
    verify_recipient_state_hmac(config, key)
    return config, key


def _source_inventory(
    root: Path, included_paths: set[str] | None = None
) -> dict[str, Any]:
    indexed = strict_preflight(root)
    receipts = load_receipts(root)
    tracked = {
        path for path in indexed
        if CHUNK_PATH_RE.fullmatch(path) is not None
    }
    if set(receipts) != tracked:
        raise VaultError("index seal source inventory is invalid; run a rebuild")
    if included_paths is not None and not included_paths.issubset(receipts):
        raise VaultError("index seal source horizon is invalid; run a rebuild")
    paths = sorted(receipts)
    working: dict[str, str] = {}
    for offset in range(0, len(paths), 500):
        batch = paths[offset : offset + 500]
        try:
            values = git(root, ["hash-object", "--", *batch]).stdout.decode(
                "utf-8"
            ).splitlines()
        except UnicodeError as error:
            raise VaultError(
                "index seal source inventory is invalid; run a rebuild"
            ) from error
        if len(values) != len(batch) or any(
            re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value) is None
            for value in values
        ):
            raise VaultError(
                "index seal source inventory is invalid; run a rebuild"
            )
        working.update(zip(batch, values, strict=True))
    normalized = []
    for relative, receipt in sorted(receipts.items()):
        path = root / relative
        try:
            metadata = path.lstat()
        except OSError as error:
            raise VaultError("index seal source inventory is unsafe") from error
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or working.get(relative) != receipt["blob_oid"]
            or indexed.get(relative) != receipt["blob_oid"]
        ):
            raise VaultError("index seal source inventory is invalid; run a rebuild")
        if included_paths is None or relative in included_paths:
            normalized.append({"source_path": relative, **receipt})
    return {
        "chunk_count": len(normalized),
        "sha256": _sha256(canonical_json(normalized)),
    }


def _forget_inventory(root: Path) -> dict[str, Any]:
    from retention_state import load_forgotten

    entries = [
        {"policy_version": policy, "episode_id": episode}
        for policy, episode in sorted(load_forgotten(root))
    ]
    return {"entry_count": len(entries), "sha256": _sha256(canonical_json(entries))}


def _schema_inventory(connection: sqlite3.Connection) -> dict[str, Any]:
    schema_rows = [
        tuple(row) for row in connection.execute(
            "SELECT type,name,sql FROM sqlite_master "
            "WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
        )
    ]
    metadata = [
        tuple(row) for row in connection.execute(
            "SELECT key,value FROM schema_metadata ORDER BY key"
        )
    ]
    return {
        "user_version": connection.execute("PRAGMA user_version").fetchone()[0],
        "signature_sha256": _sha256(canonical_json(schema_rows)),
        "metadata_sha256": _sha256(canonical_json(metadata)),
    }


def _relationship_inventory(connection: sqlite3.Connection) -> dict[str, Any]:
    policies = [
        tuple(row) for row in connection.execute(
            "SELECT * FROM relationship_policies ORDER BY policy_version"
        )
    ]
    generation = read_database_generation(connection)
    return {
        "generation": generation,
        "policy_count": len(policies),
        "policy_inventory_sha256": _sha256(canonical_json(policies)),
    }


def _seal_mac(value: dict[str, Any], key: bytes) -> str:
    return "sha256:" + hmac.new(
        key, canonical_json(value), hashlib.sha256
    ).hexdigest()


def _reject_duplicate_json_keys(
    pairs: list[tuple[str, Any]],
) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def issue_index_seal(
    root: Path, source_horizon_paths: set[str] | None = None
) -> dict[str, Any]:
    """Issue a seal while the caller holds the Vault lock."""
    database_path = root / DATABASE_PATH
    identity_before = _check_existing_database(database_path)
    connection = _open_readonly(database_path)
    try:
        generation = read_database_generation(connection)
        schema_inventory = _schema_inventory(connection)
        relationship_inventory = _relationship_inventory(connection)
        event_count = connection.execute(
            "SELECT COUNT(*) FROM source_events"
        ).fetchone()[0]
    finally:
        connection.close()
    source_inventory = _source_inventory(root, source_horizon_paths)
    source_inventory["event_count"] = event_count
    config, key = _authorized_seal_key(root)
    digest = _stream_file_sha256(database_path)
    if _check_existing_database(database_path) != identity_before:
        raise VaultError("evidence index changed while sealing")
    metadata = database_path.stat()
    unsigned = {
        "schema_version": 1,
        "contract_version": INDEX_SEAL_CONTRACT,
        "issued_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "database": {
            "sha256": digest,
            "size_bytes": metadata.st_size,
            "device": metadata.st_dev,
            "inode": metadata.st_ino,
            "mtime_ns": metadata.st_mtime_ns,
            "mode": stat.S_IMODE(metadata.st_mode),
            "vault_id": config["vault_id"],
            "generation": generation,
        },
        "index_schema": schema_inventory,
        "source_inventory": source_inventory,
        "forget_inventory": _forget_inventory(root),
        "relationship_projection": relationship_inventory,
    }
    seal = {
        **unsigned,
        "integrity": {
            "algorithm": "hmac-sha256",
            "mac": _seal_mac(unsigned, key),
        },
    }
    encoded = canonical_json(seal) + b"\n"
    if len(encoded) > MAX_INDEX_SEAL_BYTES:
        raise VaultError("evidence index seal exceeds size limit")
    atomic_replace(root / INDEX_SEAL_PATH, encoded)
    return seal


def load_index_seal(root: Path) -> dict[str, Any]:
    path = root / INDEX_SEAL_PATH
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size > MAX_INDEX_SEAL_BYTES
        ):
            raise VaultError("evidence index seal is unsafe; run a rebuild")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_INDEX_SEAL_BYTES + 1)
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_json_keys)
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("evidence index seal is invalid; run a rebuild") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(value, dict) or not _valid_index_seal_shape(value):
        raise VaultError("evidence index seal is invalid; run a rebuild")
    integrity = value.get("integrity")
    if not isinstance(integrity, dict) or set(integrity) != {"algorithm", "mac"}:
        raise VaultError("evidence index seal integrity is invalid; run a rebuild")
    unsigned = {key: item for key, item in value.items() if key != "integrity"}
    _config, key = _authorized_seal_key(root)
    if integrity.get("algorithm") != "hmac-sha256" or not hmac.compare_digest(
        str(integrity.get("mac")), _seal_mac(unsigned, key)
    ):
        raise VaultError("evidence index seal integrity mismatch; run a rebuild")
    return value


def _is_int(value: object, *, minimum: int = 0) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= minimum


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and SHA256_RE.fullmatch(value) is not None


def _valid_index_seal_shape(value: dict[str, Any]) -> bool:
    if set(value) != {
        "schema_version",
        "contract_version",
        "issued_at",
        "database",
        "index_schema",
        "source_inventory",
        "forget_inventory",
        "relationship_projection",
        "integrity",
    }:
        return False
    if (
        value.get("schema_version") != 1
        or value.get("contract_version") != INDEX_SEAL_CONTRACT
        or not isinstance(value.get("issued_at"), str)
    ):
        return False
    issued_text = value["issued_at"]
    if not issued_text.endswith("Z"):
        return False
    try:
        issued_at = dt.datetime.fromisoformat(issued_text[:-1] + "+00:00")
    except ValueError:
        return False
    if (
        issued_at.tzinfo is None
        or issued_at.utcoffset() != dt.timedelta(0)
        or issued_at.isoformat().replace("+00:00", "Z") != issued_text
    ):
        return False

    database = value.get("database")
    if not isinstance(database, dict) or set(database) != {
        "sha256",
        "size_bytes",
        "device",
        "inode",
        "mtime_ns",
        "mode",
        "vault_id",
        "generation",
    }:
        return False
    try:
        vault_id = database.get("vault_id", "")
        parsed_vault_id = uuid.UUID(vault_id)
    except (AttributeError, TypeError, ValueError):
        return False
    if str(parsed_vault_id) != vault_id:
        return False
    if not (
        _is_sha256(database.get("sha256"))
        and _is_sha256(database.get("generation"))
        and _is_int(database.get("size_bytes"), minimum=1)
        and _is_int(database.get("device"))
        and _is_int(database.get("inode"), minimum=1)
        and _is_int(database.get("mtime_ns"))
        and database.get("mode") == 0o600
    ):
        return False

    index_schema = value.get("index_schema")
    if not isinstance(index_schema, dict) or set(index_schema) != {
        "user_version",
        "signature_sha256",
        "metadata_sha256",
    }:
        return False
    if not (
        index_schema.get("user_version") == INDEX_VERSION
        and _is_sha256(index_schema.get("signature_sha256"))
        and _is_sha256(index_schema.get("metadata_sha256"))
    ):
        return False

    source = value.get("source_inventory")
    if not isinstance(source, dict) or set(source) != {
        "chunk_count",
        "event_count",
        "sha256",
    }:
        return False
    if not (
        _is_int(source.get("chunk_count"))
        and _is_int(source.get("event_count"))
        and _is_sha256(source.get("sha256"))
    ):
        return False

    forgotten = value.get("forget_inventory")
    if not isinstance(forgotten, dict) or set(forgotten) != {
        "entry_count",
        "sha256",
    }:
        return False
    if not (
        _is_int(forgotten.get("entry_count"))
        and _is_sha256(forgotten.get("sha256"))
    ):
        return False

    relationship = value.get("relationship_projection")
    if not isinstance(relationship, dict) or set(relationship) != {
        "generation",
        "policy_count",
        "policy_inventory_sha256",
    }:
        return False
    if not (
        relationship.get("generation") == database.get("generation")
        and _is_sha256(relationship.get("generation"))
        and _is_int(relationship.get("policy_count"), minimum=1)
        and _is_sha256(relationship.get("policy_inventory_sha256"))
    ):
        return False

    integrity = value.get("integrity")
    return (
        isinstance(integrity, dict)
        and set(integrity) == {"algorithm", "mac"}
        and integrity.get("algorithm") == "hmac-sha256"
        and _is_sha256(integrity.get("mac"))
    )


def _validate_sealed_source_inventory(
    root: Path, seal: dict[str, Any]
) -> None:
    current = _source_inventory(root)
    expected = seal.get("source_inventory")
    if (
        not isinstance(expected, dict)
        or current.get("chunk_count") != expected.get("chunk_count")
        or current.get("sha256") != expected.get("sha256")
    ):
        raise VaultError("source inventory changed; run a rebuild")
    _validate_sealed_forget_inventory(root, seal)


def _validate_sealed_forget_inventory(
    root: Path, seal: dict[str, Any]
) -> None:
    if _forget_inventory(root) != seal.get("forget_inventory"):
        raise VaultError("forget inventory changed; run a rebuild")


def _reject_sqlite_sidecars(root: Path) -> None:
    database = root / DATABASE_PATH
    for suffix in ("-wal", "-shm", "-journal"):
        path = Path(str(database) + suffix)
        if path.exists() or path.is_symlink():
            raise VaultError("evidence index sidecar is present; run a full rebuild")


def _sealed_database_identity(root: Path, seal: dict[str, Any]) -> tuple[int, int, int, int]:
    _reject_sqlite_sidecars(root)
    database = root / DATABASE_PATH
    identity = _check_existing_database(database)
    metadata = database.stat()
    expected = seal.get("database")
    if (
        not isinstance(expected, dict)
        or expected.get("device") != metadata.st_dev
        or expected.get("inode") != metadata.st_ino
        or expected.get("size_bytes") != metadata.st_size
        or expected.get("mtime_ns") != metadata.st_mtime_ns
        or expected.get("mode") != stat.S_IMODE(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise VaultError("evidence index seal does not match database; run a rebuild")
    config = load_config(root)
    if expected.get("vault_id") != config.get("vault_id"):
        raise VaultError("evidence index seal does not match Vault; run a rebuild")
    return identity


def _open_sealed_readonly(
    root: Path, seal: dict[str, Any]
) -> sqlite3.Connection:
    identity = _sealed_database_identity(root, seal)
    path = root / DATABASE_PATH
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            f"file:{path}?mode=ro&nofollow=1",
            uri=True,
            isolation_level=None,
        )
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA trusted_schema = OFF")
        connection.execute("PRAGMA foreign_keys = ON")
        mode = connection.execute("PRAGMA journal_mode").fetchone()
        if mode is None or str(mode[0]).lower() != "delete":
            raise VaultError("evidence index journal mode is unsupported; run a full rebuild")
        if _schema_inventory(connection) != seal.get("index_schema"):
            raise VaultError("evidence index schema seal mismatch; run a full rebuild")
        generation = read_database_generation(connection)
        if (
            generation != seal.get("database", {}).get("generation")
            or _relationship_inventory(connection)
            != seal.get("relationship_projection")
        ):
            raise VaultError("evidence index generation seal mismatch; run a rebuild")
        if _check_existing_database(path) != identity:
            raise VaultError("evidence index changed during sealed validation")
        return connection
    except VaultError:
        if connection is not None:
            connection.close()
        raise
    except sqlite3.Error as error:
        if connection is not None:
            connection.close()
        raise VaultError("evidence index sealed read failed; run a rebuild") from error


def _target_episode_edges(
    connection: sqlite3.Connection,
    policy_version: str,
    episode_id: str,
) -> dict[str, list[dict[str, Any]]]:
    member_ids = [
        row[0]
        for row in connection.execute(
            "SELECT event_id FROM episode_members "
            "WHERE policy_version=? AND episode_id=? ORDER BY event_id",
            (policy_version, episode_id),
        )
    ]
    edges = []
    # SQLite's primary key starts with (policy_version, left_event_id), so
    # bounded member batches avoid scanning every edge in the policy.
    for offset in range(0, len(member_ids), 500):
        batch = member_ids[offset:offset + 500]
        placeholders = ",".join("?" for _item in batch)
        rows = connection.execute(
            "SELECT edge.left_event_id,edge.right_event_id,edge.score,"
            "edge.decision,evidence.evidence_json "
            "FROM relationship_edges AS edge "
            "JOIN relationship_evidence AS evidence "
            "ON evidence.policy_version=edge.policy_version "
            "AND evidence.evidence_id=edge.evidence_id "
            "WHERE edge.policy_version=? "
            f"AND left_event_id IN ({placeholders}) AND decision='link' "
            "ORDER BY left_event_id,right_event_id",
            (policy_version, *batch),
        )
        for left, right, score, decision, encoded in rows:
            try:
                evidence = json.loads(encoded)
            except (TypeError, json.JSONDecodeError) as error:
                raise VaultError("relationship evidence is invalid") from error
            edges.append({
                "left_event_id": left,
                "right_event_id": right,
                "score": score,
                "decision": decision,
                "evidence": evidence,
            })
    edges.sort(key=lambda item: (item["left_event_id"], item["right_event_id"]))
    return {episode_id: edges} if edges else {}


def _read_episode_projection(
    root: Path,
    seal: dict[str, Any],
    policy_version: str,
    episode_id: str,
) -> dict[str, Any]:
    from reporting import _episode_card, _policy
    from session_atlas import read_session_atlas_facets

    connection = _open_sealed_readonly(root, seal)
    identity = _check_existing_database(root / DATABASE_PATH)
    try:
        connection.execute("BEGIN")
        policy = _policy(connection, policy_version)
        edges = _target_episode_edges(connection, policy_version, episode_id)
        card, supporting = _episode_card(
            root, connection, policy, episode_id, edges
        )
        atlas = read_session_atlas_facets(
            connection, policy_version, episode_id
        )
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
    if _check_existing_database(root / DATABASE_PATH) != identity:
        raise VaultError("evidence index changed during sealed read")
    return {
        "card": card,
        "supporting_edges": supporting,
        "policy": policy,
        "session_atlas_facets": atlas,
    }


def read_sealed_episode(
    root: Path, policy_version: str, episode_id: str
) -> dict[str, Any]:
    with vault_lock(root):
        seal = load_index_seal(root)
        _validate_sealed_source_inventory(root, seal)
        _sealed_database_identity(root, seal)
    result = _read_episode_projection(root, seal, policy_version, episode_id)
    with vault_lock(root):
        current = load_index_seal(root)
        if current != seal:
            raise VaultError("evidence index seal changed during sealed read")
        _validate_sealed_source_inventory(root, current)
        _sealed_database_identity(root, current)
    return result


def read_sealed_query_locked(
    root: Path,
    policy_version: str,
    query: Any,
    trusted_policy: dict[str, Any] | None = None,
) -> Any:
    from relationship_graph import load_stored_policies

    seal = load_index_seal(root)
    _validate_sealed_source_inventory(root, seal)
    _sealed_database_identity(root, seal)
    connection = _open_sealed_readonly(root, seal)
    try:
        connection.execute("BEGIN")
        policies = {
            item["policy_version"]: item
            for item in load_stored_policies(connection)
        }
        policy = policies.get(policy_version)
        if policy is None:
            raise VaultError("relationship policy version was not found")
        if trusted_policy is not None and canonical_json(policy) != canonical_json(trusted_policy):
            raise VaultError("stored relationship policy conflicts")
        result = query(connection, policy)
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
    current = load_index_seal(root)
    if current != seal:
        raise VaultError("evidence index seal changed during sealed read")
    _validate_sealed_source_inventory(root, current)
    _sealed_database_identity(root, current)
    return result


def _authenticate_existing_index_for_write(
    root: Path, *, source_may_advance: bool
) -> None:
    """Authenticate the current DB/seal pair before any in-place mutation."""
    seal = load_index_seal(root)
    _sealed_database_identity(root, seal)
    connection = _open_sealed_readonly(root, seal)
    connection.close()
    if source_may_advance:
        _validate_sealed_forget_inventory(root, seal)
    else:
        _validate_sealed_source_inventory(root, seal)


def _json_text(value: object) -> str | None:
    if value is None:
        return None
    assert isinstance(value, dict)
    return canonical_json(value).decode("utf-8")


def _safe_regular(
    path: Path, description: str, *, root: Path | None = None
) -> bytes:
    if root is None:
        raise VaultError(f"{description} has no trusted root")
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise VaultError(f"{description} is outside the Vault") from error
    if not relative.parts:
        raise VaultError(f"{description} is missing or unsafe")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptors: list[int] = []
    try:
        descriptor = os.open(root, directory_flags)
        descriptors.append(descriptor)
        root_metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != os.geteuid()
        ):
            raise VaultError(f"{description} is missing or unsafe")
        for part in relative.parts[:-1]:
            try:
                descriptor = os.open(
                    part, directory_flags, dir_fd=descriptors[-1]
                )
            except OSError as error:
                raise VaultError(f"{description} is missing or unsafe") from error
            descriptors.append(descriptor)
            parent_metadata = os.fstat(descriptor)
            if (
                not stat.S_ISDIR(parent_metadata.st_mode)
                or parent_metadata.st_uid != os.geteuid()
            ):
                raise VaultError(f"{description} is missing or unsafe")
        try:
            file_descriptor = os.open(
                relative.parts[-1], file_flags, dir_fd=descriptors[-1]
            )
        except OSError as error:
            raise VaultError(f"{description} is missing or unsafe") from error
        descriptors.append(file_descriptor)
        metadata = os.fstat(file_descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise VaultError(f"{description} is missing or unsafe")
        chunks: list[bytes] = []
        while True:
            block = os.read(file_descriptor, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        return b"".join(chunks)
    except OSError as error:
        raise VaultError(f"{description} cannot be read") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _authenticate_local_vault(root: Path) -> dict[str, object]:
    ensure_safe_existing_root(root)
    config = load_config(root)
    key = _safe_regular(
        root / HASH_KEY_PATH, "local correlation key", root=root
    )
    if len(key) != 32:
        raise VaultError("local correlation key has an invalid length")
    verify_recipient_state_hmac(config, key)
    local_device(config, root)
    return config


def load_chunks(root: Path) -> list[Chunk]:
    """Validate receipt-selected cache inputs and return deterministic rows."""
    config = _authenticate_local_vault(root)
    receipts = load_receipts(root)
    cache_root = root / "cache" / "imported"
    receipt_cache_paths: set[str] = set()
    result: list[Chunk] = []
    event_owners: dict[str, str] = {}
    for source_path, receipt in sorted(receipts.items()):
        match = CHUNK_PATH_RE.fullmatch(source_path)
        assert match is not None  # load_receipts has already checked this.
        _safe_regular(
            root / source_path, "encrypted chunk artifact", root=root
        )
        try:
            index_oid = indexed_blob_oid(root, source_path)
            working_oid = working_blob_oid(root, source_path)
        except VaultError:
            raise
        if (
            receipt["blob_oid"] != index_oid
            or receipt["blob_oid"] != working_oid
        ):
            raise VaultError("import receipt Git blob does not match artifact")
        digest = match.group("digest")
        cache_relative = (
            Path("cache/imported")
            / match.group("device")
            / match.group("year")
            / match.group("month")
            / match.group("day")
            / f"{digest}.jsonl"
        )
        receipt_cache_paths.add(cache_relative.as_posix())
        plaintext = _safe_regular(
            root / cache_relative, "imported chunk cache", root=root
        )
        canonical_plaintext, validated_digest = validate_plaintext(
            plaintext, match, config
        )
        chunk_id = f"sha256:{validated_digest}"
        if (
            validated_digest != digest
            or receipt["chunk_id"] != chunk_id
        ):
            raise VaultError("import receipt conflicts with imported chunk")

        lines = canonical_plaintext[:-1].split(b"\n")
        header = json.loads(lines[0])
        events = [json.loads(line) for line in lines[1:]]
        chunk_row = (
            chunk_id,
            source_path,
            receipt["blob_oid"],
            header["vault_id"],
            header["device_id"],
            header["created_at"],
            header["event_schema_version"],
            header["event_count"],
            hashlib.sha256(canonical_plaintext).hexdigest(),
        )
        event_rows: list[tuple[Any, ...]] = []
        for ordinal, event in enumerate(events):
            event_id = event["event_id"]
            previous = event_owners.get(event_id)
            if previous is not None:
                raise VaultError("duplicate event ID across imported chunks")
            event_owners[event_id] = chunk_id
            context = event.get("relationship_context")
            if context is None:
                relationship = (None, None, None, None, None)
            else:
                relationship = (
                    context["task_id_hash"],
                    context["task_source"],
                    context["branch_or_worktree_id"],
                    json.dumps(
                        context["changed_file_fingerprints"],
                        sort_keys=True,
                        separators=(",", ":"),
                    ),
                    context["changed_files_state"],
                )
            event_rows.append(
                (
                    event_id,
                    chunk_id,
                    ordinal,
                    event["schema_version"],
                    event["recorded_at"],
                    event["harness"],
                    event["source_event"],
                    event["event_kind"],
                    event["session_id_hash"],
                    event["turn_id_hash"],
                    event["workspace_id"],
                    event["model"],
                    event["permission_mode"],
                    event["tool"],
                    _json_text(event["metrics"]),
                    _json_text(event["outcome"]),
                    event.get("operation_kind"),
                    *relationship,
                    canonical_json(event).decode("utf-8"),
                )
            )
        provenance_row = (
            chunk_id,
            source_path,
            receipt["blob_oid"],
            cache_relative.as_posix(),
            1,
            INDEX_VERSION,
        )
        result.append(Chunk(chunk_row, tuple(event_rows), provenance_row))
    discovered_cache_paths: set[str] = set()
    if cache_root.exists() or cache_root.is_symlink():
        try:
            cache_metadata = cache_root.lstat()
        except OSError as error:
            raise VaultError("imported chunk cache is unsafe") from error
        if (
            not stat.S_ISDIR(cache_metadata.st_mode)
            or cache_metadata.st_uid != os.geteuid()
        ):
            raise VaultError("imported chunk cache is unsafe")
        for directory, directories, files in os.walk(
            cache_root, followlinks=False
        ):
            directory_path = Path(directory)
            for name in directories:
                child = directory_path / name
                metadata = child.lstat()
                if (
                    not stat.S_ISDIR(metadata.st_mode)
                    or metadata.st_uid != os.geteuid()
                ):
                    raise VaultError("imported chunk cache is unsafe")
            for name in files:
                child = directory_path / name
                if child.suffix != ".jsonl":
                    raise VaultError("imported chunk cache is unsafe")
                _safe_regular(child, "imported chunk cache", root=root)
                discovered_cache_paths.add(
                    child.relative_to(root).as_posix()
                )
    if discovered_cache_paths != receipt_cache_paths:
        raise VaultError("imported chunk cache and receipts disagree")
    return result


def configure(connection: sqlite3.Connection) -> None:
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA trusted_schema = OFF")
    connection.execute("PRAGMA synchronous = FULL")
    mode = connection.execute("PRAGMA journal_mode = DELETE").fetchone()
    if mode is None or str(mode[0]).lower() != "delete":
        raise VaultError("SQLite journal mode is unavailable")


def create_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(SCHEMA)
    connection.execute(f"PRAGMA user_version = {INDEX_VERSION}")
    connection.executemany(
        "INSERT INTO schema_metadata(key, value) VALUES (?, ?)", METADATA
    )


def ensure_incremental_indexes(connection: sqlite3.Connection) -> None:
    """Install additive v5 indexes needed by bounded incremental refresh."""
    connection.execute(
        "CREATE INDEX IF NOT EXISTS relationship_edges_link_candidates "
        "ON relationship_edges ( policy_version, score DESC, left_event_id, "
        "right_event_id, decision ) WHERE decision IN "
        "('link', 'component_conflict')"
    )


def insert_chunk(connection: sqlite3.Connection, chunk: Chunk) -> None:
    connection.execute(
        "INSERT INTO source_chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        chunk.chunk_row,
    )
    connection.executemany(
        "INSERT INTO source_events VALUES "
        "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        chunk.event_rows,
    )
    connection.execute(
        "INSERT INTO import_provenance VALUES (?, ?, ?, ?, ?, ?)",
        chunk.provenance_row,
    )


def _deterministic_evidence_rows(
    connection: sqlite3.Connection,
) -> list[tuple[str, str, str, str, str, str, str | None]]:
    rows: list[tuple[str, str, str, str, str, str, str | None]] = []
    for (
        event_id,
        recorded_at,
        metrics_json,
        outcome_json,
        operation_kind,
    ) in connection.execute(
        """
        SELECT event_id, recorded_at, metrics_json, outcome_json,
               operation_kind
        FROM source_events
        ORDER BY event_id
        """
    ):
        try:
            metrics = (
                json.loads(metrics_json) if metrics_json is not None else {}
            )
            outcome = (
                json.loads(outcome_json) if outcome_json is not None else None
            )
        except (TypeError, json.JSONDecodeError) as error:
            raise VaultError("deterministic evidence source is invalid") from error
        facts: list[tuple[str, str, dict[str, Any] | None]] = []
        if operation_kind is not None:
            state = (
                outcome.get("status")
                if isinstance(outcome, dict)
                and outcome.get("status")
                in ("success", "failure", "unknown")
                else "missing"
            )
            operation_value = (
                {"exit_code": outcome["exit_code"]}
                if isinstance(outcome, dict) and "exit_code" in outcome
                else None
            )
            facts.append((operation_kind, state, operation_value))
        if isinstance(outcome, dict) and "exit_code" in outcome:
            facts.append(
                (
                    "exit_status",
                    "present",
                    {"exit_code": outcome["exit_code"]},
                )
            )
        if not isinstance(metrics, dict):
            raise VaultError("deterministic evidence source is invalid")
        for metric in DETERMINISTIC_METRICS:
            if metric in metrics:
                facts.append((metric, "present", {"value": metrics[metric]}))
        for evidence_type, state, value in facts:
            value_json = (
                canonical_json(value).decode("utf-8")
                if value is not None
                else None
            )
            identity = canonical_json(
                {
                    "collector_version": DETERMINISTIC_COLLECTOR_VERSION,
                    "collected_at": recorded_at,
                    "evidence_type": evidence_type,
                    "source_event_id": event_id,
                    "state": state,
                    "value": value,
                }
            )
            evidence_id = f"sha256:{hashlib.sha256(identity).hexdigest()}"
            rows.append(
                (
                    evidence_id,
                    event_id,
                    DETERMINISTIC_COLLECTOR_VERSION,
                    recorded_at,
                    evidence_type,
                    state,
                    value_json,
                )
            )
    return sorted(rows)


def rebuild_deterministic_evidence(
    connection: sqlite3.Connection,
) -> int:
    rows = _deterministic_evidence_rows(connection)
    connection.execute("DELETE FROM deterministic_evidence")
    connection.executemany(
        "INSERT INTO deterministic_evidence VALUES (?, ?, ?, ?, ?, ?, ?)",
        rows,
    )
    return len(rows)


def validate_database(connection: sqlite3.Connection) -> None:
    foreign_keys = connection.execute("PRAGMA foreign_key_check").fetchall()
    if foreign_keys:
        raise VaultError("SQLite foreign key validation failed")
    integrity = connection.execute("PRAGMA integrity_check").fetchall()
    if integrity != [("ok",)]:
        raise VaultError("SQLite integrity validation failed")


def _schema_signature(connection: sqlite3.Connection) -> dict[str, object]:
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"
        )
        if not row[0].startswith("sqlite_")
    }
    return {
        "version": connection.execute("PRAGMA user_version").fetchone()[0],
        "tables": tables,
        "sql": {
            (row[0], row[1]): " ".join(row[2].split())
            for row in connection.execute(
                "SELECT type, name, sql FROM sqlite_master "
                "WHERE type IN ('table', 'index', 'trigger', 'view') "
                "AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL"
            )
        },
    }


def expected_signature() -> dict[str, object]:
    connection = sqlite3.connect(":memory:")
    try:
        create_schema(connection)
        return _schema_signature(connection)
    finally:
        connection.close()


def legacy_incremental_signature() -> dict[str, object]:
    """Return the authenticated v5 shape from before the additive link index."""
    signature = expected_signature()
    del signature["sql"][("index", "relationship_edges_link_candidates")]
    return signature


def _check_existing_database(path: Path) -> tuple[int, int, int, int]:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        raise VaultError("evidence index does not exist; run a full rebuild")
    except OSError as error:
        raise VaultError("evidence index is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
    ):
        raise VaultError("evidence index is unsafe")
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def _validate_current_database(connection: sqlite3.Connection) -> None:
    mode = connection.execute("PRAGMA journal_mode").fetchone()
    if mode is None or str(mode[0]).lower() != "delete":
        raise VaultError(
            "evidence index journal mode is unsupported; run a full rebuild"
        )
    signature = _schema_signature(connection)
    if signature not in (expected_signature(), legacy_incremental_signature()):
        raise VaultError(
            "evidence index schema is unsupported; run a full rebuild"
        )
    metadata = tuple(
        connection.execute(
            "SELECT key, value FROM schema_metadata ORDER BY key"
        )
    )
    if metadata != tuple(sorted(METADATA)):
        raise VaultError(
            "evidence index metadata is unsupported; run a full rebuild"
        )
    validate_database(connection)


def _open_readonly(path: Path) -> sqlite3.Connection:
    _check_existing_database(path)
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            f"file:{path}?mode=ro&nofollow=1",
            uri=True,
            isolation_level=None,
        )
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA trusted_schema = OFF")
        connection.execute("PRAGMA foreign_keys = ON")
        _validate_current_database(connection)
        return connection
    except VaultError:
        if connection is not None:
            connection.close()
        raise
    except sqlite3.Error as error:
        if connection is not None:
            connection.close()
        raise VaultError(
            "evidence index is invalid; run a full rebuild"
        ) from error


def _open_existing(path: Path) -> sqlite3.Connection:
    validated_identity = _check_existing_database(path)
    readonly = _open_readonly(path)
    readonly.close()
    if _check_existing_database(path) != validated_identity:
        raise VaultError("evidence index changed during validation")
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(
            f"file:{path}?mode=rw&nofollow=1",
            uri=True,
            isolation_level=None,
        )
        configure(connection)
        _validate_current_database(connection)
        return connection
    except VaultError:
        if connection is not None:
            connection.close()
        raise
    except sqlite3.Error as error:
        if connection is not None:
            connection.close()
        raise VaultError(
            "evidence index is invalid; run a full rebuild"
        ) from error


def validate_source_projection(
    connection: sqlite3.Connection,
    chunks: list[Chunk],
    *,
    exact: bool,
) -> None:
    expected_chunks = {chunk.chunk_row[0]: chunk.chunk_row for chunk in chunks}
    expected_provenance = {
        chunk.provenance_row[0]: chunk.provenance_row for chunk in chunks
    }
    expected_events = {
        row[0]: row for chunk in chunks for row in chunk.event_rows
    }
    projections = (
        ("source_chunks", expected_chunks),
        ("import_provenance", expected_provenance),
        ("source_events", expected_events),
    )
    for table, expected in projections:
        actual_rows = [
            tuple(row)
            for row in connection.execute(f"SELECT * FROM {table}")
        ]
        actual = {row[0]: row for row in actual_rows}
        if len(actual) != len(actual_rows) or any(
            expected.get(key) != row for key, row in actual.items()
        ):
            raise VaultError("evidence index source projection conflicts")
        if exact and actual != expected:
            raise VaultError("evidence index source projection is incomplete")


def safe_index_directory(root: Path) -> Path:
    return safe_subdirectory(root, "index")


def collect_stale_temporaries(index: Path) -> None:
    changed = False
    try:
        entries = list(index.iterdir())
    except OSError as error:
        raise VaultError("evidence index directory is unsafe") from error
    for candidate in entries:
        if not candidate.name.startswith(".vault.sqlite."):
            continue
        try:
            metadata = candidate.lstat()
        except OSError as error:
            raise VaultError("stale evidence index temporary is unsafe") from error
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise VaultError("stale evidence index temporary is unsafe")
        try:
            candidate.unlink()
        except OSError as error:
            raise VaultError(
                "stale evidence index temporary cannot be removed"
            ) from error
        changed = True
    if changed:
        fsync_directory(index)


def _existing_chunk(
    connection: sqlite3.Connection, chunk: Chunk
) -> bool:
    chunk_id = chunk.chunk_row[0]
    row = connection.execute(
        "SELECT * FROM source_chunks WHERE chunk_id = ?", (chunk_id,)
    ).fetchone()
    if row is None:
        return False
    provenance = connection.execute(
        "SELECT * FROM import_provenance WHERE chunk_id = ?", (chunk_id,)
    ).fetchone()
    events = tuple(
        connection.execute(
            "SELECT * FROM source_events WHERE chunk_id = ? ORDER BY ordinal",
            (chunk_id,),
        )
    )
    if (
        tuple(row) != chunk.chunk_row
        or provenance is None
        or tuple(provenance) != chunk.provenance_row
        or events != chunk.event_rows
    ):
        raise VaultError("immutable evidence index rows conflict")
    return True


def rebuild_full(root: Path, chunks: list[Chunk]) -> tuple[int, int]:
    index = safe_index_directory(root)
    target = root / DATABASE_PATH
    if target.exists() or target.is_symlink():
        _check_existing_database(target)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".vault.sqlite.", dir=index
    )
    temporary = Path(temporary_name)
    os.fchmod(descriptor, 0o600)
    os.close(descriptor)
    connection: sqlite3.Connection | None = None
    try:
        connection = sqlite3.connect(temporary, isolation_level=None)
        configure(connection)
        create_schema(connection)
        connection.execute("BEGIN IMMEDIATE")
        for chunk in chunks:
            insert_chunk(connection, chunk)
        rebuild_deterministic_evidence(connection)
        from relationship_graph import DEFAULT_POLICY, rebuild_relationships
        from index_storage import cache_index_storage_metrics

        rebuild_relationships(connection, DEFAULT_POLICY)
        cache_index_storage_metrics(connection)
        _write_database_generation(connection)
        connection.execute("COMMIT")
        validate_database(connection)
        connection.close()
        connection = None
        descriptor = os.open(temporary, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        if target.exists() or target.is_symlink():
            _check_existing_database(target)
        os.replace(temporary, target)
        os.chmod(target, 0o600)
        fsync_directory(index)
    except sqlite3.Error as error:
        raise VaultError("failed to build evidence index") from error
    finally:
        if connection is not None:
            connection.close()
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return len(chunks), sum(len(chunk.event_rows) for chunk in chunks)


def rebuild_incremental(root: Path, chunks: list[Chunk]) -> tuple[int, int]:
    target = root / DATABASE_PATH
    connection = _open_existing(target)
    added_chunks = 0
    added_events = 0
    try:
        from relationship_graph import (
            load_stored_policies,
            rebuild_relationships,
        )

        validate_source_projection(connection, chunks, exact=False)
        load_stored_policies(connection)
        connection.execute("BEGIN IMMEDIATE")
        ensure_incremental_indexes(connection)
        for chunk in chunks:
            if _existing_chunk(connection, chunk):
                continue
            insert_chunk(connection, chunk)
            added_chunks += 1
            added_events += len(chunk.event_rows)
        validate_database(connection)
        validate_source_projection(connection, chunks, exact=True)
        rebuild_deterministic_evidence(connection)
        policies = load_stored_policies(connection)
        for policy in policies:
            rebuild_relationships(connection, policy)
        from index_storage import cache_index_storage_metrics

        cache_index_storage_metrics(connection)
        _write_database_generation(connection)
        connection.execute("COMMIT")
    except (sqlite3.Error, VaultError) as error:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        if isinstance(error, VaultError):
            raise
        raise VaultError("incremental evidence import failed") from error
    finally:
        connection.close()
    os.chmod(target, 0o600)
    descriptor = os.open(target, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return added_chunks, added_events


def rebuild_incremental_bounded(
    root: Path, *, max_chunks: int, max_events: int
) -> bool:
    """Import one bounded source delta and return whether more drift remains."""
    if (
        isinstance(max_chunks, bool)
        or not isinstance(max_chunks, int)
        or not 1 <= max_chunks <= 2
        or isinstance(max_events, bool)
        or not isinstance(max_events, int)
        or not 1 <= max_events <= 5_000
    ):
        raise VaultError("incremental refresh bounds are invalid")
    chunks = load_chunks(root)
    target = root / DATABASE_PATH
    connection = _open_existing(target)
    try:
        from index_storage import cache_index_storage_metrics
        from relationship_graph import (
            load_stored_policies,
            refresh_relationships_incremental,
        )

        validate_source_projection(connection, chunks, exact=False)
        existing = {
            row[0] for row in connection.execute("SELECT chunk_id FROM source_chunks")
        }
        pending = [chunk for chunk in chunks if chunk.chunk_row[0] not in existing]
        selected = []
        selected_events = 0
        for chunk in pending:
            event_count = len(chunk.event_rows)
            if event_count > max_events:
                raise FullRebuildRequired(
                    "one legacy source chunk exceeds the refresh event bound"
                )
            if len(selected) >= max_chunks or selected_events + event_count > max_events:
                break
            selected.append(chunk)
            selected_events += event_count
        new_event_ids = {
            row[0] for chunk in selected for row in chunk.event_rows
        }
        connection.execute("BEGIN IMMEDIATE")
        ensure_incremental_indexes(connection)
        for chunk in selected:
            insert_chunk(connection, chunk)
        expected = [
            chunk
            for chunk in chunks
            if chunk.chunk_row[0] in existing
            or chunk.chunk_row[0] in {item.chunk_row[0] for item in selected}
        ]
        validate_source_projection(connection, expected, exact=True)
        rebuild_deterministic_evidence(connection)
        policies = load_stored_policies(connection)
        for policy in policies:
            refresh_relationships_incremental(connection, policy, new_event_ids)
        cache_index_storage_metrics(connection)
        _write_database_generation(connection)
        validate_database(connection)
        connection.execute("COMMIT")
    except (sqlite3.Error, VaultError) as error:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        if isinstance(error, VaultError):
            raise
        raise VaultError("bounded incremental refresh failed") from error
    finally:
        connection.close()
    os.chmod(target, 0o600)
    descriptor = os.open(target, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    horizon_paths = {chunk.provenance_row[1] for chunk in expected}
    issue_index_seal(root, horizon_paths)
    return len(selected) < len(pending)


def rebuild_index_locked(root: Path, *, incremental: bool) -> None:
    index = safe_index_directory(root)
    collect_stale_temporaries(index)
    if incremental:
        _authenticate_existing_index_for_write(
            root, source_may_advance=True
        )
    chunks = load_chunks(root)
    if incremental:
        added_chunks, added_events = rebuild_incremental(root, chunks)
        mode = "incremental"
    else:
        added_chunks, added_events = rebuild_full(root, chunks)
        mode = "full"
    issue_index_seal(root)
    from index_freshness import mark_manual_rebuild_ready_locked

    mark_manual_rebuild_ready_locked(root)
    print(
        f"rebuild-index: mode={mode} "
        f"chunks={added_chunks} events={added_events}"
    )


def rebuild_index(root: Path, *, incremental: bool) -> None:
    with vault_lock(root):
        rebuild_index_locked(root, incremental=incremental)


def rebuild_relationship_views(root: Path, policy_path: Path | None) -> None:
    """Atomically replace one versioned relationship view only."""
    from relationship_graph import load_policy, rebuild_relationships

    # Policy parsing and validation happens before opening a write transaction.
    policy = load_policy(policy_path)
    with vault_lock(root):
        safe_index_directory(root)
        _authenticate_existing_index_for_write(
            root, source_may_advance=False
        )
        chunks = load_chunks(root)
        connection = _open_existing(root / DATABASE_PATH)
        try:
            validate_source_projection(connection, chunks, exact=True)
            connection.execute("BEGIN IMMEDIATE")
            validate_source_projection(connection, chunks, exact=True)
            edges, episodes = rebuild_relationships(connection, policy)
            from index_storage import cache_index_storage_metrics

            cache_index_storage_metrics(connection)
            _write_database_generation(connection)
            validate_database(connection)
            connection.execute("COMMIT")
        except (sqlite3.Error, VaultError) as error:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            if isinstance(error, VaultError):
                raise
            raise VaultError("relationship rebuild failed") from error
        finally:
            connection.close()
        os.chmod(root / DATABASE_PATH, 0o600)
        descriptor = os.open(root / DATABASE_PATH, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        issue_index_seal(root)
        print(
            "rebuild-relationships: "
            f"policy={policy['policy_version']} edges={edges} episodes={episodes}"
        )
