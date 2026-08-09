#!/usr/bin/env python3
"""Compile grounded, shared value primitives from authenticated Episodes."""

from __future__ import annotations

import hashlib
import contextlib
import fcntl
import json
import math
import os
import re
import stat
import time
from pathlib import Path
from typing import Any
from typing import Iterator

from chunk_rotation import canonical_json, parse_time, safe_subdirectory
from evaluation import _evaluated_at, _executable_identity, _invoke, _safe_name
from meaning_lift import _read_card_record as _read_meaning_card_record
from meaning_lift import _stored_cards as stored_meaning_cards
from reporting import (
    _authenticated_query_locked,
    _edges_by_episode,
    _episode_card,
    _policy_selection,
)
from retention_state import load_forgotten
from semantic_receipts import _read_stored_receipt
from semantic_receipts import _stored_receipts
from vault import VaultError, atomic_replace, ensure_managed_gitignore, vault_lock


OUTPUT_VERSION = 1
CARD_VERSION = 1
PACKET_CONTRACT = "value-compiler-packet-v1"
CARD_CONTRACT = "value-primitive-card-v1"
MAX_CARD_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
MAX_SUMMARY_TEXT = 512
MAX_EPISODES = 100
MAX_COST_MICROUSD = 10_000_000
MAX_BLOCKING_LOCK_WAIT_SECONDS = 30
LOCK_POLL_SECONDS = 0.05
RUN_LOCK_PATH = Path("value-compiler/run.lock")
ATTEMPTS_PATH = Path("value-compiler/attempts.json")
PREPARED_DIRECTORY = Path("value-compiler/prepared")
PREPARED_CONTRACT = "value-compiler-prepared-v1"
MAX_ATTEMPTS = 1_000
MAX_ATTEMPTS_BYTES = 1024 * 1024
MAX_PREPARED_ENVELOPE_BYTES = 4 * 1024
MAX_PREPARED_BYTES = MAX_CARD_BYTES + MAX_PREPARED_ENVELOPE_BYTES
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.IGNORECASE
)
CARD_FILE_RE = re.compile(r"^[0-9a-f]{64}\.json$")
ATOMIC_TEMP_RE = re.compile(
    r"^\.[0-9a-f]{64}\.json\.[A-Za-z0-9_-]+$"
)
AXES = (
    "goal_achievement",
    "deliverable_quality",
    "risk_reduction",
    "learning",
    "reuse_potential",
    "decision_leverage",
    "attention_saved",
    "rework",
)
STATES = {"positive", "negative", "mixed", "unknown"}
CONFIDENCE = {"low", "medium", "high"}
AXIS_EVIDENCE_FIELDS = {
    "goal_achievement": {
        "meaning.outcome",
        "receipt.result.outcome",
        "receipt.assessment.goal_achievement",
    },
    "deliverable_quality": {
        "meaning.deliverable",
        "meaning.verification",
        "receipt.task.deliverable",
        "receipt.assessment.quality",
    },
    # v0 has no dedicated, authenticated signals for these axes. Keeping the
    # allowlist empty forces them to unknown instead of inferring by analogy.
    "risk_reduction": set(),
    "learning": {"meaning.reusable_learning", "receipt.assessment.learning"},
    "reuse_potential": {
        "meaning.reusable_learning",
        "receipt.assessment.reuse",
    },
    "decision_leverage": set(),
    "attention_saved": set(),
    "rework": set(),
}
INPUT_EVIDENCE_FIELDS = {
    "meaning.intent", "meaning.deliverable", "meaning.verification",
    "meaning.outcome", "meaning.reusable_learning", "receipt.task.intent",
    "receipt.task.deliverable", "receipt.result.outcome",
    "receipt.assessment.goal_achievement", "receipt.assessment.quality",
    "receipt.assessment.efficiency",
}
CARD_FIELDS = {
    "schema_version", "contract_version", "value_primitive_card_id",
    "episode_id", "observations", "primitives", "provenance",
}
PROVENANCE_FIELDS = {
    "contract_version", "packet_sha256", "input_anchor_ids",
    "input_evidence_ids", "input_evidence_fields", "evaluator_model",
    "evaluator_adapter", "evaluator_adapter_sha256", "policy_version",
    "source_event_ids", "generated_at", "generation_cost_microusd",
    "latency_ms",
}
OBSERVATION_FIELDS = {
    "measured_duration_ms", "measured_cost_usd", "deterministic_outcomes",
    "deterministic_evidence",
}
ATTEMPT_FIELDS = {
    "fingerprint", "episode_id", "packet_sha256", "evaluator_model",
    "evaluator_adapter_sha256", "policy_version", "compiler_contract",
    "state", "updated_at", "value_primitive_card_id", "diagnostic_code",
}
ATTEMPT_STATES = {"pending", "prepared", "failed", "completed"}
ATTEMPT_DIAGNOSTICS = {
    "provider_or_validation_failed",
    "input_changed",
}
MEASUREMENT_FIELDS = {
    "value", "state", "aggregation", "known_event_count",
    "total_event_count",
}
MEASUREMENT_STATES = {"missing", "partial", "complete"}
OUTCOME_FIELDS = {
    "success", "failure", "unknown", "not_recorded", "evidence",
}
OUTCOME_EVIDENCE_FIELDS = {"event_id", "status", "exit_code"}
DETERMINISTIC_OBSERVATION_FIELDS = {
    "evidence_id", "evidence_type", "state",
}
DETERMINISTIC_STATES = {
    "success", "failure", "unknown", "missing", "present",
}
MAX_OBSERVATION_EVIDENCE = 10_000
PREPARED_FIELDS = {
    "schema_version", "contract_version", "fingerprint", "episode_id",
    "packet_sha256", "evaluator_model", "evaluator_adapter_sha256",
    "policy_version", "card",
}


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _attempt_fingerprint(
    packet_sha256: str,
    model: str,
    evaluator_sha256: str,
    policy_version: str,
) -> str:
    return _sha256(
        canonical_json(
            {
                "packet_sha256": packet_sha256,
                "evaluator_model": model,
                "evaluator_adapter_sha256": evaluator_sha256,
                "policy_version": policy_version,
                "compiler_contract": CARD_CONTRACT,
            }
        )
    )


def _validate_attempt(value: object) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != ATTEMPT_FIELDS:
        raise VaultError("Value Compiler attempt ledger is invalid")
    for field in (
        "fingerprint", "episode_id", "packet_sha256",
        "evaluator_adapter_sha256",
    ):
        item = value.get(field)
        if not isinstance(item, str) or HASH_RE.fullmatch(item) is None:
            raise VaultError("Value Compiler attempt ledger is invalid")
    for field in ("evaluator_model", "policy_version"):
        item = value.get(field)
        if (
            not isinstance(item, str)
            or not item
            or len(item) > 128
            or any(character in item for character in "\r\n\0")
        ):
            raise VaultError("Value Compiler attempt ledger is invalid")
    state = value.get("state")
    if (
        value.get("compiler_contract") != CARD_CONTRACT
        or not isinstance(state, str)
        or state not in ATTEMPT_STATES
    ):
        raise VaultError("Value Compiler attempt ledger is invalid")
    try:
        parse_time(value.get("updated_at"))
    except (TypeError, ValueError) as error:
        raise VaultError("Value Compiler attempt ledger is invalid") from error
    card_id = value.get("value_primitive_card_id")
    diagnostic = value.get("diagnostic_code")
    if (
        (card_id is not None and (
            not isinstance(card_id, str) or HASH_RE.fullmatch(card_id) is None
        ))
        or (diagnostic is not None and (
            not isinstance(diagnostic, str)
            or diagnostic not in ATTEMPT_DIAGNOSTICS
        ))
        or (state in {"pending", "prepared"} and (
            card_id is not None or diagnostic is not None
        ))
        or (state == "failed" and (card_id is not None or diagnostic is None))
        or (state == "completed" and (card_id is None or diagnostic is not None))
    ):
        raise VaultError("Value Compiler attempt ledger is invalid")
    expected = _attempt_fingerprint(
        value["packet_sha256"],
        value["evaluator_model"],
        value["evaluator_adapter_sha256"],
        value["policy_version"],
    )
    if value["fingerprint"] != expected:
        raise VaultError("Value Compiler attempt fingerprint is invalid")
    return value


def _validate_measurement(value: object, description: str) -> None:
    if not isinstance(value, dict) or set(value) != MEASUREMENT_FIELDS:
        raise VaultError(f"stored {description} observation is invalid")
    state = value.get("state")
    known = value.get("known_event_count")
    total = value.get("total_event_count")
    measured = value.get("value")
    if (
        not isinstance(state, str)
        or state not in MEASUREMENT_STATES
        or value.get("aggregation") != "sum_of_recorded_values"
        or isinstance(known, bool)
        or not isinstance(known, int)
        or isinstance(total, bool)
        or not isinstance(total, int)
        or not 0 <= known <= total <= MAX_OBSERVATION_EVIDENCE
        or total < 1
    ):
        raise VaultError(f"stored {description} observation is invalid")
    expected_state = (
        "missing" if known == 0
        else "complete" if known == total
        else "partial"
    )
    if state != expected_state:
        raise VaultError(f"stored {description} observation is invalid")
    if known == 0:
        if measured is not None:
            raise VaultError(f"stored {description} observation is invalid")
    else:
        try:
            finite = (
                not isinstance(measured, bool)
                and isinstance(measured, (int, float))
                and math.isfinite(measured)
                and measured >= 0
            )
        except (OverflowError, TypeError, ValueError):
            finite = False
        if not finite:
            raise VaultError(f"stored {description} observation is invalid")


def _validate_observations(value: object) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != OBSERVATION_FIELDS:
        raise VaultError("stored Value Primitive Card observations are invalid")
    _validate_measurement(value["measured_duration_ms"], "duration")
    _validate_measurement(value["measured_cost_usd"], "cost")
    outcomes = value.get("deterministic_outcomes")
    if not isinstance(outcomes, dict) or set(outcomes) != OUTCOME_FIELDS:
        raise VaultError("stored outcome observations are invalid")
    counts = []
    for field in ("success", "failure", "unknown", "not_recorded"):
        item = outcomes.get(field)
        if (
            isinstance(item, bool)
            or not isinstance(item, int)
            or not 0 <= item <= MAX_OBSERVATION_EVIDENCE
        ):
            raise VaultError("stored outcome observations are invalid")
        counts.append(item)
    total = value["measured_duration_ms"]["total_event_count"]
    if sum(counts) != total:
        raise VaultError("stored outcome observations are invalid")
    outcome_evidence = outcomes.get("evidence")
    if (
        not isinstance(outcome_evidence, list)
        or len(outcome_evidence) > MAX_OBSERVATION_EVIDENCE
    ):
        raise VaultError("stored outcome observations are invalid")
    observed_counts = {"success": 0, "failure": 0, "unknown": 0}
    event_ids = []
    for item in outcome_evidence:
        if (
            not isinstance(item, dict)
            or set(item) != OUTCOME_EVIDENCE_FIELDS
            or not isinstance(item.get("event_id"), str)
            or UUID_RE.fullmatch(item["event_id"]) is None
            or not isinstance(item.get("status"), str)
            or item["status"] not in observed_counts
        ):
            raise VaultError("stored outcome observations are invalid")
        exit_code = item.get("exit_code")
        if (
            exit_code is not None
            and (
                isinstance(exit_code, bool)
                or not isinstance(exit_code, int)
                or not 0 <= exit_code <= 255
            )
        ):
            raise VaultError("stored outcome observations are invalid")
        observed_counts[item["status"]] += 1
        event_ids.append(item["event_id"])
    if (
        event_ids != list(dict.fromkeys(event_ids))
        or any(outcomes[name] != count for name, count in observed_counts.items())
    ):
        raise VaultError("stored outcome observations are invalid")
    deterministic = value.get("deterministic_evidence")
    if (
        not isinstance(deterministic, list)
        or len(deterministic) > MAX_OBSERVATION_EVIDENCE
    ):
        raise VaultError("stored deterministic observations are invalid")
    evidence_ids = []
    for item in deterministic:
        if (
            not isinstance(item, dict)
            or set(item) != DETERMINISTIC_OBSERVATION_FIELDS
            or not isinstance(item.get("evidence_id"), str)
            or HASH_RE.fullmatch(item["evidence_id"]) is None
            or not isinstance(item.get("evidence_type"), str)
            or not item["evidence_type"]
            or len(item["evidence_type"]) > 128
            or any(character in item["evidence_type"] for character in "\r\n\0")
            or not isinstance(item.get("state"), str)
            or item["state"] not in DETERMINISTIC_STATES
        ):
            raise VaultError("stored deterministic observations are invalid")
        evidence_ids.append(item["evidence_id"])
    if evidence_ids != list(dict.fromkeys(evidence_ids)):
        raise VaultError("stored deterministic observations are invalid")
    return value


def _validate_attempts(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "attempts"}
        or value.get("schema_version") != 1
        or not isinstance(value.get("attempts"), list)
        or len(value["attempts"]) > MAX_ATTEMPTS
    ):
        raise VaultError("Value Compiler attempt ledger is invalid")
    attempts = [_validate_attempt(item) for item in value["attempts"]]
    fingerprints = [item["fingerprint"] for item in attempts]
    if fingerprints != sorted(set(fingerprints)):
        raise VaultError("Value Compiler attempt ledger is invalid")
    return value


def _load_attempts_with_raw(root: Path) -> tuple[bytes | None, dict[str, Any]]:
    directory = root / "value-compiler"
    if directory.is_symlink():
        raise VaultError("Value Compiler attempt directory is unsafe")
    if not directory.exists():
        return None, {"schema_version": 1, "attempts": []}
    try:
        directory_metadata = directory.lstat()
    except OSError as error:
        raise VaultError("Value Compiler attempt directory is unsafe") from error
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.geteuid()
        or directory_metadata.st_mode & 0o077
    ):
        raise VaultError("Value Compiler attempt directory is unsafe")
    path = root / ATTEMPTS_PATH
    if not path.exists() and not path.is_symlink():
        return None, {"schema_version": 1, "attempts": []}
    descriptor = -1
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
            or metadata.st_size > MAX_ATTEMPTS_BYTES
        ):
            raise VaultError("Value Compiler attempt ledger is unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_ATTEMPTS_BYTES + 1)
        after = path.lstat()
        if any(
            (
                after.st_dev != metadata.st_dev,
                after.st_ino != metadata.st_ino,
                after.st_size != metadata.st_size,
                after.st_mtime_ns != metadata.st_mtime_ns,
                after.st_ctime_ns != metadata.st_ctime_ns,
            )
        ):
            raise VaultError("Value Compiler attempt ledger changed while reading")
        value = _validate_attempts(json.loads(raw))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("Value Compiler attempt ledger is invalid or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return raw, value


def _load_attempts(root: Path) -> dict[str, Any]:
    return _load_attempts_with_raw(root)[1]


def _store_attempts(root: Path, value: dict[str, Any]) -> None:
    validated = _validate_attempts(value)
    directory = safe_subdirectory(root, "value-compiler")
    data = canonical_json(validated) + b"\n"
    if len(data) > MAX_ATTEMPTS_BYTES:
        raise VaultError("Value Compiler attempt ledger exceeds size limit")
    atomic_replace(root / ATTEMPTS_PATH, data)
    directory.chmod(0o700)


def _new_attempt(
    episode_id: str,
    packet_sha256: str,
    model: str,
    evaluator_sha256: str,
    policy_version: str,
) -> dict[str, Any]:
    result = {
        "fingerprint": _attempt_fingerprint(
            packet_sha256, model, evaluator_sha256, policy_version
        ),
        "episode_id": episode_id,
        "packet_sha256": packet_sha256,
        "evaluator_model": model,
        "evaluator_adapter_sha256": evaluator_sha256,
        "policy_version": policy_version,
        "compiler_contract": CARD_CONTRACT,
        "state": "pending",
        "updated_at": _evaluated_at(),
        "value_primitive_card_id": None,
        "diagnostic_code": None,
    }
    return result


def _replace_attempt(
    root: Path,
    fingerprint: str,
    state: str,
    *,
    card_id: str | None = None,
    diagnostic_code: str | None = None,
) -> None:
    ledger = _load_attempts(root)
    changed = False
    attempts = []
    for item in ledger["attempts"]:
        if item["fingerprint"] == fingerprint:
            item = {
                **item,
                "state": state,
                "updated_at": _evaluated_at(),
                "value_primitive_card_id": card_id,
                "diagnostic_code": diagnostic_code,
            }
            changed = True
        attempts.append(item)
    if not changed:
        raise VaultError("Value Compiler attempt reservation is missing")
    _store_attempts(
        root,
        {"schema_version": 1, "attempts": sorted(
            attempts, key=lambda item: item["fingerprint"]
        )},
    )


def _remove_attempt(root: Path, fingerprint: str) -> None:
    ledger = _load_attempts(root)
    remaining = [
        item for item in ledger["attempts"]
        if item["fingerprint"] != fingerprint
    ]
    if len(remaining) == len(ledger["attempts"]):
        raise VaultError("Value Compiler attempt reservation is missing")
    _store_attempts(
        root,
        {"schema_version": 1, "attempts": remaining},
    )


def _fail_attempt_if_present(
    root: Path,
    fingerprint: str,
    diagnostic_code: str,
) -> None:
    if any(
        item["fingerprint"] == fingerprint
        for item in _load_attempts(root)["attempts"]
    ):
        _replace_attempt(
            root,
            fingerprint,
            "failed",
            diagnostic_code=diagnostic_code,
        )


def _prune_completed_attempts(root: Path) -> dict[str, Any]:
    ledger = _load_attempts(root)
    remaining = [
        item for item in ledger["attempts"]
        if item["state"] != "completed"
    ]
    if len(remaining) != len(ledger["attempts"]):
        _store_attempts(
            root,
            {"schema_version": 1, "attempts": remaining},
        )
    return {"schema_version": 1, "attempts": remaining}


def value_attempt_record_count(
    root: Path,
    episode_id: str,
    policy_version: str | None = None,
) -> int:
    return sum(
        item["episode_id"] == episode_id
        and (
            policy_version is None
            or item["policy_version"] == policy_version
        )
        for item in _load_attempts(root)["attempts"]
    )


def remove_episode_attempts(
    root: Path,
    episode_id: str,
    policy_version: str | None = None,
) -> bytes | None:
    """Remove one Episode's attempts under caller-held run/Vault locks."""
    raw, ledger = _load_attempts_with_raw(root)
    if raw is None:
        return None
    remaining = [
        item for item in ledger["attempts"]
        if not (
            item["episode_id"] == episode_id
            and (
                policy_version is None
                or item["policy_version"] == policy_version
            )
        )
    ]
    _store_attempts(
        root,
        {"schema_version": 1, "attempts": remaining},
    )
    return raw


def restore_attempts(root: Path, snapshot: bytes | None) -> None:
    path = root / ATTEMPTS_PATH
    if snapshot is None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return
    if len(snapshot) > MAX_ATTEMPTS_BYTES:
        raise VaultError("Value Compiler attempt snapshot is invalid")
    try:
        _validate_attempts(json.loads(snapshot))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("Value Compiler attempt snapshot is invalid") from error
    atomic_replace(path, snapshot)


def _evidence_id(source: str, anchor_id: str, field: str, content: object) -> str:
    return _sha256(
        canonical_json(
            {"source": source, "anchor_id": anchor_id, "field": field, "content": content}
        )
    )


def _meaning_evidence(card: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    anchor_id = card["meaning_card_id"]
    for name in ("intent", "deliverable", "verification", "outcome", "reusable_learning"):
        item = card[name]
        content: dict[str, Any] = {"summary": item["summary"]}
        if name == "outcome":
            content["state"] = item["state"]
        field = f"meaning.{name}"
        result.append(
            {
                "evidence_id": _evidence_id("meaning_card", anchor_id, field, content),
                "source": "meaning_card",
                "anchor_id": anchor_id,
                "field": field,
                "content": content,
            }
        )
    return result


def _receipt_evidence(receipt: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    anchor_id = receipt["receipt_id"]
    mappings = (
        ("receipt.task.intent", receipt["task"].get("intent")),
        ("receipt.task.deliverable", receipt["task"].get("deliverable")),
        ("receipt.result.outcome", receipt["result"].get("outcome")),
    )
    for field, content in mappings:
        if content is None:
            continue
        result.append(
            {
                "evidence_id": _evidence_id("semantic_receipt", anchor_id, field, content),
                "source": "semantic_receipt",
                "anchor_id": anchor_id,
                "field": field,
                "content": content,
            }
        )
    for name, criterion in receipt["assessment"]["criteria"].items():
        field = f"receipt.assessment.{name}"
        content = {"state": criterion["state"]}
        result.append(
            {
                "evidence_id": _evidence_id(
                    "semantic_receipt", anchor_id, field, content
                ),
                "source": "semantic_receipt",
                "anchor_id": anchor_id,
                "field": field,
                "content": content,
            }
        )
    return result


def _observations(card: dict[str, Any]) -> dict[str, Any]:
    return {
        "measured_duration_ms": card["measured_duration_ms"],
        "measured_cost_usd": card["measured_cost_usd"],
        "deterministic_outcomes": card["deterministic_outcomes"],
        "deterministic_evidence": [
            {
                "evidence_id": item["evidence_id"],
                "evidence_type": item["evidence_type"],
                "state": item["state"],
            }
            for item in card["deterministic_evidence"]
        ],
    }


def _edges_for_episode_ids(
    connection: Any,
    policy_version: str,
    episode_ids: set[str],
) -> dict[str, list[dict[str, Any]]]:
    if not episode_ids:
        return {}
    placeholders = ",".join("?" for _item in episode_ids)
    query = f"""
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
          AND left_member.episode_id IN ({placeholders})
        ORDER BY left_member.episode_id, edge.left_event_id,
                 edge.right_event_id
    """
    result: dict[str, list[dict[str, Any]]] = {}
    for episode_id, left, right, score, decision, encoded in connection.execute(
        query, (policy_version, *sorted(episode_ids))
    ):
        try:
            evidence = json.loads(encoded)
        except (TypeError, json.JSONDecodeError) as error:
            raise VaultError("relationship evidence is invalid") from error
        result.setdefault(episode_id, []).append({
            "left_event_id": left,
            "right_event_id": right,
            "score": score,
            "decision": decision,
            "evidence": evidence,
        })
    return result


def _episodes(
    root: Path,
    policy_version: str,
    trusted: dict[str, Any] | None,
    episode_ids: set[str],
) -> list[dict[str, Any]]:
    forgotten = load_forgotten(root)

    def query(connection: Any, policy: dict[str, Any]) -> list[dict[str, Any]]:
        edges = _edges_for_episode_ids(
            connection, policy_version, episode_ids
        )
        result = []
        for episode_id in sorted(episode_ids):
            if (policy_version, episode_id) in forgotten:
                continue
            found = connection.execute(
                "SELECT 1 FROM episodes "
                "WHERE policy_version = ? AND episode_id = ?",
                (policy_version, episode_id),
            ).fetchone()
            if found is None:
                continue
            card, _supporting = _episode_card(root, connection, policy, episode_id, edges)
            result.append(card)
        return result

    return _authenticated_query_locked(root, policy_version, query, trusted)


def _anchors_by_episode(
    policy_version: str,
    episodes: list[dict[str, Any]],
    meanings: list[dict[str, Any]],
    receipts: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    episode_map = {item["episode_id"]: item for item in episodes}
    anchors: dict[str, dict[str, Any]] = {}
    for meaning in meanings:
        episode = episode_map.get(meaning["episode_id"])
        provenance = meaning["provenance"]
        if (
            episode is not None
            and provenance["policy_version"] == policy_version
            and provenance["source_event_ids"] == episode["source_event_ids"]
        ):
            current = anchors.setdefault(meaning["episode_id"], {})
            prior = current.get("meaning")
            if prior is None or (
                parse_time(provenance["generated_at"]), meaning["meaning_card_id"]
            ) > (
                parse_time(prior["provenance"]["generated_at"]), prior["meaning_card_id"]
            ):
                current["meaning"] = meaning
    for receipt in receipts:
        episode = episode_map.get(receipt["episode_id"])
        provenance = receipt["provenance"]
        if (
            episode is not None
            and provenance["policy_version"] == policy_version
            and provenance["source_event_ids"] == episode["source_event_ids"]
            and set(provenance["evidence_ids"]).issubset(
                {item["evidence_id"] for item in episode["deterministic_evidence"]}
            )
        ):
            current = anchors.setdefault(receipt["episode_id"], {})
            prior = current.get("receipt")
            if prior is None or (
                parse_time(provenance["generated_at"]), receipt["receipt_id"]
            ) > (
                parse_time(prior["provenance"]["generated_at"]), prior["receipt_id"]
            ):
                current["receipt"] = receipt
    return anchors


def _packet(episode: dict[str, Any], anchors: dict[str, Any]) -> dict[str, Any]:
    evidence: list[dict[str, Any]] = []
    anchor_ids = []
    meaning = anchors.get("meaning")
    if meaning is not None:
        evidence.extend(_meaning_evidence(meaning))
        anchor_ids.append(meaning["meaning_card_id"])
    receipt = anchors.get("receipt")
    if receipt is not None:
        evidence.extend(_receipt_evidence(receipt))
        anchor_ids.append(receipt["receipt_id"])
    packet_without_hash = {
        "contract_version": PACKET_CONTRACT,
        "episode_id": episode["episode_id"],
        "anchor_ids": sorted(anchor_ids),
        "evidence": sorted(evidence, key=lambda item: item["evidence_id"]),
        "observations": _observations(episode),
    }
    return {
        **packet_without_hash,
        "packet_sha256": _sha256(canonical_json(packet_without_hash)),
    }


def _checked_summary(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > MAX_SUMMARY_TEXT
        or any(character in value for character in "\r\0")
    ):
        raise VaultError("value evaluator response summary is invalid")
    return value


def _directional_state(item: dict[str, Any]) -> str | None:
    field = item["field"]
    content = item["content"]
    if field == "meaning.outcome":
        raw = content.get("state") if isinstance(content, dict) else None
        return {
            "success": "positive",
            "failure": "negative",
            "mixed": "mixed",
        }.get(raw)
    if field == "receipt.result.outcome":
        return {
            "success": "positive",
            "failure": "negative",
            "mixed": "mixed",
        }.get(content)
    if field in {
        "receipt.assessment.goal_achievement",
        "receipt.assessment.quality",
    }:
        raw = content.get("state") if isinstance(content, dict) else None
        return {
            "supported": "positive",
            "unsupported": "negative",
        }.get(raw)
    return None


def _validate_directional_grounding(
    axis: str,
    state: str,
    references: list[str],
    evidence: dict[str, dict[str, Any]],
) -> None:
    if state == "unknown":
        return
    directional_fields = {
        "goal_achievement": {
            "meaning.outcome",
            "receipt.result.outcome",
            "receipt.assessment.goal_achievement",
        },
        "deliverable_quality": {"receipt.assessment.quality"},
    }
    fields = directional_fields.get(axis)
    if fields is None:
        return
    available = [
        item for item in evidence.values() if item["field"] in fields
    ]
    cited = [evidence[reference] for reference in references]
    cited_directional = [item for item in cited if item["field"] in fields]
    # Goal claims always require explicit outcome direction. A structured
    # quality criterion, when present, is authoritative; bounded Meaning text
    # remains supplementary rather than overriding that direction.
    direction_required = axis == "goal_achievement" or bool(available)
    if direction_required and not any(
        _directional_state(item) == state for item in cited_directional
    ):
        raise VaultError(
            f"value evaluator {axis.replace('_', ' ')} direction is invalid"
        )


def _validate_response(raw: bytes, packet: dict[str, Any], budget: int) -> tuple[dict[str, Any], int]:
    if len(raw) > MAX_RESPONSE_BYTES:
        raise VaultError("value evaluator response is too large")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("value evaluator response is invalid") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "primitives", "measured_cost_microusd"}
        or value.get("schema_version") != 1
        or not isinstance(value.get("primitives"), dict)
        or set(value["primitives"]) != set(AXES)
    ):
        raise VaultError("value evaluator response is invalid")
    cost = value["measured_cost_microusd"]
    if isinstance(cost, bool) or not isinstance(cost, int) or not 0 <= cost <= budget:
        raise VaultError("value evaluator response violates the cost budget")
    evidence = {item["evidence_id"]: item for item in packet["evidence"]}
    primitives = {}
    for axis in AXES:
        item = value["primitives"][axis]
        if not isinstance(item, dict) or set(item) != {
            "state", "summary", "confidence", "evidence_references"
        }:
            raise VaultError("value evaluator primitive is invalid")
        state = item["state"]
        refs = item["evidence_references"]
        if (
            not isinstance(state, str)
            or state not in STATES
            or not isinstance(item["confidence"], str)
            or item["confidence"] not in CONFIDENCE
            or not isinstance(refs, list)
            or any(not isinstance(ref, str) for ref in refs)
            or len(refs) != len(set(refs))
            or refs != sorted(refs)
            or any(ref not in evidence for ref in refs)
        ):
            raise VaultError("value evaluator evidence is invalid")
        allowed = AXIS_EVIDENCE_FIELDS[axis]
        if any(evidence[ref]["field"] not in allowed for ref in refs):
            raise VaultError("value evaluator evidence is not allowed for axis")
        _validate_directional_grounding(axis, state, refs, evidence)
        if state == "unknown":
            if refs:
                raise VaultError("unknown value primitive must not cite evidence")
            basis = "unknown"
        else:
            if not refs:
                raise VaultError("inferred value primitive requires evidence")
            basis = "inferred"
        primitives[axis] = {
            "state": state,
            "basis": basis,
            "summary": _checked_summary(item["summary"]),
            "confidence": item["confidence"],
            "evidence_references": refs,
        }
    return primitives, cost


def _validate_card(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != CARD_FIELDS
        or value.get("schema_version") != CARD_VERSION
    ):
        raise VaultError("stored Value Primitive Card is invalid")
    if (
        value.get("contract_version") != CARD_CONTRACT
        or not isinstance(value.get("primitives"), dict)
        or set(value["primitives"]) != set(AXES)
    ):
        raise VaultError("stored Value Primitive Card is invalid")
    _validate_observations(value.get("observations"))
    if not isinstance(value.get("episode_id"), str) or HASH_RE.fullmatch(value["episode_id"]) is None:
        raise VaultError("stored Value Primitive Card is invalid")
    card_id = value.get("value_primitive_card_id")
    if not isinstance(card_id, str) or HASH_RE.fullmatch(card_id) is None:
        raise VaultError("stored Value Primitive Card is invalid")
    try:
        expected = _sha256(canonical_json({
            key: item for key, item in value.items()
            if key != "value_primitive_card_id"
        }))
    except (TypeError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("stored Value Primitive Card is invalid") from error
    if card_id != expected:
        raise VaultError("stored Value Primitive Card ID is invalid")
    provenance = value.get("provenance")
    if not isinstance(provenance, dict) or set(provenance) != PROVENANCE_FIELDS:
        raise VaultError("stored Value Primitive Card provenance is invalid")
    input_ids = provenance.get("input_evidence_ids")
    anchor_ids = provenance.get("input_anchor_ids")
    input_fields = provenance.get("input_evidence_fields")
    if (
        provenance.get("contract_version") != CARD_CONTRACT
        or not isinstance(input_ids, list)
        or not input_ids
        or any(not isinstance(item, str) or HASH_RE.fullmatch(item) is None for item in input_ids)
        or len(input_ids) != len(set(input_ids))
        or input_ids != sorted(input_ids)
        or not isinstance(anchor_ids, list)
        or not anchor_ids
        or any(not isinstance(item, str) or HASH_RE.fullmatch(item) is None for item in anchor_ids)
        or len(anchor_ids) != len(set(anchor_ids))
        or anchor_ids != sorted(anchor_ids)
        or not isinstance(input_fields, dict)
        or set(input_fields) != set(input_ids)
        or any(
            not isinstance(field, str)
            or field not in INPUT_EVIDENCE_FIELDS
            for field in input_fields.values()
        )
    ):
        raise VaultError("stored Value Primitive Card provenance is invalid")
    for field in ("packet_sha256", "evaluator_adapter_sha256"):
        item = provenance.get(field)
        if not isinstance(item, str) or HASH_RE.fullmatch(item) is None:
            raise VaultError("stored Value Primitive Card provenance is invalid")
    for field in ("evaluator_model", "evaluator_adapter", "policy_version"):
        item = provenance.get(field)
        if (
            not isinstance(item, str)
            or not item
            or len(item) > 128
            or any(character in item for character in "\r\n\0")
        ):
            raise VaultError("stored Value Primitive Card provenance is invalid")
    source_events = provenance.get("source_event_ids")
    if (
        not isinstance(source_events, list)
        or not source_events
        or any(not isinstance(item, str) or UUID_RE.fullmatch(item) is None for item in source_events)
        or len(source_events) != len(set(source_events))
    ):
        raise VaultError("stored Value Primitive Card provenance is invalid")
    try:
        parse_time(provenance.get("generated_at"))
    except (TypeError, ValueError) as error:
        raise VaultError("stored Value Primitive Card provenance is invalid") from error
    for field, maximum in (
        ("generation_cost_microusd", MAX_COST_MICROUSD),
        ("latency_ms", 300_000),
    ):
        item = provenance.get(field)
        if isinstance(item, bool) or not isinstance(item, int) or not 0 <= item <= maximum:
            raise VaultError("stored Value Primitive Card provenance is invalid")
    for axis, primitive in value["primitives"].items():
        if not isinstance(primitive, dict) or set(primitive) != {
            "state", "basis", "summary", "confidence", "evidence_references"
        }:
            raise VaultError("stored Value Primitive Card primitive is invalid")
        refs = primitive["evidence_references"]
        state = primitive["state"]
        basis = primitive["basis"]
        if (
            not isinstance(state, str)
            or state not in STATES
            or not isinstance(basis, str)
            or basis not in {"inferred", "unknown"}
            or not isinstance(primitive["confidence"], str)
            or primitive["confidence"] not in CONFIDENCE
            or not isinstance(refs, list)
            or any(not isinstance(ref, str) for ref in refs)
            or len(refs) != len(set(refs))
            or refs != sorted(refs)
            or not set(refs).issubset(input_ids)
            or any(input_fields[ref] not in AXIS_EVIDENCE_FIELDS[axis] for ref in refs)
            or (state == "unknown" and (basis != "unknown" or refs))
            or (state != "unknown" and (basis != "inferred" or not refs))
        ):
            raise VaultError("stored Value Primitive Card evidence is invalid")
        _checked_summary(primitive["summary"])
    try:
        stored_size = len(canonical_json(value)) + 1
    except (TypeError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("stored Value Primitive Card is invalid") from error
    if stored_size > MAX_CARD_BYTES:
        raise VaultError("Value Primitive Card exceeds storage size limit")
    return value


def _read_card(path: Path) -> tuple[bytes, dict[str, Any]]:
    if path.is_symlink() or CARD_FILE_RE.fullmatch(path.name) is None:
        raise VaultError("stored Value Primitive Card is unsafe")
    descriptor = -1
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
            or metadata.st_size > MAX_CARD_BYTES
        ):
            raise VaultError("stored Value Primitive Card is unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_CARD_BYTES + 1)
        after = path.lstat()
        if any((after.st_dev != metadata.st_dev, after.st_ino != metadata.st_ino, after.st_size != metadata.st_size, after.st_mtime_ns != metadata.st_mtime_ns, after.st_ctime_ns != metadata.st_ctime_ns)):
            raise VaultError("stored Value Primitive Card changed while reading")
        value = _validate_card(json.loads(raw))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("stored Value Primitive Card is invalid or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if path.stem != value["value_primitive_card_id"].removeprefix("sha256:"):
        raise VaultError("stored Value Primitive Card filename is invalid")
    return raw, value


def _stored_records(root: Path) -> list[tuple[Path, bytes, dict[str, Any]]]:
    directory = root / "value-primitive-cards"
    if not directory.exists() and not directory.is_symlink():
        return []
    if directory.is_symlink():
        raise VaultError("Value Primitive Card storage is unsafe")
    try:
        metadata = directory.lstat()
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077
        ):
            raise VaultError(
                "Value Compiler prepared storage is unsafe"
            )
        paths = []
        for path in sorted(directory.iterdir()):
            if ATOMIC_TEMP_RE.fullmatch(path.name) is None:
                paths.append(path)
                continue
            temporary = path.lstat()
            if (
                not stat.S_ISREG(temporary.st_mode)
                or temporary.st_uid != os.geteuid()
                or temporary.st_nlink != 1
                or stat.S_IMODE(temporary.st_mode) != 0o600
            ):
                raise VaultError(
                    "Value Primitive Card temporary file is unsafe"
                )
    except OSError as error:
        raise VaultError("Value Primitive Card storage is unsafe") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise VaultError("Value Primitive Card storage is unsafe")
    return [(path, *_read_card(path)) for path in paths]


def _validate_prepared(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != PREPARED_FIELDS
        or value.get("schema_version") != 1
        or value.get("contract_version") != PREPARED_CONTRACT
    ):
        raise VaultError("stored Value Compiler prepared record is invalid")
    for field in (
        "fingerprint", "episode_id", "packet_sha256",
        "evaluator_adapter_sha256",
    ):
        item = value.get(field)
        if not isinstance(item, str) or HASH_RE.fullmatch(item) is None:
            raise VaultError("stored Value Compiler prepared record is invalid")
    for field in ("evaluator_model", "policy_version"):
        item = value.get(field)
        if (
            not isinstance(item, str)
            or not item
            or len(item) > 128
            or any(character in item for character in "\r\n\0")
        ):
            raise VaultError("stored Value Compiler prepared record is invalid")
    card = _validate_card(value.get("card"))
    provenance = card["provenance"]
    if (
        card["episode_id"] != value["episode_id"]
        or provenance["packet_sha256"] != value["packet_sha256"]
        or provenance["evaluator_model"] != value["evaluator_model"]
        or provenance["evaluator_adapter_sha256"]
        != value["evaluator_adapter_sha256"]
        or provenance["policy_version"] != value["policy_version"]
        or value["fingerprint"] != _attempt_fingerprint(
            value["packet_sha256"],
            value["evaluator_model"],
            value["evaluator_adapter_sha256"],
            value["policy_version"],
        )
    ):
        raise VaultError("stored Value Compiler prepared record conflicts")
    return value


def _read_prepared(
    path: Path,
    expected_fingerprint: str | None = None,
) -> tuple[bytes, dict[str, Any]]:
    is_target = CARD_FILE_RE.fullmatch(path.name) is not None
    is_temporary = ATOMIC_TEMP_RE.fullmatch(path.name) is not None
    if (
        path.is_symlink()
        or (expected_fingerprint is None and not is_target)
        or (expected_fingerprint is not None and not is_temporary)
    ):
        raise VaultError("stored Value Compiler prepared record is unsafe")
    descriptor = -1
    try:
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
            or metadata.st_size > MAX_PREPARED_BYTES
        ):
            raise VaultError("stored Value Compiler prepared record is unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_PREPARED_BYTES + 1)
        after = path.lstat()
        if any(
            (
                after.st_dev != metadata.st_dev,
                after.st_ino != metadata.st_ino,
                after.st_size != metadata.st_size,
                after.st_mtime_ns != metadata.st_mtime_ns,
                after.st_ctime_ns != metadata.st_ctime_ns,
            )
        ):
            raise VaultError(
                "stored Value Compiler prepared record changed while reading"
            )
        value = _validate_prepared(json.loads(raw))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError(
            "stored Value Compiler prepared record is invalid or unsafe"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if expected_fingerprint is None and (
        path.stem != value["fingerprint"].removeprefix("sha256:")
    ):
        raise VaultError("stored Value Compiler prepared filename is invalid")
    if expected_fingerprint is not None and (
        value["fingerprint"] != expected_fingerprint
        or path.name[1:65] != expected_fingerprint.removeprefix("sha256:")
    ):
        raise VaultError("stored Value Compiler prepared filename is invalid")
    return raw, value


def _stored_prepared_records(
    root: Path,
) -> list[tuple[Path, bytes, dict[str, Any]]]:
    directory = root / PREPARED_DIRECTORY
    if not directory.exists() and not directory.is_symlink():
        return []
    if directory.is_symlink():
        raise VaultError("Value Compiler prepared storage is unsafe")
    try:
        metadata = directory.lstat()
        paths = []
        promoted: list[Path] = []
        for path in sorted(directory.iterdir()):
            if ATOMIC_TEMP_RE.fullmatch(path.name) is None:
                paths.append(path)
                continue
            temporary = path.lstat()
            if (
                not stat.S_ISREG(temporary.st_mode)
                or temporary.st_uid != os.geteuid()
                or temporary.st_nlink != 1
                or stat.S_IMODE(temporary.st_mode) != 0o600
            ):
                raise VaultError(
                    "Value Compiler prepared temporary file is unsafe"
                )
            fingerprint = "sha256:" + path.name[1:65]
            _raw, value = _read_prepared(path, fingerprint)
            target = directory / f"{path.name[1:65]}.json"
            if target.exists() or target.is_symlink():
                _target_raw, target_value = _read_prepared(target)
                if target_value != value:
                    raise VaultError(
                        "stored Value Compiler prepared record conflicts"
                    )
                path.unlink()
            else:
                os.replace(path, target)
                promoted.append(target)
        paths.extend(path for path in promoted if path not in paths)
    except OSError as error:
        raise VaultError("Value Compiler prepared storage is unsafe") from error
    return [(path, *_read_prepared(path)) for path in paths]


def _store_prepared(root: Path, value: dict[str, Any]) -> Path:
    record = _validate_prepared(value)
    directory = safe_subdirectory(root, "value-compiler", "prepared")
    target = directory / f"{record['fingerprint'].removeprefix('sha256:')}.json"
    data = canonical_json(record) + b"\n"
    if len(data) > MAX_PREPARED_BYTES:
        raise VaultError("Value Compiler prepared record exceeds size limit")
    if target.exists() or target.is_symlink():
        _raw, existing = _read_prepared(target)
        if existing != record:
            raise VaultError("stored Value Compiler prepared record conflicts")
        return target
    atomic_replace(target, data)
    return target


def prepared_record_snapshots(
    root: Path,
    policy_version: str,
    episode_id: str,
) -> list[tuple[Path, bytes]]:
    return [
        (path, raw)
        for path, raw, value in _stored_prepared_records(root)
        if value["episode_id"] == episode_id
        and value["policy_version"] == policy_version
    ]


def load_value_primitive_cards(
    root: Path,
    policy_version: str,
    episode_id: str,
    current_episode_card: dict[str, Any],
) -> list[dict[str, Any]]:
    result = [
        value for _path, _raw, value in _stored_records(root)
        if value["episode_id"] == episode_id
        and value["provenance"]["policy_version"] == policy_version
    ]
    if not result:
        return []
    meanings = stored_meaning_cards(root)
    receipts = [value for _path, _raw, value in _stored_receipts(root)]
    anchors = _anchors_by_episode(
        policy_version,
        [current_episode_card],
        meanings,
        receipts,
    )
    current_anchors = anchors.get(episode_id)
    if current_anchors is None:
        raise VaultError(
            "stored Value Primitive Card has no current semantic anchor"
        )
    current_packet = _packet(current_episode_card, current_anchors)
    current_evidence = {
        item["evidence_id"]: item
        for item in current_packet["evidence"]
    }
    current_fields = {
        evidence_id: item["field"]
        for evidence_id, item in current_evidence.items()
    }
    current_source_event_ids = current_episode_card.get("source_event_ids")
    for value in result:
        provenance = value["provenance"]
        if (
            value["observations"] != current_packet["observations"]
            or provenance["source_event_ids"] != current_source_event_ids
            or provenance["packet_sha256"]
            != current_packet["packet_sha256"]
            or provenance["input_anchor_ids"]
            != current_packet["anchor_ids"]
            or provenance["input_evidence_ids"]
            != sorted(current_evidence)
            or provenance["input_evidence_fields"] != current_fields
        ):
            raise VaultError(
                "stored Value Primitive Card does not match current packet"
            )
        for axis, primitive in value["primitives"].items():
            _validate_directional_grounding(
                axis,
                primitive["state"],
                primitive["evidence_references"],
                current_evidence,
            )
    result.sort(key=lambda item: (parse_time(item["provenance"]["generated_at"]), item["value_primitive_card_id"]))
    return result


def value_primitive_card_record_snapshots(root: Path, policy_version: str, episode_id: str) -> list[tuple[Path, bytes]]:
    return [
        (path, raw) for path, raw, value in _stored_records(root)
        if value["episode_id"] == episode_id and value["provenance"]["policy_version"] == policy_version
    ]


def _store_card(root: Path, card: dict[str, Any]) -> None:
    _validate_card(card)
    ensure_managed_gitignore(root)
    directory = safe_subdirectory(root, "value-primitive-cards")
    target = directory / f"{card['value_primitive_card_id'].removeprefix('sha256:')}.json"
    data = canonical_json(card) + b"\n"
    if len(data) > MAX_CARD_BYTES:
        raise VaultError("Value Primitive Card exceeds storage size limit")
    if target.exists() or target.is_symlink():
        _raw, existing = _read_card(target)
        if existing != card:
            raise VaultError("stored Value Primitive Card is conflicting")
        return
    atomic_replace(target, data)


def _same_generation(card: dict[str, Any], packet: dict[str, Any], model: str, evaluator_sha256: str, policy_version: str) -> bool:
    provenance = card["provenance"]
    return (
        card["episode_id"] == packet["episode_id"]
        and provenance["packet_sha256"] == packet["packet_sha256"]
        and provenance["evaluator_model"] == model
        and provenance["evaluator_adapter_sha256"] == evaluator_sha256
        and provenance["policy_version"] == policy_version
    )


def _generation_key(
    episode_id: str,
    packet_sha256: str,
    model: str,
    evaluator_sha256: str,
    policy_version: str,
) -> tuple[str, str, str, str, str]:
    return (
        episode_id,
        packet_sha256,
        model,
        evaluator_sha256,
        policy_version,
    )


def _card_generation_key(card: dict[str, Any]) -> tuple[str, str, str, str, str]:
    provenance = card["provenance"]
    return _generation_key(
        card["episode_id"],
        provenance["packet_sha256"],
        provenance["evaluator_model"],
        provenance["evaluator_adapter_sha256"],
        provenance["policy_version"],
    )


@contextlib.contextmanager
def run_lock(root: Path, *, blocking: bool) -> Iterator[bool]:
    """Serialize Value Compiler batches without blocking Vault readers."""
    directory = safe_subdirectory(root, "value-compiler")
    path = root / RUN_LOCK_PATH
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_CREAT
            | os.O_RDWR
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
        ):
            raise VaultError("value compiler run lock is unsafe")
        os.fchmod(descriptor, 0o600)
        deadline = time.monotonic() + MAX_BLOCKING_LOCK_WAIT_SECONDS
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not blocking:
                    yield False
                    return
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise VaultError(
                        "value compiler is busy; retry the operation"
                    )
                time.sleep(min(LOCK_POLL_SECONDS, remaining))
        yield True
    except VaultError:
        raise
    except OSError as error:
        raise VaultError(
            "value compiler run lock is unavailable or unsafe"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        directory.chmod(0o700)


def _build_anchor_index(
    root: Path,
    policy_version: str,
) -> dict[str, Any]:
    # These are the only full anchor-directory scans in one compiler batch.
    meanings = stored_meaning_cards(root)
    receipt_records = _stored_receipts(root)
    records: dict[str, dict[str, Any]] = {}
    for meaning in meanings:
        path = root / "meaning-cards" / (
            meaning["meaning_card_id"].removeprefix("sha256:") + ".json"
        )
        raw, current = _read_meaning_card_record(path)
        if current != meaning:
            raise VaultError("Meaning Card changed while indexing")
        records[meaning["meaning_card_id"]] = {
            "kind": "meaning",
            "path": path,
            "raw": raw,
            "value": current,
        }
    receipts = []
    for path, raw, receipt in receipt_records:
        receipts.append(receipt)
        records[receipt["receipt_id"]] = {
            "kind": "receipt",
            "path": path,
            "raw": raw,
            "value": receipt,
        }
    return {
        "policy_version": policy_version,
        "meanings": meanings,
        "receipts": receipts,
        "records": records,
        "selected": {},
    }


def _refresh_selected_anchor_records(
    index: dict[str, Any],
    episode_ids: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    meanings = []
    receipts = []
    for episode_id in sorted(episode_ids):
        selected = index["selected"].get(episode_id)
        if not selected:
            raise VaultError("value compiler anchor locator is missing")
        for anchor_id in selected:
            record = index["records"].get(anchor_id)
            if record is None:
                raise VaultError("value compiler anchor locator is invalid")
            if record["kind"] == "meaning":
                raw, current = _read_meaning_card_record(record["path"])
                meanings.append(current)
            elif record["kind"] == "receipt":
                raw, current = _read_stored_receipt(record["path"])
                receipts.append(current)
            else:
                raise VaultError("value compiler anchor locator is invalid")
            if raw != record["raw"] or current != record["value"]:
                raise VaultError("value compiler anchor changed during batch")
    return meanings, receipts


def _authenticated_packets(
    root: Path,
    policy_version: str,
    trusted: dict[str, Any] | None,
    episode_ids: set[str] | None = None,
    anchor_index: dict[str, Any] | None = None,
    *,
    refresh: bool = False,
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    index = anchor_index or _build_anchor_index(root, policy_version)
    if index.get("policy_version") != policy_version:
        raise VaultError("value compiler anchor locator policy conflicts")
    meanings = index["meanings"]
    receipts = index["receipts"]
    anchored_episode_ids = {
        item["episode_id"]
        for item in [*meanings, *receipts]
        if item["provenance"]["policy_version"] == policy_version
    }
    if episode_ids is not None:
        anchored_episode_ids &= episode_ids
    if refresh:
        meanings, receipts = _refresh_selected_anchor_records(
            index, anchored_episode_ids
        )
    episodes = _episodes(
        root, policy_version, trusted, anchored_episode_ids
    )
    anchors = _anchors_by_episode(
        policy_version, episodes, meanings, receipts
    )
    for episode_id, selected in anchors.items():
        index["selected"][episode_id] = sorted(
            item
            for item in (
                selected.get("meaning", {}).get("meaning_card_id"),
                selected.get("receipt", {}).get("receipt_id"),
            )
            if item is not None
        )
    return [
        (episode, _packet(episode, anchors[episode["episode_id"]]))
        for episode in episodes
        if episode["episode_id"] in anchors
    ]


def _build_card(
    episode: dict[str, Any],
    packet: dict[str, Any],
    primitives: dict[str, Any],
    model: str,
    evaluator_path: Path,
    evaluator_sha256: str,
    policy_version: str,
    cost: int,
    latency_ms: int,
) -> dict[str, Any]:
    without_id = {
        "schema_version": CARD_VERSION,
        "contract_version": CARD_CONTRACT,
        "episode_id": episode["episode_id"],
        "observations": packet["observations"],
        "primitives": primitives,
        "provenance": {
            "contract_version": CARD_CONTRACT,
            "packet_sha256": packet["packet_sha256"],
            "input_anchor_ids": packet["anchor_ids"],
            "input_evidence_ids": sorted(
                item["evidence_id"] for item in packet["evidence"]
            ),
            "input_evidence_fields": {
                item["evidence_id"]: item["field"]
                for item in packet["evidence"]
            },
            "evaluator_model": model,
            "evaluator_adapter": evaluator_path.name,
            "evaluator_adapter_sha256": evaluator_sha256,
            "policy_version": policy_version,
            "source_event_ids": episode["source_event_ids"],
            "generated_at": _evaluated_at(),
            "generation_cost_microusd": cost,
            "latency_ms": latency_ms,
        },
    }
    return {
        **without_id,
        "value_primitive_card_id": _sha256(canonical_json(without_id)),
    }


def compile_values(
    root: Path,
    evaluator: str,
    model: str,
    maximum_episodes: int,
    maximum_cost_microusd: int,
    timeout_seconds: int,
    policy_version: str | None = None,
) -> dict[str, Any]:
    if isinstance(maximum_episodes, bool) or not isinstance(maximum_episodes, int) or not 1 <= maximum_episodes <= MAX_EPISODES:
        raise VaultError("value compiler episode limit is invalid")
    if isinstance(maximum_cost_microusd, bool) or not isinstance(maximum_cost_microusd, int) or not 1 <= maximum_cost_microusd <= MAX_COST_MICROUSD:
        raise VaultError("value compiler cost budget is invalid")
    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError("value compiler evaluator timeout is invalid")
    selected_evaluator = _safe_name(evaluator, "value evaluator")
    selected_model = _safe_name(model, "value evaluator model")
    evaluator_path, evaluator_sha256 = _executable_identity(selected_evaluator)
    selected_policy, trusted = _policy_selection(policy_version, None)
    compiled = []
    reused = []
    attempt_skip_count = 0
    attempt_failure_count = 0
    batch_failures: list[str] = []
    spent = 0
    with run_lock(root, blocking=True):
        with vault_lock(root):
            ensure_managed_gitignore(root)
            anchor_index = _build_anchor_index(root, selected_policy)
            candidates = _authenticated_packets(
                root,
                selected_policy,
                trusted,
                anchor_index=anchor_index,
            )
            existing = _stored_records(root)
            card_index = {
                _card_generation_key(value): value
                for _path, _raw, value in existing
            }
            prepared_index = {
                value["fingerprint"]: (path, value)
                for path, _raw, value in _stored_prepared_records(root)
            }
            ledger = _prune_completed_attempts(root)
            attempts = {
                item["fingerprint"]: item
                for item in ledger["attempts"]
            }
            pending_candidates = []
            ready = []
            for episode, packet in candidates:
                generation_key = _generation_key(
                    episode["episode_id"],
                    packet["packet_sha256"],
                    selected_model,
                    evaluator_sha256,
                    selected_policy,
                )
                existing_card = card_index.get(generation_key)
                fingerprint = _attempt_fingerprint(
                    packet["packet_sha256"],
                    selected_model,
                    evaluator_sha256,
                    selected_policy,
                )
                prepared = prepared_index.get(fingerprint)
                if existing_card is not None:
                    reused.append(existing_card)
                    if prepared is not None:
                        _raw, current_prepared = _read_prepared(prepared[0])
                        if current_prepared != prepared[1]:
                            raise VaultError(
                                "Value Compiler prepared record changed"
                            )
                        prepared[0].unlink()
                    if fingerprint in attempts:
                        _remove_attempt(root, fingerprint)
                        attempts.pop(fingerprint)
                elif prepared is not None:
                    ready.append((episode, packet, fingerprint, *prepared))
                elif fingerprint in attempts:
                    attempt_skip_count += 1
                else:
                    pending_candidates.append(
                        (episode, packet, fingerprint)
                    )
            ready = ready[:maximum_episodes]
            pending = pending_candidates[
                :max(0, maximum_episodes - len(ready))
            ]

        # Finalize durable provider results before considering new paid work.
        for episode, packet, fingerprint, prepared_path, prepared in ready:
            with vault_lock(root):
                try:
                    current_packets = _authenticated_packets(
                        root,
                        selected_policy,
                        trusted,
                        {episode["episode_id"]},
                        anchor_index,
                        refresh=True,
                    )
                except VaultError as error:
                    _fail_attempt_if_present(
                        root,
                        fingerprint,
                        "input_changed",
                    )
                    batch_failures.append(str(error))
                    attempt_failure_count += 1
                    continue
                current = current_packets[0] if current_packets else None
                if current is None or current[1] != packet:
                    _fail_attempt_if_present(
                        root,
                        fingerprint,
                        "input_changed",
                    )
                    batch_failures.append(
                        "value compiler prepared input changed"
                    )
                    attempt_failure_count += 1
                    continue
                _raw, current_prepared = _read_prepared(prepared_path)
                if current_prepared != prepared:
                    raise VaultError(
                        "Value Compiler prepared record changed"
                    )
                card = prepared["card"]
                _store_card(root, card)
                prepared_path.unlink()
                current_attempts = {
                    item["fingerprint"]
                    for item in _load_attempts(root)["attempts"]
                }
                if fingerprint in current_attempts:
                    _remove_attempt(root, fingerprint)
                card_index[_card_generation_key(card)] = card
                compiled.append(card)

        # The batch run lock stays held, but the Vault lock is deliberately
        # released across provider work so inspect/report/sync can proceed.
        for episode, packet, fingerprint in pending:
            if spent >= maximum_cost_microusd:
                break
            remaining = maximum_cost_microusd - spent
            with vault_lock(root):
                try:
                    _refresh_selected_anchor_records(
                        anchor_index, {episode["episode_id"]}
                    )
                except VaultError as error:
                    batch_failures.append(str(error))
                    attempt_failure_count += 1
                    continue
                ledger = _load_attempts(root)
                if any(
                    item["fingerprint"] == fingerprint
                    for item in ledger["attempts"]
                ):
                    attempt_skip_count += 1
                    continue
                if len(ledger["attempts"]) >= MAX_ATTEMPTS:
                    raise VaultError(
                        "Value Compiler attempt ledger is at capacity"
                    )
                reservation = _new_attempt(
                    episode["episode_id"],
                    packet["packet_sha256"],
                    selected_model,
                    evaluator_sha256,
                    selected_policy,
                )
                if reservation["fingerprint"] != fingerprint:
                    raise VaultError(
                        "Value Compiler attempt fingerprint conflicts"
                    )
                _store_attempts(
                    root,
                    {
                        "schema_version": 1,
                        "attempts": sorted(
                            [*ledger["attempts"], reservation],
                            key=lambda item: item["fingerprint"],
                        ),
                    },
                )
            request = {
                "schema_version": 1,
                "model": selected_model,
                "packet": packet,
                "remaining_cost_microusd": remaining,
            }
            invoking_parent_pid = os.getppid()
            started = time.monotonic_ns()
            try:
                raw = _invoke(
                    evaluator_path,
                    evaluator_sha256,
                    request,
                    timeout_seconds,
                )
                latency_ms = max(
                    0, (time.monotonic_ns() - started) // 1_000_000
                )
                primitives, cost = _validate_response(
                    raw, packet, remaining
                )
            except VaultError as error:
                with vault_lock(root):
                    _replace_attempt(
                        root,
                        fingerprint,
                        "failed",
                        diagnostic_code="provider_or_validation_failed",
                    )
                batch_failures.append(str(error))
                attempt_failure_count += 1
                continue
            with vault_lock(root):
                card = _build_card(
                    episode,
                    packet,
                    primitives,
                    selected_model,
                    evaluator_path,
                    evaluator_sha256,
                    selected_policy,
                    cost,
                    latency_ms,
                )
                prepared = {
                    "schema_version": 1,
                    "contract_version": PREPARED_CONTRACT,
                    "fingerprint": fingerprint,
                    "episode_id": episode["episode_id"],
                    "packet_sha256": packet["packet_sha256"],
                    "evaluator_model": selected_model,
                    "evaluator_adapter_sha256": evaluator_sha256,
                    "policy_version": selected_policy,
                    "card": card,
                }
                prepared_path = _store_prepared(root, prepared)
                _replace_attempt(root, fingerprint, "prepared")
            # A shell function launched in the background can be terminated
            # without forwarding SIGTERM to this child. Preserve any valid,
            # paid provider result first, but never publish a Card from an
            # orphaned compiler run. The next run can finalize the prepared
            # record without invoking the provider again.
            if os.getppid() != invoking_parent_pid:
                raise VaultError(
                    "value compiler caller exited during evaluation"
                )
            with vault_lock(root):
                try:
                    current_packets = _authenticated_packets(
                        root,
                        selected_policy,
                        trusted,
                        {episode["episode_id"]},
                        anchor_index,
                        refresh=True,
                    )
                except VaultError as error:
                    _replace_attempt(
                        root,
                        fingerprint,
                        "failed",
                        diagnostic_code="input_changed",
                    )
                    batch_failures.append(str(error))
                    attempt_failure_count += 1
                    continue
                current = {
                    item[0]["episode_id"]: item
                    for item in current_packets
                }.get(episode["episode_id"])
                if current is None or current[1] != packet:
                    _replace_attempt(
                        root,
                        fingerprint,
                        "failed",
                        diagnostic_code="input_changed",
                    )
                    batch_failures.append(
                        "value compiler input changed during evaluation"
                    )
                    attempt_failure_count += 1
                    continue
                generation_key = _generation_key(
                    episode["episode_id"],
                    packet["packet_sha256"],
                    selected_model,
                    evaluator_sha256,
                    selected_policy,
                )
                existing_card = card_index.get(generation_key)
                if existing_card is not None:
                    reused.append(existing_card)
                else:
                    _store_card(root, card)
                    compiled.append(card)
                    card_index[generation_key] = card
                _raw, current_prepared = _read_prepared(prepared_path)
                if current_prepared != prepared:
                    raise VaultError(
                        "Value Compiler prepared record changed"
                    )
                prepared_path.unlink()
                _remove_attempt(root, fingerprint)
            spent += cost
    if batch_failures:
        raise VaultError(
            "value compiler batch failed for "
            f"{len(batch_failures)} candidate(s): {batch_failures[0]}"
        )
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "value compile",
        "policy_version": selected_policy,
        "candidate_count": len(candidates),
        "compiled_count": len(compiled),
        "reused_count": len(reused),
        "attempt_skip_count": attempt_skip_count,
        "attempt_failure_count": attempt_failure_count,
        "deferred_count": len(candidates) - len(compiled) - len(reused),
        "measured_cost_microusd": spent,
        "compiled_cards": compiled,
    }


def render_compile(value: dict[str, Any]) -> str:
    return (
        "Value Compiler completed: "
        f"{value['compiled_count']} compiled, {value['reused_count']} reused, "
        f"{value['deferred_count']} deferred; generation cost="
        f"{value['measured_cost_microusd']} microusd.\n"
    )
