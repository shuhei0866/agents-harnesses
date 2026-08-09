#!/usr/bin/env python3
"""Compile grounded, shared value primitives from authenticated Episodes."""

from __future__ import annotations

import hashlib
import contextlib
import fcntl
import json
import os
import re
import stat
import time
from pathlib import Path
from typing import Any
from typing import Iterator

from chunk_rotation import canonical_json, parse_time, safe_subdirectory
from evaluation import _evaluated_at, _executable_identity, _invoke, _safe_name
from meaning_lift import _stored_cards as stored_meaning_cards
from reporting import (
    _authenticated_query_locked,
    _edges_by_episode,
    _episode_card,
    _policy_selection,
)
from retention_state import load_forgotten
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
MAX_ATTEMPTS = 1_000
MAX_ATTEMPTS_BYTES = 1024 * 1024
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
    r"[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.IGNORECASE
)
CARD_FILE_RE = re.compile(r"^[0-9a-f]{64}\.json$")
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
ATTEMPT_STATES = {"pending", "failed", "completed"}
ATTEMPT_DIAGNOSTICS = {
    "provider_or_validation_failed",
    "input_changed",
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
    if (
        value.get("compiler_contract") != CARD_CONTRACT
        or value.get("state") not in ATTEMPT_STATES
    ):
        raise VaultError("Value Compiler attempt ledger is invalid")
    try:
        parse_time(value.get("updated_at"))
    except (TypeError, ValueError) as error:
        raise VaultError("Value Compiler attempt ledger is invalid") from error
    card_id = value.get("value_primitive_card_id")
    diagnostic = value.get("diagnostic_code")
    state = value["state"]
    if (
        (card_id is not None and (
            not isinstance(card_id, str) or HASH_RE.fullmatch(card_id) is None
        ))
        or (diagnostic is not None and diagnostic not in ATTEMPT_DIAGNOSTICS)
        or (state == "pending" and (card_id is not None or diagnostic is not None))
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


def _episodes(root: Path, policy_version: str, trusted: dict[str, Any] | None) -> list[dict[str, Any]]:
    forgotten = load_forgotten(root)

    def query(connection: Any, policy: dict[str, Any]) -> list[dict[str, Any]]:
        edges = _edges_by_episode(connection, policy_version)
        result = []
        for (episode_id,) in connection.execute(
            "SELECT episode_id FROM episodes WHERE policy_version = ? ORDER BY episode_id",
            (policy_version,),
        ):
            if (policy_version, episode_id) in forgotten:
                continue
            card, _supporting = _episode_card(root, connection, policy, episode_id, edges)
            result.append(card)
        return result

    return _authenticated_query_locked(root, policy_version, query, trusted)


def _anchors_by_episode(root: Path, policy_version: str, episodes: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    episode_map = {item["episode_id"]: item for item in episodes}
    anchors: dict[str, dict[str, Any]] = {}
    for meaning in stored_meaning_cards(root):
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
    for _path, _raw, receipt in _stored_receipts(root):
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
            state not in STATES
            or item["confidence"] not in CONFIDENCE
            or not isinstance(refs, list)
            or refs != sorted(set(refs))
            or any(ref not in evidence for ref in refs)
        ):
            raise VaultError("value evaluator evidence is invalid")
        allowed = AXIS_EVIDENCE_FIELDS[axis]
        if any(evidence[ref]["field"] not in allowed for ref in refs):
            raise VaultError("value evaluator evidence is not allowed for axis")
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
        or not isinstance(value.get("observations"), dict)
        or set(value["observations"]) != OBSERVATION_FIELDS
    ):
        raise VaultError("stored Value Primitive Card is invalid")
    if not isinstance(value.get("episode_id"), str) or HASH_RE.fullmatch(value["episode_id"]) is None:
        raise VaultError("stored Value Primitive Card is invalid")
    card_id = value.get("value_primitive_card_id")
    if not isinstance(card_id, str) or HASH_RE.fullmatch(card_id) is None:
        raise VaultError("stored Value Primitive Card is invalid")
    expected = _sha256(canonical_json({key: item for key, item in value.items() if key != "value_primitive_card_id"}))
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
        or input_ids != sorted(set(input_ids))
        or any(not isinstance(item, str) or HASH_RE.fullmatch(item) is None for item in input_ids)
        or not isinstance(anchor_ids, list)
        or not anchor_ids
        or anchor_ids != sorted(set(anchor_ids))
        or any(not isinstance(item, str) or HASH_RE.fullmatch(item) is None for item in anchor_ids)
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
        or source_events != list(dict.fromkeys(source_events))
        or any(not isinstance(item, str) or UUID_RE.fullmatch(item) is None for item in source_events)
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
            state not in STATES
            or basis not in {"inferred", "unknown"}
            or primitive["confidence"] not in CONFIDENCE
            or not isinstance(refs, list)
            or refs != sorted(set(refs))
            or not set(refs).issubset(input_ids)
            or any(input_fields[ref] not in AXIS_EVIDENCE_FIELDS[axis] for ref in refs)
            or (state == "unknown" and (basis != "unknown" or refs))
            or (state != "unknown" and (basis != "inferred" or not refs))
        ):
            raise VaultError("stored Value Primitive Card evidence is invalid")
        _checked_summary(primitive["summary"])
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
        paths = sorted(directory.iterdir())
    except OSError as error:
        raise VaultError("Value Primitive Card storage is unsafe") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise VaultError("Value Primitive Card storage is unsafe")
    return [(path, *_read_card(path)) for path in paths]


def load_value_primitive_cards(root: Path, policy_version: str, episode_id: str) -> list[dict[str, Any]]:
    result = [
        value for _path, _raw, value in _stored_records(root)
        if value["episode_id"] == episode_id and value["provenance"]["policy_version"] == policy_version
    ]
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


def _authenticated_packets(
    root: Path,
    policy_version: str,
    trusted: dict[str, Any] | None,
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    episodes = _episodes(root, policy_version, trusted)
    anchors = _anchors_by_episode(root, policy_version, episodes)
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
    spent = 0
    with run_lock(root, blocking=True):
        with vault_lock(root):
            ensure_managed_gitignore(root)
            candidates = _authenticated_packets(
                root, selected_policy, trusted
            )
            existing = _stored_records(root)
            attempts = {
                item["fingerprint"]: item
                for item in _load_attempts(root)["attempts"]
            }
            pending = []
            for episode, packet in candidates:
                matches = [
                    value for _path, _raw, value in existing
                    if _same_generation(
                        value,
                        packet,
                        selected_model,
                        evaluator_sha256,
                        selected_policy,
                    )
                ]
                fingerprint = _attempt_fingerprint(
                    packet["packet_sha256"],
                    selected_model,
                    evaluator_sha256,
                    selected_policy,
                )
                if matches:
                    reused.append(matches[-1])
                elif fingerprint in attempts:
                    attempt_skip_count += 1
                elif len(pending) < maximum_episodes:
                    pending.append((episode, packet, fingerprint))

        # The batch run lock stays held, but the Vault lock is deliberately
        # released across provider work so inspect/report/sync can proceed.
        for episode, packet, fingerprint in pending:
            if spent >= maximum_cost_microusd:
                break
            remaining = maximum_cost_microusd - spent
            with vault_lock(root):
                current = {
                    item[0]["episode_id"]: item
                    for item in _authenticated_packets(
                        root, selected_policy, trusted
                    )
                }.get(episode["episode_id"])
                if current is None or current[1] != packet:
                    raise VaultError(
                        "value compiler input changed before evaluation"
                    )
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
            except VaultError:
                with vault_lock(root):
                    _replace_attempt(
                        root,
                        fingerprint,
                        "failed",
                        diagnostic_code="provider_or_validation_failed",
                    )
                raise
            # A shell function launched in the background can be terminated
            # without forwarding SIGTERM to this child. Treat reparenting as
            # an interrupted run: keep the durable pending reservation and
            # never publish a card from an orphaned provider call.
            if os.getppid() != invoking_parent_pid:
                raise VaultError(
                    "value compiler caller exited during evaluation"
                )
            with vault_lock(root):
                current = {
                    item[0]["episode_id"]: item
                    for item in _authenticated_packets(
                        root, selected_policy, trusted
                    )
                }.get(episode["episode_id"])
                if current is None or current[1] != packet:
                    _replace_attempt(
                        root,
                        fingerprint,
                        "failed",
                        diagnostic_code="input_changed",
                    )
                    raise VaultError(
                        "value compiler input changed during evaluation"
                    )
                existing = _stored_records(root)
                matches = [
                    value for _path, _raw, value in existing
                    if _same_generation(
                        value,
                        packet,
                        selected_model,
                        evaluator_sha256,
                        selected_policy,
                    )
                ]
                if matches:
                    reused.append(matches[-1])
                    card_id = matches[-1]["value_primitive_card_id"]
                else:
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
                    _store_card(root, card)
                    compiled.append(card)
                    card_id = card["value_primitive_card_id"]
                _replace_attempt(
                    root,
                    fingerprint,
                    "completed",
                    card_id=card_id,
                )
            spent += cost
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "value compile",
        "policy_version": selected_policy,
        "candidate_count": len(candidates),
        "compiled_count": len(compiled),
        "reused_count": len(reused),
        "attempt_skip_count": attempt_skip_count,
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
