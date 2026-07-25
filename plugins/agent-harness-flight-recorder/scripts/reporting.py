#!/usr/bin/env python3
"""Grounded local health and Episode Evidence Card reporting."""

from __future__ import annotations

import datetime as dt
import json
import math
import os
import re
import secrets
import sqlite3
import stat
from pathlib import Path
from typing import Any, Callable, TypeVar

from chunk_rotation import canonical_json, parse_time
from evidence_index import (
    DATABASE_PATH,
    _check_existing_database,
    _open_readonly,
    create_schema,
    insert_chunk,
    load_chunks,
    validate_database,
    validate_source_projection,
)
from relationship_graph import (
    load_policy,
    load_stored_policies,
    rebuild_relationships,
)
from sync import (
    CHUNK_PATH_RE,
    PENDING_PATH,
    load_pending,
    load_receipts,
    strict_preflight,
    tracked_paths,
)
from vault import (
    HASH_KEY_PATH,
    VaultError,
    authorized_key,
    ensure_safe_existing_root,
    load_config,
    vault_lock,
    verify_recipient_state_hmac,
)


OUTPUT_VERSION = 1
DEFAULT_POLICY_VERSION = "default-v1"
EPISODE_ID_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
DURATION_RE = re.compile(r"^([1-9][0-9]*)([smhdw])$")
MAX_WINDOW_SECONDS = 10 * 366 * 24 * 60 * 60
UNITS = {
    "s": 1,
    "m": 60,
    "h": 60 * 60,
    "d": 24 * 60 * 60,
    "w": 7 * 24 * 60 * 60,
}
GRAPH_TABLES = (
    "relationship_policies",
    "relationship_edges",
    "episodes",
    "episode_members",
)
T = TypeVar("T")


def parse_duration(value: str) -> dt.timedelta:
    match = DURATION_RE.fullmatch(value)
    if match is None:
        raise VaultError("report duration must be a positive integer plus s/m/h/d/w")
    amount = int(match.group(1))
    seconds = amount * UNITS[match.group(2)]
    if seconds > MAX_WINDOW_SECONDS:
        raise VaultError("report duration is too large")
    return dt.timedelta(seconds=seconds)


def _policy(
    connection: sqlite3.Connection, policy_version: str
) -> dict[str, Any]:
    policies = {
        policy["policy_version"]: policy
        for policy in load_stored_policies(connection)
    }
    try:
        return policies[policy_version]
    except KeyError as error:
        raise VaultError("relationship policy version was not found") from error


def _open_reporting(path: Path) -> sqlite3.Connection:
    identity = _check_existing_database(path)
    connection = _open_readonly(path)
    if _check_existing_database(path) != identity:
        connection.close()
        raise VaultError("evidence index changed during validation")
    return connection


def _artifact_paths(root: Path) -> set[str]:
    devices = root / "devices"
    if devices.is_symlink():
        raise VaultError("encrypted chunk directory is unsafe")
    if not devices.exists():
        return set()
    try:
        metadata = devices.lstat()
    except OSError as error:
        raise VaultError("encrypted chunk directory is unsafe") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise VaultError("encrypted chunk directory is unsafe")
    result = set()
    try:
        candidates = sorted(devices.rglob("*.jsonl.age"))
        for candidate in candidates:
            item = candidate.lstat()
            relative = candidate.relative_to(root).as_posix()
            if (
                not stat.S_ISREG(item.st_mode)
                or item.st_uid != os.geteuid()
                or item.st_nlink != 1
                or CHUNK_PATH_RE.fullmatch(relative) is None
            ):
                raise VaultError("encrypted chunk is unsafe")
            result.add(relative)
    except OSError as error:
        raise VaultError("encrypted chunk directory is unsafe") from error
    return result


def _authenticated_chunks(root: Path) -> list[Any]:
    strict_preflight(root)
    chunks = load_chunks(root)
    receipts = set(load_receipts(root))
    tracked = {
        path for path in tracked_paths(root)
        if CHUNK_PATH_RE.fullmatch(path) is not None
    }
    artifacts = _artifact_paths(root)
    if receipts != tracked or receipts != artifacts:
        raise VaultError("encrypted chunks and import receipts disagree")
    return chunks


def _policy_selection(
    policy_version: str | None, policy_path: Path | None
) -> tuple[str, dict[str, Any] | None]:
    if policy_path is not None:
        trusted = load_policy(policy_path)
        if (
            policy_version is not None
            and policy_version != trusted["policy_version"]
        ):
            raise VaultError("relationship policy selection conflicts")
        return trusted["policy_version"], trusted
    selected = policy_version or DEFAULT_POLICY_VERSION
    if selected != DEFAULT_POLICY_VERSION:
        raise VaultError("custom relationship policy requires --policy")
    return selected, None


def _graph_rows(
    connection: sqlite3.Connection, policy_version: str
) -> dict[str, list[tuple[Any, ...]]]:
    return {
        table: sorted(
            (
                tuple(row)
                for row in connection.execute(
                    f"SELECT * FROM {table} WHERE policy_version = ?",
                    (policy_version,),
                )
            ),
            key=repr,
        )
        for table in GRAPH_TABLES
    }


def _verify_graph(
    connection: sqlite3.Connection,
    chunks: list[Any],
    policy: dict[str, Any],
) -> None:
    expected = sqlite3.connect(":memory:", isolation_level=None)
    try:
        expected.execute("PRAGMA foreign_keys = ON")
        expected.execute("PRAGMA trusted_schema = OFF")
        create_schema(expected)
        for chunk in chunks:
            insert_chunk(expected, chunk)
        rebuild_relationships(expected, policy)
        validate_database(expected)
        if _graph_rows(connection, policy["policy_version"]) != _graph_rows(
            expected, policy["policy_version"]
        ):
            raise VaultError("evidence index relationship projection conflicts")
    except sqlite3.Error as error:
        raise VaultError("evidence index relationship projection is invalid") from error
    finally:
        expected.close()


def _authenticated_query(
    root: Path,
    policy_version: str,
    query: Callable[[sqlite3.Connection, dict[str, Any]], T],
    trusted_policy: dict[str, Any] | None = None,
) -> T:
    with vault_lock(root):
        chunks = _authenticated_chunks(root)
        connection = _open_reporting(root / DATABASE_PATH)
        try:
            connection.execute("BEGIN")
            validate_source_projection(connection, chunks, exact=True)
            validate_database(connection)
            policy = _policy(connection, policy_version)
            if (
                trusted_policy is not None
                and canonical_json(policy) != canonical_json(trusted_policy)
            ):
                raise VaultError("stored relationship policy conflicts")
            _verify_graph(connection, chunks, policy)
            result = query(connection, policy)
            connection.execute("COMMIT")
            return result
        except VaultError:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise
        except sqlite3.Error as error:
            if connection.in_transaction:
                connection.execute("ROLLBACK")
            raise VaultError("evidence index query failed") from error
        finally:
            connection.close()


def _iso(value: dt.datetime) -> str:
    normalized = value.astimezone(dt.timezone.utc)
    return normalized.isoformat().replace("+00:00", "Z")


def _measurement(
    events: list[dict[str, Any]], metric: str
) -> dict[str, int | float | str | None]:
    values = [
        event["metrics"][metric]
        for event in events
        if event["metrics"] is not None and metric in event["metrics"]
    ]
    total = len(events)
    known = len(values)
    if known == 0:
        state = "missing"
        value: int | float | None = None
    else:
        state = "complete" if known == total else "partial"
        try:
            value = math.fsum(values)
        except (OverflowError, ValueError) as error:
            raise VaultError("recorded metric aggregate is invalid") from error
        if not math.isfinite(value):
            raise VaultError("recorded metric aggregate is invalid")
        if all(isinstance(item, int) for item in values):
            value = int(value)
    return {
        "value": value,
        "state": state,
        "aggregation": "sum_of_recorded_values",
        "known_event_count": known,
        "total_event_count": total,
    }


def _edges_by_episode(
    connection: sqlite3.Connection,
    policy_version: str,
) -> dict[str, list[dict[str, Any]]]:
    episodes: dict[str, list[dict[str, Any]]] = {}
    for episode_id, left, right, score, decision, encoded in connection.execute(
        """
        SELECT left_member.episode_id, edge.left_event_id,
               edge.right_event_id, edge.score, edge.decision,
               edge.evidence_json
        FROM relationship_edges AS edge
        JOIN episode_members AS left_member
          ON left_member.policy_version = edge.policy_version
         AND left_member.event_id = edge.left_event_id
        JOIN episode_members AS right_member
          ON right_member.policy_version = edge.policy_version
         AND right_member.event_id = edge.right_event_id
         AND right_member.episode_id = left_member.episode_id
        WHERE edge.policy_version = ? AND edge.decision = 'link'
        ORDER BY left_member.episode_id, edge.left_event_id,
                 edge.right_event_id
        """,
        (policy_version,),
    ):
        try:
            evidence = json.loads(encoded)
        except (TypeError, json.JSONDecodeError) as error:
            raise VaultError("relationship evidence is invalid") from error
        episodes.setdefault(episode_id, []).append(
            {
                "left_event_id": left,
                "right_event_id": right,
                "score": score,
                "decision": decision,
                "evidence": evidence,
            }
        )
    return episodes


def _episode_card(
    connection: sqlite3.Connection,
    policy: dict[str, Any],
    episode_id: str,
    edges_by_episode: dict[str, list[dict[str, Any]]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    rows = list(
        connection.execute(
            """
            SELECT e.event_id, e.recorded_at, e.harness, e.model,
                   e.metrics_json, e.outcome_json
            FROM episode_members AS m
            JOIN source_events AS e ON e.event_id = m.event_id
            WHERE m.policy_version = ? AND m.episode_id = ?
            ORDER BY e.event_id
            """,
            (policy["policy_version"], episode_id),
        )
    )
    if not rows:
        raise VaultError("episode was not found for relationship policy")
    events: list[dict[str, Any]] = []
    for event_id, recorded_at, harness, model, metrics_json, outcome_json in rows:
        try:
            metrics = json.loads(metrics_json) if metrics_json is not None else None
            outcome = json.loads(outcome_json) if outcome_json is not None else None
        except (TypeError, json.JSONDecodeError) as error:
            raise VaultError("episode source evidence is invalid") from error
        events.append(
            {
                "event_id": event_id,
                "recorded_at": recorded_at,
                "harness": harness,
                "model": model,
                "metrics": metrics,
                "outcome": outcome,
            }
        )
    events.sort(
        key=lambda event: (
            parse_time(event["recorded_at"]),
            event["event_id"],
        )
    )
    timestamps = [parse_time(event["recorded_at"]) for event in events]
    elapsed = (timestamps[-1] - timestamps[0]).total_seconds() * 1000
    elapsed_ms: int | float = (
        int(elapsed) if float(elapsed).is_integer() else elapsed
    )
    outcome_counts = {
        "success": 0,
        "failure": 0,
        "unknown": 0,
        "not_recorded": 0,
    }
    outcome_evidence = []
    for event in events:
        outcome = event["outcome"]
        status = outcome.get("status") if isinstance(outcome, dict) else None
        if status in ("success", "failure", "unknown"):
            outcome_counts[status] += 1
            outcome_evidence.append(
                {
                    "event_id": event["event_id"],
                    "status": status,
                    "exit_code": outcome.get("exit_code"),
                }
            )
        else:
            outcome_counts["not_recorded"] += 1
    event_ids = [event["event_id"] for event in events]
    known_models = sum(event["model"] is not None for event in events)
    model_state = (
        "missing"
        if known_models == 0
        else ("complete" if known_models == len(events) else "partial")
    )
    edges = edges_by_episode.get(episode_id, [])
    confidence = None
    if len(events) > 1 and edges:
        confidence = {
            "state": "supported",
            "minimum_supporting_score": min(edge["score"] for edge in edges),
            "threshold": policy["threshold"],
        }
    card = {
        "schema_version": OUTPUT_VERSION,
        "episode_id": episode_id,
        "policy_version": policy["policy_version"],
        "time": {
            "first_recorded_at": events[0]["recorded_at"],
            "last_recorded_at": events[-1]["recorded_at"],
        },
        "event_count": len(events),
        "harnesses": sorted({event["harness"] for event in events}),
        "models": sorted(
            {event["model"] for event in events if event["model"] is not None}
        ),
        "model_coverage": {
            "state": model_state,
            "known_event_count": known_models,
            "total_event_count": len(events),
        },
        # Event v1/v2 do not record a trustworthy task taxonomy.
        "task_type": None,
        "elapsed_ms": elapsed_ms,
        "measured_duration_ms": _measurement(events, "duration_ms"),
        "measured_cost_usd": _measurement(events, "total_cost_usd"),
        "deterministic_outcomes": {
            **outcome_counts,
            "evidence": outcome_evidence,
        },
        # Retry evidence is introduced by the R1.1 durable retry work.
        "retry_count": None,
        "confidence": confidence,
        "source_event_ids": event_ids,
    }
    return card, edges


def report(
    root: Path,
    last: str,
    policy_version: str | None,
    policy_path: Path | None = None,
    *,
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    policy_version, trusted_policy = _policy_selection(
        policy_version, policy_path
    )
    window = parse_duration(last)
    end = now or dt.datetime.now(dt.timezone.utc)
    if end.tzinfo is None:
        raise VaultError("report clock must include a timezone")
    end = end.astimezone(dt.timezone.utc)
    start = end - window

    def query(
        connection: sqlite3.Connection, policy: dict[str, Any]
    ) -> dict[str, Any]:
        episode_ids = [
            row[0]
            for row in connection.execute(
                "SELECT episode_id FROM episodes "
                "WHERE policy_version = ? ORDER BY episode_id",
                (policy_version,),
            )
        ]
        edges_by_episode = _edges_by_episode(connection, policy_version)
        cards = []
        for episode_id in episode_ids:
            card, _edges = _episode_card(
                connection, policy, episode_id, edges_by_episode
            )
            last_recorded = parse_time(card["time"]["last_recorded_at"])
            if start <= last_recorded <= end:
                cards.append(card)
        cards.sort(
            key=lambda card: (
                parse_time(card["time"]["last_recorded_at"]),
                card["episode_id"],
            ),
            reverse=True,
        )
        return {
            "schema_version": OUTPUT_VERSION,
            "command": "report",
            "policy_version": policy_version,
            "window": {
                "requested": last,
                "start": _iso(start),
                "end": _iso(end),
            },
            "cards": cards,
        }

    return _authenticated_query(
        root, policy_version, query, trusted_policy
    )


def inspect_episode(
    root: Path,
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None = None,
) -> dict[str, Any]:
    if EPISODE_ID_RE.fullmatch(episode_id) is None:
        raise VaultError("episode ID is invalid")
    policy_version, trusted_policy = _policy_selection(
        policy_version, policy_path
    )

    def query(
        connection: sqlite3.Connection, policy: dict[str, Any]
    ) -> dict[str, Any]:
        edges_by_episode = _edges_by_episode(connection, policy_version)
        card, edges = _episode_card(
            connection, policy, episode_id, edges_by_episode
        )
        return {
            "schema_version": OUTPUT_VERSION,
            "command": "inspect",
            "policy_version": policy_version,
            "card": card,
            "supporting_edges": edges,
        }

    return _authenticated_query(
        root, policy_version, query, trusted_policy
    )


def _regular_count(directory: Path, suffix: str | None = None) -> int:
    if directory.is_symlink():
        raise VaultError("local reporting directory is unsafe")
    if not directory.exists():
        return 0
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise VaultError("local reporting directory is unsafe") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise VaultError("local reporting directory is unsafe")
    count = 0
    try:
        for path in directory.iterdir():
            item = path.lstat()
            if (
                not stat.S_ISREG(item.st_mode)
                or item.st_uid != os.geteuid()
                or item.st_nlink != 1
            ):
                raise VaultError("local reporting state is unsafe")
            if suffix is None or path.name.endswith(suffix):
                count += 1
    except OSError as error:
        raise VaultError("local reporting state is unsafe") from error
    return count


def _inbox_count(root: Path) -> int:
    path = root / "inbox/events.jsonl"
    if path.is_symlink():
        raise VaultError("event inbox is unsafe")
    if not path.exists():
        return 0
    try:
        metadata = path.lstat()
    except OSError as error:
        raise VaultError("event inbox is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
    ):
        raise VaultError("event inbox is unsafe")
    try:
        with path.open("rb") as stream:
            return sum(1 for line in stream if line)
    except OSError as error:
        raise VaultError("event inbox cannot be read") from error


def _vault_health(root: Path) -> dict[str, Any]:
    config_path = root / "vault.json"
    if config_path.is_symlink():
        raise VaultError("vault configuration is missing or unsafe")
    if not config_path.exists():
        return {"state": "uninitialized"}
    config = load_config(root)
    key = authorized_key(root, None)
    local_key = root / HASH_KEY_PATH
    try:
        metadata = local_key.lstat()
        local_key_bytes = local_key.read_bytes()
    except OSError as error:
        raise VaultError("local correlation key is missing or unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
    ):
        raise VaultError("local correlation key is missing or unsafe")
    if not secrets.compare_digest(local_key_bytes, key):
        raise VaultError("local correlation key does not match the envelope")
    verify_recipient_state_hmac(config, key)
    return {"state": "initialized", "vault_id": config["vault_id"]}


def status(root: Path) -> dict[str, Any]:
    ensure_safe_existing_root(root)
    components: dict[str, dict[str, Any]] = {}
    try:
        components["vault"] = _vault_health(root)
    except VaultError:
        components["vault"] = {"state": "invalid"}

    try:
        if (root / PENDING_PATH).is_symlink():
            raise VaultError("pending sync state is unsafe")
        pending = load_pending(root)
        if (root / ".git").is_dir():
            chunks = _authenticated_chunks(root)
        elif load_receipts(root) or _artifact_paths(root):
            raise VaultError("encrypted chunks are not synchronized")
        else:
            chunks = []
        phase = pending.get("phase") if pending else None
        attempts = pending.get("attempt_count") if pending else None
        if phase is not None and not isinstance(phase, str):
            raise VaultError("pending sync state is invalid")
        if attempts is not None and (
            isinstance(attempts, bool)
            or not isinstance(attempts, int)
            or attempts < 0
        ):
            raise VaultError("pending sync state is invalid")
        components["sync"] = {
            "state": "pending" if pending is not None else "idle",
            "pending": pending is not None,
            "pending_phase": phase,
            "attempt_count": attempts,
            "imported_chunk_count": len(chunks),
            # No pending marker proves only local idleness, not remote success.
            "last_success_at": None,
        }
    except VaultError:
        components["sync"] = {"state": "invalid", "pending": None}

    index_path = root / DATABASE_PATH
    if index_path.is_symlink():
        components["index"] = {
            "state": "invalid",
            "schema_version": None,
            "source_event_count": None,
            "episode_count": None,
        }
    elif not index_path.exists():
        components["index"] = {
            "state": "missing",
            "schema_version": None,
            "source_event_count": None,
            "episode_count": None,
        }
    else:
        try:
            def index_query(
                connection: sqlite3.Connection, _policy: dict[str, Any]
            ) -> dict[str, Any]:
                return {
                    "state": "ready",
                    "schema_version": connection.execute(
                        "PRAGMA user_version"
                    ).fetchone()[0],
                    "source_event_count": connection.execute(
                        "SELECT COUNT(*) FROM source_events"
                    ).fetchone()[0],
                    "episode_count": connection.execute(
                        "SELECT COUNT(*) FROM episodes "
                        "WHERE policy_version = ?",
                        (DEFAULT_POLICY_VERSION,),
                    ).fetchone()[0],
                }

            components["index"] = _authenticated_query(
                root, DEFAULT_POLICY_VERSION, index_query
            )
        except VaultError:
            components["index"] = {
                "state": "invalid",
                "schema_version": None,
                "source_event_count": None,
                "episode_count": None,
            }

    try:
        inbox = _inbox_count(root)
        queue_directory = root / "queue"
        rotation = 0
        _regular_count(queue_directory)
        if queue_directory.exists():
            rotation = sum(
                1
                for path in queue_directory.iterdir()
                if path.name.endswith(".jsonl.pending")
            )
        quarantine = _regular_count(root / "quarantine")
        sync_pending = components["sync"].get("pending") is True
        pending_count = inbox + rotation + int(sync_pending)
        components["queue"] = {
            "state": "empty" if pending_count == 0 else "pending",
            "pending_count": pending_count,
            "inbox_event_count": inbox,
            "rotation_job_count": rotation,
            "quarantine_file_count": quarantine,
        }
    except (OSError, VaultError):
        components["queue"] = {"state": "invalid", "pending_count": None}

    states = [component["state"] for component in components.values()]
    overall = "ready" if all(
        state in ("initialized", "idle", "ready", "empty")
        for state in states
    ) else "attention"
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "status",
        "overall": overall,
        **components,
    }


def render_status(value: dict[str, Any]) -> str:
    return "\n".join(
        (
            "Flight Recorder status",
            f"Overall: {value['overall']}",
            f"Vault: {value['vault']['state']}",
            (
                f"Sync: {value['sync']['state']} "
                f"(pending: {value['sync'].get('pending')})"
            ),
            (
                f"Index: {value['index']['state']} "
                f"(events: {value['index'].get('source_event_count')}, "
                f"episodes: {value['index'].get('episode_count')})"
            ),
            (
                f"Queue: {value['queue']['state']} "
                f"(pending: {value['queue'].get('pending_count')})"
            ),
        )
    )


def _display(value: object) -> str:
    return "unknown" if value is None else str(value)


def _terminal_text(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)[1:-1]


def render_report(value: dict[str, Any]) -> str:
    lines = [
        (
            "Flight Recorder report "
            f"(last {value['window']['requested']}, "
            f"policy {value['policy_version']})"
        ),
        f"Episodes: {len(value['cards'])}",
    ]
    for card in value["cards"]:
        lines.extend(
            (
                "",
                f"Episode {card['episode_id']}",
                (
                    f"  Time: {card['time']['first_recorded_at']} .. "
                    f"{card['time']['last_recorded_at']}"
                ),
                (
                    "  Harnesses: "
                    + ", ".join(_terminal_text(item) for item in card["harnesses"])
                ),
                (
                    "  Models: "
                    + (
                        ", ".join(
                            _terminal_text(item) for item in card["models"]
                        )
                        or "unknown"
                    )
                ),
                f"  Task type: {_display(card['task_type'])}",
                f"  Elapsed ms: {card['elapsed_ms']}",
                (
                    "  Measured duration ms: "
                    f"{_display(card['measured_duration_ms']['value'])} "
                    f"({card['measured_duration_ms']['state']})"
                ),
                (
                    "  Measured cost USD: "
                    f"{_display(card['measured_cost_usd']['value'])} "
                    f"({card['measured_cost_usd']['state']})"
                ),
                (
                    "  Outcomes: "
                    f"success={card['deterministic_outcomes']['success']} "
                    f"failure={card['deterministic_outcomes']['failure']} "
                    f"unknown={card['deterministic_outcomes']['unknown']} "
                    "not-recorded="
                    f"{card['deterministic_outcomes']['not_recorded']}"
                ),
                f"  Retry count: {_display(card['retry_count'])}",
                (
                    "  Confidence: "
                    + (
                        "unknown"
                        if card["confidence"] is None
                        else (
                            f"minimum-score="
                            f"{card['confidence']['minimum_supporting_score']} "
                            f"threshold={card['confidence']['threshold']}"
                        )
                    )
                ),
                f"  Source events: {len(card['source_event_ids'])}",
            )
        )
    return "\n".join(lines)


def render_inspect(value: dict[str, Any]) -> str:
    card = value["card"]
    lines = [
        f"Flight Recorder inspect {card['episode_id']}",
        f"Policy: {value['policy_version']}",
        f"Events: {card['event_count']}",
        (
            "Harnesses: "
            + ", ".join(_terminal_text(item) for item in card["harnesses"])
        ),
        (
            "Models: "
            + (
                ", ".join(_terminal_text(item) for item in card["models"])
                or "unknown"
            )
        ),
        f"Task type: {_display(card['task_type'])}",
        f"Elapsed ms: {card['elapsed_ms']}",
        (
            "Measured duration ms: "
            f"{_display(card['measured_duration_ms']['value'])} "
            f"({card['measured_duration_ms']['state']})"
        ),
        (
            "Measured cost USD: "
            f"{_display(card['measured_cost_usd']['value'])} "
            f"({card['measured_cost_usd']['state']})"
        ),
        (
            "Outcomes: "
            f"success={card['deterministic_outcomes']['success']} "
            f"failure={card['deterministic_outcomes']['failure']} "
            f"unknown={card['deterministic_outcomes']['unknown']} "
            f"not-recorded={card['deterministic_outcomes']['not_recorded']}"
        ),
        f"Retry count: {_display(card['retry_count'])}",
        (
            "Confidence: "
            + (
                "unknown"
                if card["confidence"] is None
                else (
                    f"minimum-score="
                    f"{card['confidence']['minimum_supporting_score']} "
                    f"threshold={card['confidence']['threshold']}"
                )
            )
        ),
        "Source evidence IDs:",
        *(f"  {event_id}" for event_id in card["source_event_ids"]),
        "Supporting relationship edges:",
    ]
    if value["supporting_edges"]:
        for edge in value["supporting_edges"]:
            lines.extend(
                (
                    (
                        f"  {edge['left_event_id']} -> "
                        f"{edge['right_event_id']} "
                        f"score={edge['score']} "
                        f"decision={edge['decision']}"
                    ),
                    (
                        "    evidence="
                        + canonical_json(edge["evidence"]).decode("utf-8")
                    ),
                )
            )
    else:
        lines.append("  none (singleton or insufficient evidence)")
    return "\n".join(lines)


def emit(value: dict[str, Any], *, as_json: bool, human: str) -> None:
    if as_json:
        print(canonical_json(value).decode("utf-8"))
    else:
        print(human)
