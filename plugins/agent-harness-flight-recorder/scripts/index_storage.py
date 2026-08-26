#!/usr/bin/env python3
"""Bounded readers and writer-time cache for Evidence Index storage."""

from __future__ import annotations

import json
import sqlite3
from typing import Any

from chunk_rotation import canonical_json
from vault import VaultError


NAMESPACE = "index-storage-v1"
KEY = "major-components"
POLICY = "global-v1"
WARNING_AT_BYTES = 5_368_709_120
CRITICAL_AT_BYTES = 8_589_934_592
SOURCE_NAMES = {
    "source_chunks",
    "source_events",
    "import_provenance",
    "deterministic_evidence",
}
RELATIONSHIP_NAMES = {
    "relationship_policies",
    "relationship_evidence",
    "relationship_edges",
}
PROJECTION_NAMES = {"episodes", "episode_members", "session_atlas_facets"}
INDEX_OWNERS = {
    "session_atlas_by_context": "session_atlas_facets",
    "session_atlas_by_lifecycle": "session_atlas_facets",
    "session_atlas_by_operation": "session_atlas_facets",
    "session_atlas_by_artifact": "session_atlas_facets",
}


def _category(name: str) -> str | None:
    owner = INDEX_OWNERS.get(name)
    if owner is None and name.startswith("sqlite_autoindex_"):
        owner = name[len("sqlite_autoindex_") :].rsplit("_", 1)[0]
    resolved = owner or name
    for category, names in (
        ("source_bytes", SOURCE_NAMES),
        ("relationship_bytes", RELATIONSHIP_NAMES),
        ("projection_bytes", PROJECTION_NAMES),
    ):
        if resolved in names or any(
            resolved.startswith(f"{item}_") for item in names
        ):
            return category
    return None


def cache_index_storage_metrics(connection: sqlite3.Connection) -> dict[str, Any]:
    totals = {name: 0 for name in (
        "source_bytes", "relationship_bytes", "projection_bytes"
    )}
    try:
        rows = connection.execute(
            "SELECT name,SUM(pgsize) FROM dbstat GROUP BY name ORDER BY name"
        )
        for name, size in rows:
            category = _category(name)
            if category is not None:
                totals[category] += int(size)
    except sqlite3.OperationalError as error:
        # Apple's Python SQLite omits the optional dbstat virtual table. Keep
        # the cache shape available and account those pages as ``other`` on
        # readers; builds must not become platform-dependent.
        if "no such table: dbstat" not in str(error):
            raise VaultError("index storage metrics are unavailable") from error
    except (sqlite3.Error, TypeError, ValueError) as error:
        raise VaultError("index storage metrics are unavailable") from error
    value = {"schema_version": 1, **totals}
    connection.execute(
        "INSERT OR REPLACE INTO derived_state "
        "(namespace,key,policy_version,value_json) VALUES (?,?,?,?)",
        (NAMESPACE, KEY, POLICY, canonical_json(value).decode("utf-8")),
    )
    return value


def index_storage_snapshot(connection: sqlite3.Connection) -> dict[str, Any]:
    try:
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        page_count = connection.execute("PRAGMA page_count").fetchone()[0]
        row = connection.execute(
            "SELECT value_json FROM derived_state "
            "WHERE namespace=? AND key=? AND policy_version=?",
            (NAMESPACE, KEY, POLICY),
        ).fetchone()
        cached = json.loads(row[0]) if row is not None else None
    except (sqlite3.Error, TypeError, ValueError, json.JSONDecodeError) as error:
        raise VaultError("index storage metrics are invalid") from error
    fields = {
        "schema_version", "source_bytes", "relationship_bytes", "projection_bytes"
    }
    if (
        isinstance(page_size, bool)
        or not isinstance(page_size, int)
        or page_size <= 0
        or isinstance(page_count, bool)
        or not isinstance(page_count, int)
        or page_count < 0
        or not isinstance(cached, dict)
        or set(cached) != fields
        or cached.get("schema_version") != 1
    ):
        raise VaultError("index storage metrics are invalid")
    components = {}
    for field in ("source_bytes", "relationship_bytes", "projection_bytes"):
        value = cached[field]
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise VaultError("index storage metrics are invalid")
        components[field] = value
    total = page_size * page_count
    allocated = sum(components.values())
    if allocated > total:
        raise VaultError("index storage metrics are invalid")
    components["other_bytes"] = total - allocated
    state = (
        "critical" if total >= CRITICAL_AT_BYTES
        else "attention" if total >= WARNING_AT_BYTES
        else "ready"
    )
    return {
        "state": state,
        "total_bytes": total,
        "warning_at_bytes": WARNING_AT_BYTES,
        "critical_at_bytes": CRITICAL_AT_BYTES,
        "components": components,
    }
