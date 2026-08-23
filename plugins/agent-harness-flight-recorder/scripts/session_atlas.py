#!/usr/bin/env python3
"""Deterministic Session Atlas facets and authenticated cohort queries."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import sqlite3
from pathlib import Path
from typing import Any

from chunk_rotation import EVENT_KINDS, canonical_json
from evidence_index import (
    _authorized_seal_key,
    read_database_generation,
    read_sealed_query_locked,
)
from retention_state import load_forgotten
from vault import VaultError, vault_lock


FACETS = (
    "context_identity",
    "event_lifecycle",
    "operation",
    "artifact_change",
)
STRUCTURAL_FACETS = FACETS[1:]
STATES = {"present", "mixed", "unknown"}
SHA256_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
CORRELATION_RE = re.compile(r"^sha256:[0-9a-f]{24}$")
MAX_LIMIT = 100
MAX_CURSOR_BYTES = 4096
CURSOR_DOMAIN = b"agent-harness-flight-recorder/session-atlas-cursor-v1\0"
OPERATION_ORDER = ("test", "build", "lint", "git_commit", "pull_request")


class _FacetName(str):
    """Keep the public match-mask order stable under sorted JSON encoders."""

    def __lt__(self, other: object) -> bool:
        if isinstance(other, str) and self in FACETS and other in FACETS:
            return FACETS.index(self) < FACETS.index(other)
        return str.__lt__(self, other)  # type: ignore[arg-type]


def _facet_insert_sql(expression: str) -> str:
    # All aggregation happens in SQLite.  The ordered distinct CTE gives mixed
    # values a deterministic finite JSON representation without Episode cards.
    return f"""
        WITH finite AS (
            SELECT DISTINCT m.policy_version, m.episode_id,
                   {expression} AS value
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id = m.event_id
            WHERE m.policy_version = ? AND {expression} IS NOT NULL
            ORDER BY m.policy_version, m.episode_id, value
        ), windowed AS (
            SELECT policy_version,episode_id,value,
                   COUNT(*) OVER (
                       PARTITION BY policy_version,episode_id
                   ) AS value_count,
                   MIN(value) OVER (
                       PARTITION BY policy_version,episode_id
                   ) AS one_value,
                   json_group_array(value) OVER (
                       PARTITION BY policy_version,episode_id
                       ORDER BY value
                       ROWS BETWEEN UNBOUNDED PRECEDING
                                AND UNBOUNDED FOLLOWING
                   ) AS many_values,
                   ROW_NUMBER() OVER (
                       PARTITION BY policy_version,episode_id ORDER BY value
                   ) AS item_number
            FROM finite
        ), aggregated AS (
            SELECT policy_version,episode_id,value_count,one_value,many_values
            FROM windowed WHERE item_number=1
        )
        INSERT INTO temp.session_atlas_values(
            policy_version, episode_id, facet, state, value_json
        )
        SELECT ep.policy_version, ep.episode_id, ?,
               CASE
                   WHEN COALESCE(a.value_count, 0) = 0 THEN 'unknown'
                   WHEN a.value_count = 1 THEN 'present'
                   ELSE 'mixed'
               END,
               CASE
                   WHEN COALESCE(a.value_count, 0) = 0 THEN NULL
                   WHEN a.value_count = 1 THEN json_quote(a.one_value)
                   ELSE a.many_values
               END
        FROM episodes AS ep
        LEFT JOIN aggregated AS a
          ON a.policy_version = ep.policy_version
         AND a.episode_id = ep.episode_id
        WHERE ep.policy_version = ?
        ORDER BY ep.episode_id
    """


def clear_session_atlas(
    connection: sqlite3.Connection, policy_version: str
) -> None:
    """Remove one policy's Atlas rows before its Episodes are replaced."""
    connection.execute(
        "DELETE FROM session_atlas_facets WHERE policy_version=?",
        (policy_version,),
    )


def materialize_session_atlas(
    connection: sqlite3.Connection, policy_version: str
) -> None:
    """Replace one policy's one-row-per-Episode Atlas projection."""
    clear_session_atlas(connection, policy_version)
    connection.execute(
        "CREATE TEMP TABLE IF NOT EXISTS session_atlas_values ("
        "policy_version TEXT NOT NULL, episode_id TEXT NOT NULL, "
        "facet TEXT NOT NULL, state TEXT NOT NULL, value_json TEXT, "
        "PRIMARY KEY(policy_version,episode_id,facet)) WITHOUT ROWID"
    )
    connection.execute("DELETE FROM temp.session_atlas_values")
    scalar_expressions = {
        "context_identity": (
            "COALESCE(e.workspace_id, e.session_id_hash, "
            "e.relationship_task_id_hash, "
            "e.relationship_branch_or_worktree_id)"
        ),
        "event_lifecycle": "e.event_kind",
    }
    for facet, expression in scalar_expressions.items():
        connection.execute(
            _facet_insert_sql(expression),
            (policy_version, facet, policy_version),
        )
    connection.execute(
        """
        WITH counts AS (
            SELECT m.policy_version, m.episode_id,
                   SUM(CASE WHEN e.event_kind='tool.completed'
                            THEN 1 ELSE 0 END) AS eligible_count,
                   SUM(CASE WHEN e.event_kind='tool.completed'
                                 AND e.operation_kind IS NOT NULL
                            THEN 1 ELSE 0 END) AS classified_count,
                   COUNT(DISTINCT CASE
                       WHEN e.event_kind='tool.completed'
                       THEN e.operation_kind END) AS kind_count
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id=m.event_id
            WHERE m.policy_version=?
            GROUP BY m.policy_version,m.episode_id
        ), finite AS (
            SELECT DISTINCT m.policy_version,m.episode_id,
                   e.operation_kind AS kind
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id=m.event_id
            WHERE m.policy_version=?
              AND e.event_kind='tool.completed'
              AND e.operation_kind IS NOT NULL
        ), kinds AS (
            SELECT policy_version,episode_id,
                   '[' || rtrim(
                       CASE WHEN MAX(kind='test') THEN '"test",' ELSE '' END ||
                       CASE WHEN MAX(kind='build') THEN '"build",' ELSE '' END ||
                       CASE WHEN MAX(kind='lint') THEN '"lint",' ELSE '' END ||
                       CASE WHEN MAX(kind='git_commit')
                            THEN '"git_commit",' ELSE '' END ||
                       CASE WHEN MAX(kind='pull_request')
                            THEN '"pull_request",' ELSE '' END,
                       ','
                   ) || ']' AS kind_json
            FROM finite GROUP BY policy_version,episode_id
        )
        INSERT INTO temp.session_atlas_values
        SELECT c.policy_version,c.episode_id,'operation',
               CASE
                   WHEN c.kind_count=0 THEN 'unknown'
                   WHEN (c.eligible_count>0 AND
                         c.classified_count<c.eligible_count)
                        OR c.kind_count>1 THEN 'mixed'
                   ELSE 'present'
               END,
               CASE WHEN c.kind_count=0 THEN NULL ELSE json_object(
                   'coverage',CASE
                       WHEN c.eligible_count=0 OR
                            c.classified_count=c.eligible_count
                       THEN 'complete' ELSE 'partial' END,
                   'kinds',json(k.kind_json)
               ) END
        FROM counts AS c
        LEFT JOIN kinds AS k
          ON k.policy_version=c.policy_version AND k.episode_id=c.episode_id
        ORDER BY c.policy_version,c.episode_id
        """,
        (policy_version, policy_version),
    )
    connection.execute(
        """
        WITH observations AS (
            SELECT m.policy_version,m.episode_id,
                   e.relationship_changed_files_state AS coverage_state
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id=m.event_id
            WHERE m.policy_version=?
              AND e.relationship_changed_files_state IN ('complete','truncated')
        ), coverage AS (
            SELECT ep.policy_version,ep.episode_id,
                   COUNT(o.coverage_state) AS known_count,
                   SUM(CASE WHEN o.coverage_state='truncated'
                            THEN 1 ELSE 0 END) AS truncated_count,
                   ep.member_count
            FROM episodes AS ep
            LEFT JOIN observations AS o
              ON o.policy_version=ep.policy_version
             AND o.episode_id=ep.episode_id
            WHERE ep.policy_version=?
            GROUP BY ep.policy_version,ep.episode_id,ep.member_count
        ), fingerprint_counts AS (
            SELECT m.policy_version,m.episode_id,
                   COUNT(DISTINCT fingerprint.value) AS file_count
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id=m.event_id
            JOIN json_each(
                e.relationship_changed_file_fingerprints_json
            ) AS fingerprint
            WHERE m.policy_version=?
              AND e.relationship_changed_files_state IN ('complete','truncated')
            GROUP BY m.policy_version,m.episode_id
        )
        INSERT INTO temp.session_atlas_values
        SELECT c.policy_version,c.episode_id,'artifact_change',
               CASE
                   WHEN c.known_count=0 THEN 'unknown'
                   WHEN c.known_count<c.member_count OR c.truncated_count>0
                        THEN 'mixed'
                   ELSE 'present'
               END,
               CASE WHEN c.known_count=0 THEN NULL ELSE json_object(
                   'coverage',CASE
                       WHEN c.known_count=c.member_count
                            AND c.truncated_count=0
                       THEN 'complete' ELSE 'partial' END,
                   'shape',CASE
                       WHEN COALESCE(f.file_count,0)=0 THEN 'none'
                       WHEN f.file_count=1 THEN 'single'
                       WHEN f.file_count<=8 THEN 'few' ELSE 'many' END
               ) END
        FROM coverage AS c
        LEFT JOIN fingerprint_counts AS f
          ON f.policy_version=c.policy_version AND f.episode_id=c.episode_id
        ORDER BY c.policy_version,c.episode_id
        """,
        (policy_version, policy_version, policy_version),
    )
    connection.execute(
        """
        INSERT INTO session_atlas_facets
        SELECT ep.policy_version, ep.episode_id,
               ci.state, ci.value_json,
               el.state, el.value_json,
               op.state, op.value_json,
               ac.state, ac.value_json
        FROM episodes AS ep
        JOIN temp.session_atlas_values AS ci
          ON ci.policy_version=ep.policy_version
         AND ci.episode_id=ep.episode_id AND ci.facet='context_identity'
        JOIN temp.session_atlas_values AS el
          ON el.policy_version=ep.policy_version
         AND el.episode_id=ep.episode_id AND el.facet='event_lifecycle'
        JOIN temp.session_atlas_values AS op
          ON op.policy_version=ep.policy_version
         AND op.episode_id=ep.episode_id AND op.facet='operation'
        JOIN temp.session_atlas_values AS ac
          ON ac.policy_version=ep.policy_version
         AND ac.episode_id=ep.episode_id AND ac.facet='artifact_change'
        WHERE ep.policy_version=? ORDER BY ep.episode_id
        """,
        (policy_version,),
    )


def _selected_facets(tier: str, facets: list[str]) -> tuple[str, ...]:
    if tier == "exact":
        if facets:
            raise VaultError("exact Atlas cohort does not accept facets")
        return FACETS
    if tier == "structural":
        if facets:
            raise VaultError("structural Atlas cohort does not accept facets")
        return STRUCTURAL_FACETS
    if tier != "partial":
        raise VaultError("Atlas cohort tier is invalid")
    if not facets or len(facets) != len(set(facets)):
        raise VaultError("partial Atlas cohort requires unique facets")
    if any(facet not in FACETS for facet in facets):
        raise VaultError("partial Atlas cohort facet is invalid")
    return tuple(facet for facet in FACETS if facet in facets)


def _cursor_mac(payload: dict[str, Any], key: bytes) -> str:
    return hmac.new(
        key, CURSOR_DOMAIN + canonical_json(payload), hashlib.sha256
    ).hexdigest()


def _encode_cursor(payload: dict[str, Any], key: bytes) -> str:
    encoded = canonical_json(
        {"payload": payload, "mac": _cursor_mac(payload, key)}
    )
    return base64.urlsafe_b64encode(encoded).decode("ascii").rstrip("=")


def _decode_cursor(token: str, expected: dict[str, Any], key: bytes) -> str:
    if not isinstance(token, str) or not token or len(token) > MAX_CURSOR_BYTES:
        raise VaultError("Atlas cohort cursor is invalid")
    try:
        raw = base64.b64decode(
            token + "=" * (-len(token) % 4), altchars=b"-_", validate=True
        )
        value = json.loads(raw)
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("Atlas cohort cursor is invalid") from error
    if not isinstance(value, dict) or set(value) != {"payload", "mac"}:
        raise VaultError("Atlas cohort cursor is invalid")
    payload, mac = value["payload"], value["mac"]
    if (
        not isinstance(payload, dict)
        or set(payload) != {*expected, "after"}
        or any(payload.get(name) != item for name, item in expected.items())
        or not isinstance(payload.get("after"), str)
        or SHA256_RE.fullmatch(payload["after"]) is None
        or not isinstance(mac, str)
        or not hmac.compare_digest(mac, _cursor_mac(payload, key))
    ):
        raise VaultError("Atlas cohort cursor does not match query")
    return payload["after"]


def _valid_scalar_facet(facet: str, state: str, value: object) -> bool:
    values = value if state == "mixed" else [value]
    if (
        not isinstance(values, list)
        or not values
        or any(not isinstance(item, str) for item in values)
        or values != sorted(set(values))
        or (state == "mixed" and len(values) < 2)
        or (state == "present" and len(values) != 1)
    ):
        return False
    if facet == "context_identity":
        return all(CORRELATION_RE.fullmatch(item) is not None for item in values)
    return facet == "event_lifecycle" and all(
        item in EVENT_KINDS for item in values
    )


def _valid_operation_facet(state: str, value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"coverage", "kinds"}:
        return False
    coverage = value.get("coverage")
    kinds = value.get("kinds")
    if not (
        coverage in {"complete", "partial"}
        and isinstance(kinds, list)
        and bool(kinds)
        and all(isinstance(kind, str) and kind in OPERATION_ORDER for kind in kinds)
        and len(kinds) == len(set(kinds))
        and kinds == [kind for kind in OPERATION_ORDER if kind in kinds]
    ):
        return False
    if state == "present":
        return coverage == "complete" and len(kinds) == 1
    return state == "mixed" and (coverage == "partial" or len(kinds) > 1)


def _valid_artifact_facet(state: str, value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"coverage", "shape"}:
        return False
    coverage = value.get("coverage")
    if value.get("shape") not in {"none", "single", "few", "many"}:
        return False
    return (
        (state == "present" and coverage == "complete")
        or (state == "mixed" and coverage == "partial")
    )


def _decode_facet(
    facet: str, state: str, encoded: str | None
) -> dict[str, Any]:
    if facet not in FACETS:
        raise VaultError("Session Atlas facet is invalid")
    if state not in STATES or (encoded is None) != (state == "unknown"):
        raise VaultError("Session Atlas projection is invalid")
    try:
        value = None if encoded is None else json.loads(encoded)
    except (TypeError, json.JSONDecodeError) as error:
        raise VaultError("Session Atlas projection is invalid") from error
    if encoded is not None and canonical_json(value).decode("utf-8") != encoded:
        raise VaultError("Session Atlas projection is not canonical")
    valid = state == "unknown"
    if facet in {"context_identity", "event_lifecycle"} and state != "unknown":
        valid = _valid_scalar_facet(facet, state, value)
    elif facet == "operation" and state != "unknown":
        valid = _valid_operation_facet(state, value)
    elif facet == "artifact_change" and state != "unknown":
        valid = _valid_artifact_facet(state, value)
    if not valid:
        raise VaultError("Session Atlas facet value is invalid")
    return {"state": state, "value": value}


def read_session_atlas_facets(
    connection: sqlite3.Connection,
    policy_version: str,
    episode_id: str,
) -> dict[str, dict[str, Any]]:
    columns = ",".join(
        f"{facet}_state,{facet}_value_json" for facet in FACETS
    )
    row = connection.execute(
        f"SELECT {columns} FROM session_atlas_facets "
        "WHERE policy_version=? AND episode_id=?",
        (policy_version, episode_id),
    ).fetchone()
    if row is None:
        raise VaultError("Session Atlas facets were not found for Episode")
    return {
        facet: _decode_facet(facet, row[offset * 2], row[offset * 2 + 1])
        for offset, facet in enumerate(FACETS)
    }


def query_cohort(
    root: Path,
    policy_version: str | None,
    episode_id: str,
    tier: str,
    facets: list[str],
    limit: int,
    cursor: str | None,
    *,
    policy_path: Path | None = None,
) -> dict[str, Any]:
    from reporting import _policy_selection

    policy_version, trusted_policy = _policy_selection(
        policy_version, policy_path
    )
    if not isinstance(episode_id, str) or SHA256_RE.fullmatch(episode_id) is None:
        raise VaultError("Atlas Episode ID is invalid")
    if (
        isinstance(limit, bool)
        or not isinstance(limit, int)
        or not 1 <= limit <= MAX_LIMIT
    ):
        raise VaultError("Atlas cohort limit must be between 1 and 100")
    selected = _selected_facets(tier, facets)

    with vault_lock(root):
        forgotten = load_forgotten(root)
        if (policy_version, episode_id) in forgotten:
            raise VaultError("episode is forgotten for relationship policy")
        _config, cursor_key = _authorized_seal_key(root)

        def query(
            connection: sqlite3.Connection,
            _policy: dict[str, Any],
        ) -> dict[str, Any]:
            generation = read_database_generation(connection)
            query_spec = {
                "policy_version": policy_version,
                "episode_id": episode_id,
                "tier": tier,
                "facets": list(selected),
                "limit": limit,
                "generation": generation,
            }
            after = _decode_cursor(cursor, query_spec, cursor_key) if cursor else ""
            columns = ",".join(
                f"{facet}_state,{facet}_value_json" for facet in FACETS
            )
            target = connection.execute(
                f"SELECT {columns} FROM session_atlas_facets "
                "WHERE policy_version=? AND episode_id=?",
                (policy_version, episode_id),
            ).fetchone()
            if target is None:
                raise VaultError("episode was not found for relationship policy")
            target_facets = {
                facet: (target[offset * 2], target[offset * 2 + 1])
                for offset, facet in enumerate(FACETS)
            }
            for facet, (state, encoded) in target_facets.items():
                _decode_facet(facet, state, encoded)
            if any(target_facets[facet][0] == "unknown" for facet in selected):
                rows: list[tuple[Any, ...]] = []
            else:
                predicates = ["policy_version=?", "episode_id>?"]
                parameters: list[Any] = [policy_version, after]
                for facet in selected:
                    state, encoded = target_facets[facet]
                    predicates.extend(
                        (f"{facet}_state=?", f"{facet}_value_json=?")
                    )
                    parameters.extend((state, encoded))
                hidden = sorted(
                    hidden_episode
                    for hidden_policy, hidden_episode in forgotten
                    if hidden_policy == policy_version
                )
                if hidden:
                    predicates.append(
                        "episode_id NOT IN "
                        "(SELECT value FROM json_each(?))"
                    )
                    parameters.append(canonical_json(hidden).decode("utf-8"))
                parameters.append(limit + 1)
                rows = list(
                    connection.execute(
                        f"SELECT episode_id,{columns} "
                        "FROM session_atlas_facets "
                        f"WHERE {' AND '.join(predicates)} "
                        "ORDER BY episode_id LIMIT ?",
                        parameters,
                    )
                )
            page, extra = rows[:limit], len(rows) > limit
            items = []
            for row in page:
                decoded = {
                    facet: _decode_facet(
                        facet, row[1 + offset * 2], row[2 + offset * 2]
                    )
                    for offset, facet in enumerate(FACETS)
                }
                mask = {
                    _FacetName(facet): (
                        decoded[facet]["state"] != "unknown"
                        and decoded[facet]["state"] == target_facets[facet][0]
                        and canonical_json(decoded[facet]["value"]).decode("utf-8")
                        == target_facets[facet][1]
                    )
                    for facet in FACETS
                }
                items.append(
                    {
                        "episode_id": row[0],
                        "facets": decoded,
                        "match_mask": mask,
                    }
                )
            next_cursor = None
            if extra and page:
                next_cursor = _encode_cursor(
                    {**query_spec, "after": page[-1][0]}, cursor_key
                )
            return {
                "schema_version": 1,
                "command": "atlas.cohort",
                "policy_version": policy_version,
                "generation": generation,
                "query": {
                    "episode_id": episode_id,
                    "tier": tier,
                    "facets": list(selected),
                    "limit": limit,
                },
                "items": items,
                "next_cursor": next_cursor,
            }

        return read_sealed_query_locked(
            root, policy_version, query, trusted_policy
        )


def render_cohort(value: dict[str, Any]) -> str:
    query = value["query"]
    lines = [
        f"Session Atlas cohort: {query['episode_id']}",
        f"  tier: {query['tier']}",
        f"  facets: {', '.join(query['facets'])}",
        f"  matches: {len(value['items'])}",
    ]
    lines.extend(f"  - {item['episode_id']}" for item in value["items"])
    if value["next_cursor"]:
        lines.append(f"  next cursor: {value['next_cursor']}")
    return "\n".join(lines)
