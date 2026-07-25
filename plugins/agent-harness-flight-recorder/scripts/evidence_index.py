#!/usr/bin/env python3
"""Build the local, derived SQLite evidence index from imported chunks."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, local_device, safe_subdirectory
from sync import (
    CHUNK_PATH_RE,
    indexed_blob_oid,
    load_receipts,
    validate_plaintext,
    working_blob_oid,
)
from vault import (
    HASH_KEY_PATH,
    VaultError,
    ensure_safe_existing_root,
    fsync_directory,
    load_config,
    vault_lock,
    verify_recipient_state_hmac,
)


DATABASE_PATH = Path("index/vault.sqlite")
INDEX_VERSION = 2
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
CREATE TABLE relationship_edges (
    policy_version TEXT NOT NULL,
    left_event_id TEXT NOT NULL,
    right_event_id TEXT NOT NULL,
    score INTEGER NOT NULL,
    decision TEXT NOT NULL CHECK (
        decision IN ('link', 'no_link', 'hard_veto', 'component_conflict')
    ),
    evidence_json TEXT NOT NULL,
    PRIMARY KEY (policy_version, left_event_id, right_event_id),
    CHECK (left_event_id < right_event_id),
    FOREIGN KEY (policy_version) REFERENCES relationship_policies(policy_version)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (left_event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    FOREIGN KEY (right_event_id) REFERENCES source_events(event_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
) WITHOUT ROWID;
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
"""
METADATA = (
    ("event_schema_versions", "1,2"),
    ("index_role", "derived_rebuildable"),
    ("schema_version", "2"),
    ("source_of_truth", "encrypted_chunk_v1_event_v1_v2"),
)


@dataclass(frozen=True)
class Chunk:
    chunk_row: tuple[Any, ...]
    event_rows: tuple[tuple[Any, ...], ...]
    provenance_row: tuple[Any, ...]


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


def insert_chunk(connection: sqlite3.Connection, chunk: Chunk) -> None:
    connection.execute(
        "INSERT INTO source_chunks VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        chunk.chunk_row,
    )
    connection.executemany(
        "INSERT INTO source_events VALUES "
        "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        chunk.event_rows,
    )
    connection.execute(
        "INSERT INTO import_provenance VALUES (?, ?, ?, ?, ?, ?)",
        chunk.provenance_row,
    )


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
    if _schema_signature(connection) != expected_signature():
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
        from relationship_graph import DEFAULT_POLICY, rebuild_relationships

        rebuild_relationships(connection, DEFAULT_POLICY)
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
        for chunk in chunks:
            if _existing_chunk(connection, chunk):
                continue
            insert_chunk(connection, chunk)
            added_chunks += 1
            added_events += len(chunk.event_rows)
        validate_database(connection)
        validate_source_projection(connection, chunks, exact=True)
        policies = load_stored_policies(connection)
        for policy in policies:
            rebuild_relationships(connection, policy)
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
    return added_chunks, added_events


def rebuild_index_locked(root: Path, *, incremental: bool) -> None:
    index = safe_index_directory(root)
    collect_stale_temporaries(index)
    chunks = load_chunks(root)
    if incremental:
        added_chunks, added_events = rebuild_incremental(root, chunks)
        mode = "incremental"
    else:
        added_chunks, added_events = rebuild_full(root, chunks)
        mode = "full"
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
        chunks = load_chunks(root)
        connection = _open_existing(root / DATABASE_PATH)
        try:
            validate_source_projection(connection, chunks, exact=True)
            connection.execute("BEGIN IMMEDIATE")
            validate_source_projection(connection, chunks, exact=True)
            edges, episodes = rebuild_relationships(connection, policy)
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
        print(
            "rebuild-relationships: "
            f"policy={policy['policy_version']} edges={edges} episodes={episodes}"
        )
