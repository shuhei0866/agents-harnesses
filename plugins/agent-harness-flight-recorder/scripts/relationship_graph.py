#!/usr/bin/env python3
"""Deterministic, versioned relationship views derived from source events."""

from __future__ import annotations

import hashlib
import itertools
import json
import math
import sqlite3
import os
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, parse_time
from vault import VaultError


DEFAULT_POLICY: dict[str, Any] = {
    "schema_version": 1,
    "policy_version": "default-v1",
    "threshold": 500,
    "weights": {
        "explicit_task_match": 600,
        "workspace_match": 100,
        "branch_or_worktree_match": 150,
        "changed_file_overlap": 150,
    },
    "time_buckets": [
        {"max_seconds": 300, "contribution": 100},
        {"max_seconds": 3600, "contribution": 25},
    ],
    "time_window_seconds": 3600,
    "hard_veto": {"contradictory_task_ids": True},
}


@dataclass(frozen=True)
class Event:
    event_id: str
    recorded_at: str
    workspace_id: str | None
    task_id: str | None
    branch_id: str | None
    files: tuple[str, ...]
    files_state: str


def _integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_policy(value: object) -> dict[str, Any]:
    fields = {
        "schema_version", "policy_version", "threshold", "weights",
        "time_buckets", "time_window_seconds", "hard_veto",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise VaultError("relationship policy has invalid fields")
    if value["schema_version"] != 1:
        raise VaultError("relationship policy schema is unsupported")
    version = value["policy_version"]
    if (
        not isinstance(version, str)
        or not version
        or len(version) > 128
        or any(character not in
               "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
               for character in version)
    ):
        raise VaultError("relationship policy version is invalid")
    if (
        not _integer(value["threshold"])
        or value["threshold"] < 0
        or value["threshold"] > 1_000_000_000
    ):
        raise VaultError("relationship policy threshold must be an integer")
    weights = value["weights"]
    weight_fields = {
        "explicit_task_match", "workspace_match",
        "branch_or_worktree_match", "changed_file_overlap",
    }
    if (
        not isinstance(weights, dict)
        or set(weights) != weight_fields
        or any(
            not _integer(item) or item < 0 or item > 1_000_000_000
            for item in weights.values()
        )
    ):
        raise VaultError("relationship policy weights are invalid")
    buckets = value["time_buckets"]
    if not isinstance(buckets, list):
        raise VaultError("relationship policy time buckets are invalid")
    previous = -1
    for bucket in buckets:
        if (
            not isinstance(bucket, dict)
            or set(bucket) != {"max_seconds", "contribution"}
            or not _integer(bucket["max_seconds"])
            or bucket["max_seconds"] < 0
            or bucket["max_seconds"] > 1_000_000_000
            or bucket["max_seconds"] <= previous
            or not _integer(bucket["contribution"])
            or bucket["contribution"] < 0
            or bucket["contribution"] > 1_000_000_000
        ):
            raise VaultError("relationship policy time buckets are invalid")
        previous = bucket["max_seconds"]
    window = value["time_window_seconds"]
    if not _integer(window) or window < 0 or window > 1_000_000_000:
        raise VaultError("relationship policy time window is invalid")
    veto = value["hard_veto"]
    if (
        not isinstance(veto, dict)
        or set(veto) != {"contradictory_task_ids"}
        or not isinstance(veto["contradictory_task_ids"], bool)
    ):
        raise VaultError("relationship policy hard veto is invalid")
    # Normalize through canonical JSON so callers cannot mutate nested values.
    return json.loads(canonical_json(value))


def load_policy(path: Path | None) -> dict[str, Any]:
    if path is None:
        return validate_policy(DEFAULT_POLICY)
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_NONBLOCK", 0)
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            os.close(descriptor)
            raise VaultError("relationship policy file is unsafe")
        try:
            raw = os.read(descriptor, 64 * 1024 + 1)
        finally:
            os.close(descriptor)
        if len(raw) > 64 * 1024:
            raise VaultError("relationship policy file is too large")
        return validate_policy(json.loads(raw.decode("utf-8")))
    except VaultError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("relationship policy file is invalid") from error


def load_stored_policies(
    connection: sqlite3.Connection,
) -> list[dict[str, Any]]:
    """Authenticate every persisted policy definition before reusing it."""
    policies: list[dict[str, Any]] = []
    for version, schema_version, digest, encoded in connection.execute(
        """
        SELECT policy_version, schema_version, policy_sha256, policy_json
        FROM relationship_policies ORDER BY policy_version
        """
    ):
        try:
            decoded = json.loads(encoded)
        except (TypeError, json.JSONDecodeError) as error:
            raise VaultError("stored relationship policy is invalid") from error
        policy = validate_policy(decoded)
        canonical = canonical_json(policy).decode("utf-8")
        expected_digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
        if (
            policy["policy_version"] != version
            or policy["schema_version"] != schema_version
            or canonical != encoded
            or expected_digest != digest
        ):
            raise VaultError("stored relationship policy is not canonical")
        if (
            version == DEFAULT_POLICY["policy_version"]
            and canonical != canonical_json(DEFAULT_POLICY).decode("utf-8")
        ):
            raise VaultError("bundled relationship policy was replaced")
        policies.append(policy)
    if not any(
        policy["policy_version"] == DEFAULT_POLICY["policy_version"]
        for policy in policies
    ):
        policies.append(validate_policy(DEFAULT_POLICY))
    return sorted(policies, key=lambda policy: policy["policy_version"])


def _events(connection: sqlite3.Connection) -> list[Event]:
    rows = connection.execute(
        """
        SELECT event_id, recorded_at, workspace_id, relationship_task_id_hash,
               relationship_branch_or_worktree_id,
               relationship_changed_file_fingerprints_json,
               relationship_changed_files_state
        FROM source_events ORDER BY event_id
        """
    )
    result = []
    for row in rows:
        files = tuple(json.loads(row[5])) if row[5] is not None else ()
        result.append(Event(row[0], row[1], row[2], row[3], row[4],
                            files, row[6] or "missing"))
    return result


def _state(left: str | None, right: str | None) -> str:
    if left is None or right is None:
        return "missing"
    return "match" if left == right else "mismatch"


def score_pair(
    left: Event, right: Event, policy: dict[str, Any]
) -> tuple[int, str, str]:
    weights = policy["weights"]
    task_state = _state(left.task_id, right.task_id)
    contradiction = (
        left.task_id is not None
        and right.task_id is not None
        and left.task_id != right.task_id
    )
    workspace_state = _state(left.workspace_id, right.workspace_id)
    branch_state = _state(left.branch_id, right.branch_id)
    complete_files = (
        left.files_state == "complete"
        and right.files_state == "complete"
        and bool(left.files)
        and bool(right.files)
    )
    overlap = len(set(left.files) & set(right.files)) if complete_files else 0
    files_state = "match" if overlap else (
        "mismatch" if complete_files else "missing"
    )
    seconds = math.ceil(abs(
        (parse_time(left.recorded_at) - parse_time(right.recorded_at))
        .total_seconds()
    ))
    time_contribution = 0
    for bucket in policy["time_buckets"]:
        if seconds <= bucket["max_seconds"]:
            time_contribution = bucket["contribution"]
            break
    contributions = {
        "task": weights["explicit_task_match"] if task_state == "match" else 0,
        "workspace": weights["workspace_match"]
        if workspace_state == "match" else 0,
        "branch": weights["branch_or_worktree_match"]
        if branch_state == "match" else 0,
        "files": weights["changed_file_overlap"] if overlap else 0,
        "time": time_contribution
        if seconds <= policy["time_window_seconds"] else 0,
    }
    evidence = {
        "explicit_task_id": {
            "state": task_state, "contribution": contributions["task"]
        },
        "workspace_id": {
            "state": workspace_state, "contribution": contributions["workspace"]
        },
        "branch_or_worktree_id": {
            "state": branch_state, "contribution": contributions["branch"]
        },
        "time_distance": {
            "state": (
                "within_window"
                if seconds <= policy["time_window_seconds"]
                else "outside_window"
            ),
            "seconds": seconds,
            "contribution": contributions["time"],
        },
        "changed_file_fingerprints": {
            "state": files_state,
            "intersection_count": overlap,
            "contribution": contributions["files"],
        },
        "contradictory_task_ids": {
            "state": "contradiction" if contradiction else "clear",
            "contribution": 0,
        },
    }
    score = sum(contributions.values())
    if contradiction and policy["hard_veto"]["contradictory_task_ids"]:
        decision = "hard_veto"
    elif (
        seconds > policy["time_window_seconds"]
        and task_state != "match"
    ):
        decision = "no_link"
    else:
        decision = "link" if score >= policy["threshold"] else "no_link"
    return score, decision, canonical_json(evidence).decode("utf-8")


class Components:
    def __init__(self, events: list[Event]) -> None:
        self.parent = {event.event_id: event.event_id for event in events}
        self.tasks = {
            event.event_id: ({event.task_id} if event.task_id else set())
            for event in events
        }

    def find(self, item: str) -> str:
        while self.parent[item] != item:
            self.parent[item] = self.parent[self.parent[item]]
            item = self.parent[item]
        return item

    def join(self, left: str, right: str) -> bool:
        a, b = self.find(left), self.find(right)
        if a == b:
            return True
        if len(self.tasks[a] | self.tasks[b]) > 1:
            return False
        keep, drop = sorted((a, b))
        self.parent[drop] = keep
        self.tasks[keep] |= self.tasks[drop]
        return True


def rebuild_relationships(
    connection: sqlite3.Connection, policy: dict[str, Any]
) -> tuple[int, int]:
    policy = validate_policy(policy)
    version = policy["policy_version"]
    events = _events(connection)
    by_id = {event.event_id: event for event in events}
    candidate_ids: set[tuple[str, str]] = set()
    chronological = sorted(
        (parse_time(event.recorded_at), event.event_id)
        for event in events
    )
    window = policy["time_window_seconds"]
    for index, (left_time, left_id) in enumerate(chronological):
        for right_time, right_id in chronological[index + 1:]:
            if (right_time - left_time).total_seconds() > window:
                break
            candidate_ids.add(tuple(sorted((left_id, right_id))))
    task_groups: dict[str, list[str]] = {}
    for event in events:
        if event.task_id is not None:
            task_groups.setdefault(event.task_id, []).append(event.event_id)
    for group in task_groups.values():
        candidate_ids.update(
            tuple(sorted(pair)) for pair in itertools.combinations(group, 2)
        )

    pairs: list[tuple[int, str, str, str, str]] = []
    for left_id, right_id in sorted(candidate_ids):
        left, right = by_id[left_id], by_id[right_id]
        score, decision, evidence = score_pair(left, right, policy)
        pairs.append(
            (score, left.event_id, right.event_id, decision, evidence)
        )
    components = Components(events)
    conflicts: set[tuple[str, str]] = set()
    for score, left, right, decision, _evidence in sorted(
        pairs, key=lambda item: (-item[0], item[1], item[2])
    ):
        if decision == "link" and not components.join(left, right):
            conflicts.add((left, right))
    pairs = [
        (
            score,
            left,
            right,
            "component_conflict" if (left, right) in conflicts else decision,
            evidence,
        )
        for score, left, right, decision, evidence in pairs
    ]

    encoded_policy = canonical_json(policy).decode("utf-8")
    policy_digest = hashlib.sha256(encoded_policy.encode("utf-8")).hexdigest()
    existing_policy = connection.execute(
        "SELECT policy_sha256 FROM relationship_policies "
        "WHERE policy_version = ?",
        (version,),
    ).fetchone()
    if existing_policy is not None and existing_policy[0] != policy_digest:
        raise VaultError(
            "relationship policy version conflicts with existing definition"
        )
    connection.execute(
        "DELETE FROM episode_members WHERE policy_version = ?", (version,)
    )
    connection.execute("DELETE FROM episodes WHERE policy_version = ?", (version,))
    connection.execute(
        "DELETE FROM relationship_edges WHERE policy_version = ?", (version,)
    )
    connection.execute(
        "DELETE FROM relationship_policies WHERE policy_version = ?", (version,)
    )
    connection.execute(
        "INSERT INTO relationship_policies VALUES (?, ?, ?, ?)",
        (version, policy["schema_version"], policy_digest, encoded_policy),
    )
    connection.executemany(
        "INSERT INTO relationship_edges VALUES (?, ?, ?, ?, ?, ?)",
        [
            (version, left, right, score, decision, evidence)
            for score, left, right, decision, evidence in pairs
        ],
    )
    groups: dict[str, list[str]] = {}
    for event in events:
        groups.setdefault(components.find(event.event_id), []).append(event.event_id)
    episode_rows = []
    member_rows = []
    for members in sorted((sorted(group) for group in groups.values())):
        identity = hashlib.sha256(
            (version + "\0" + "\0".join(members)).encode("utf-8")
        ).hexdigest()
        episode_id = f"sha256:{identity}"
        episode_rows.append((version, episode_id, len(members)))
        member_rows.extend(
            (version, episode_id, event_id, ordinal)
            for ordinal, event_id in enumerate(members)
        )
    connection.executemany("INSERT INTO episodes VALUES (?, ?, ?)", episode_rows)
    connection.executemany(
        "INSERT INTO episode_members VALUES (?, ?, ?, ?)", member_rows
    )
    return len(pairs), len(episode_rows)
