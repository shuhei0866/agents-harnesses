#!/usr/bin/env python3
"""Generate a compact, local-only Meaning Card from a minimized session span."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import time
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, parse_time, safe_subdirectory
from evaluation import (
    BUNDLED_EVALUATORS,
    MAX_EVALUATOR_OUTPUT_BYTES,
    _evaluated_at,
    _executable_identity,
    _invoke,
    _safe_name,
)
from semantic_receipts import _read_registered_span
from session_sources import load_registered_source
from vault import (
    VaultError,
    atomic_replace,
    ensure_managed_gitignore,
    vault_lock,
)


OUTPUT_VERSION = 1
CARD_VERSION = 1
PACKET_CONTRACT = "meaning-packet-v1"
CARD_CONTRACT = "meaning-card-v1"
MAX_PACKET_BYTES = 16 * 1024
MAX_EVIDENCE_ITEMS = 8
MAX_EVIDENCE_TEXT = 2_048
MAX_SUMMARY_TEXT = 512
MAX_CARD_BYTES = 32 * 1024
MAX_COST_MICROUSD = 100_000
MEANING_FIELDS = (
    "intent",
    "deliverable",
    "verification",
    "outcome",
    "reusable_learning",
)
QUESTION_FIELDS = (
    "intent",
    "deliverable",
    "verification_and_outcome",
    "reusable_learning",
    "time_and_api_cost",
)
RESPONSE_FIELDS = {
    "schema_version",
    *MEANING_FIELDS,
    "confidence",
    "measured_cost_microusd",
}
FIELD_FIELDS = {"summary", "evidence_references"}
OUTCOME_FIELDS = {*FIELD_FIELDS, "state"}
CONFIDENCE_LEVELS = {"low", "medium", "high"}
OUTCOME_STATES = {"success", "failure", "mixed", "unknown"}
CARD_FIELDS = {
    "schema_version",
    "meaning_card_id",
    "episode_id",
    *MEANING_FIELDS,
    "confidence",
    "provenance",
}
PROVENANCE_FIELDS = {
    "contract_version",
    "packet_sha256",
    "packet_evidence_ids",
    "evaluator_model",
    "evaluator_adapter",
    "evaluator_adapter_sha256",
    "evaluator_runtime_sha256",
    "policy_version",
    "source_event_ids",
    "source_span",
    "generated_at",
    "measured_cost_microusd",
    "latency_ms",
}
SOURCE_SPAN_FIELDS = {
    "source_ref",
    "adapter",
    "content_sha256",
    "span_sha256",
    "start_line",
    "end_line",
}
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
CARD_FILE_RE = re.compile(r"^[0-9a-f]{64}\.json$")
CODE_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
EMAIL_RE = re.compile(
    r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@"
    r"[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9._%+-])"
)
ABSOLUTE_PATH_RE = re.compile(
    r"(?<![A-Za-z0-9_.-])/(?:Users|home|private|tmp|var|etc|opt)/"
    r"[^\s\"'`<>]+"
)
SECRET_PATTERNS = (
    re.compile(r"(?i)\bAuthorization\s*:\s*Bearer\s+\S+"),
    re.compile(r"\b(?:sk-ant|sk-proj|sk-test)-[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{12,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
)


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _sanitize(value: str) -> str:
    text = CODE_FENCE_RE.sub("[code omitted]", value)
    for pattern in SECRET_PATTERNS:
        text = pattern.sub("[secret redacted]", text)
    text = ABSOLUTE_PATH_RE.sub("[path redacted]", text)
    text = EMAIL_RE.sub("[email redacted]", text)
    text = "".join(
        character
        for character in text
        if ord(character) >= 0x20 or character in "\t\n"
    )
    text = re.sub(r"\s+", " ", text).strip()
    return text[:MAX_EVIDENCE_TEXT]


def _block_text(content: object, allowed_types: set[str]) -> list[str]:
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    result: list[str] = []
    for block in content:
        if not isinstance(block, dict):
            continue
        block_type = block.get("type")
        text = block.get("text")
        if block_type in allowed_types and isinstance(text, str):
            result.append(text)
    return result


def _message_parts(value: object) -> tuple[str | None, list[str]]:
    if not isinstance(value, dict):
        return None, []
    payload = value.get("payload")
    candidate = payload if isinstance(payload, dict) else value
    role = candidate.get("role")
    if role is None and value.get("type") in {"user", "assistant"}:
        role = value.get("type")
        message = value.get("message")
        if isinstance(message, dict):
            candidate = message
    if role == "user":
        allowed = {"input_text", "text"}
    elif role == "assistant":
        allowed = {"output_text", "text"}
    else:
        return None, []
    if candidate.get("type") not in {None, "message"}:
        return None, []
    return role, _block_text(candidate.get("content"), allowed)


def _build_packet(adapter: str, selected_content: str) -> dict[str, Any]:
    user_parts: list[str] = []
    assistant_messages: list[list[str]] = []
    try:
        for line in selected_content.splitlines():
            if not line.strip():
                continue
            value = json.loads(line)
            role, parts = _message_parts(value)
            if role == "user" and parts and not user_parts:
                user_parts = parts
            elif role == "assistant" and parts:
                assistant_messages.append(parts)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("meaning source span is invalid") from error
    candidates = (
        ("user_intent", " ".join(user_parts)),
        (
            "final_assistant",
            " ".join(assistant_messages[-1]) if assistant_messages else "",
        ),
    )
    evidence: list[dict[str, str]] = []
    for kind, raw in candidates:
        content = _sanitize(raw)
        if not content:
            continue
        item_without_id = {"kind": kind, "content": content}
        evidence.append(
            {
                "evidence_id": _sha256(canonical_json(item_without_id)),
                **item_without_id,
            }
        )
    if not evidence or len(evidence) > MAX_EVIDENCE_ITEMS:
        raise VaultError("meaning source span has no usable evidence")
    packet_without_id: dict[str, Any] = {
        "schema_version": 1,
        "contract_version": PACKET_CONTRACT,
        "adapter": adapter,
        "evidence": evidence,
    }
    packet = {
        **packet_without_id,
        "packet_sha256": _sha256(canonical_json(packet_without_id)),
    }
    if len(canonical_json(packet)) > MAX_PACKET_BYTES:
        raise VaultError("meaning evidence packet exceeds the size limit")
    return packet


def _validate_completed_span(adapter: str, selected_content: str) -> None:
    try:
        rows = [
            json.loads(line)
            for line in selected_content.splitlines()
            if line.strip()
        ]
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("meaning source span is invalid") from error
    messages = [_message_parts(row) for row in rows]
    human_count = sum(role == "user" and bool(parts) for role, parts in messages)
    assistant_count = sum(
        role == "assistant" and bool(parts) for role, parts in messages
    )
    if human_count != 1 or assistant_count < 1:
        raise VaultError(
            "meaning source span is not one exact completed task"
        )
    if adapter != "codex":
        return
    markers: list[tuple[str, object]] = []
    for row in rows:
        payload = row.get("payload") if isinstance(row, dict) else None
        if (
            isinstance(payload, dict)
            and payload.get("type") in {"task_started", "task_complete"}
        ):
            markers.append((payload["type"], payload.get("turn_id")))
    if (
        len(markers) != 2
        or [item[0] for item in markers]
        != ["task_started", "task_complete"]
        or not isinstance(markers[0][1], str)
        or markers[0][1] != markers[1][1]
    ):
        raise VaultError(
            "meaning source span is not one exact completed task"
        )


def _checked_summary(value: object, description: str) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > MAX_SUMMARY_TEXT
        or any(ord(character) < 0x20 for character in value)
    ):
        raise VaultError(f"meaning evaluator {description} is invalid")
    for pattern in SECRET_PATTERNS:
        if pattern.search(value):
            raise VaultError("meaning evaluator returned private content")
    if ABSOLUTE_PATH_RE.search(value) or EMAIL_RE.search(value):
        raise VaultError("meaning evaluator returned private content")
    return value


def _checked_field(
    value: object,
    description: str,
    evidence_ids: set[str],
    *,
    outcome: bool = False,
) -> dict[str, Any]:
    expected = OUTCOME_FIELDS if outcome else FIELD_FIELDS
    if not isinstance(value, dict) or set(value) != expected:
        raise VaultError(f"meaning evaluator {description} is invalid")
    references = value.get("evidence_references")
    if (
        not isinstance(references, list)
        or any(not isinstance(item, str) for item in references)
        or references != sorted(set(references))
        or not set(references).issubset(evidence_ids)
        or not references
    ):
        raise VaultError(
            f"meaning evaluator {description} evidence is invalid"
        )
    result: dict[str, Any] = {
        "summary": _checked_summary(value.get("summary"), description),
        "evidence_references": references,
    }
    if outcome:
        state = value.get("state")
        if state not in OUTCOME_STATES:
            raise VaultError("meaning evaluator outcome state is invalid")
        result = {"state": state, **result}
    return result


def _validate_response(
    raw: bytes, packet: dict[str, Any], maximum_cost: int
) -> tuple[dict[str, Any], int]:
    if len(raw) > MAX_EVALUATOR_OUTPUT_BYTES:
        raise VaultError("meaning evaluator output exceeded the size limit")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("meaning evaluator returned invalid JSON") from error
    if (
        not isinstance(value, dict)
        or set(value) != RESPONSE_FIELDS
        or value.get("schema_version") != 2
        or value.get("confidence") not in CONFIDENCE_LEVELS
    ):
        raise VaultError("meaning evaluator response is invalid")
    cost = value.get("measured_cost_microusd")
    if (
        isinstance(cost, bool)
        or not isinstance(cost, int)
        or cost < 0
        or cost > maximum_cost
    ):
        raise VaultError("meaning evaluator response violates the cost budget")
    evidence_ids = {
        item["evidence_id"] for item in packet["evidence"]
    }
    response = {
        name: _checked_field(
            value[name],
            name.replace("_", " "),
            evidence_ids,
            outcome=name == "outcome",
        )
        for name in MEANING_FIELDS
    }
    response["confidence"] = value["confidence"]
    response_texts = [
        response[name]["summary"] for name in MEANING_FIELDS
    ]
    for item in packet["evidence"]:
        fragment = item["content"].strip()
        if len(fragment) >= 8 and any(
            fragment.casefold() in text.casefold()
            for text in response_texts
        ):
            raise VaultError(
                "meaning evaluator copied raw packet content"
            )
    return response, cost


def _validate_card_record(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != CARD_FIELDS
        or value.get("schema_version") != CARD_VERSION
        or not isinstance(value.get("meaning_card_id"), str)
        or HASH_RE.fullmatch(value["meaning_card_id"]) is None
        or not isinstance(value.get("episode_id"), str)
        or HASH_RE.fullmatch(value["episode_id"]) is None
        or value.get("confidence") not in CONFIDENCE_LEVELS
    ):
        raise VaultError("stored Meaning Card is invalid")
    provenance = value.get("provenance")
    if not isinstance(provenance, dict) or set(provenance) != PROVENANCE_FIELDS:
        raise VaultError("stored Meaning Card provenance is invalid")
    evidence_ids = provenance.get("packet_evidence_ids")
    if (
        provenance.get("contract_version") != CARD_CONTRACT
        or not isinstance(evidence_ids, list)
        or not evidence_ids
        or evidence_ids != sorted(set(evidence_ids))
        or any(
            not isinstance(item, str) or HASH_RE.fullmatch(item) is None
            for item in evidence_ids
        )
    ):
        raise VaultError("stored Meaning Card provenance is invalid")
    for field in (
        "packet_sha256",
        "evaluator_adapter_sha256",
        "evaluator_runtime_sha256",
    ):
        if (
            not isinstance(provenance.get(field), str)
            or HASH_RE.fullmatch(provenance[field]) is None
        ):
            raise VaultError("stored Meaning Card provenance is invalid")
    for field in ("evaluator_model", "evaluator_adapter", "policy_version"):
        item = provenance.get(field)
        if (
            not isinstance(item, str)
            or not item
            or len(item) > 128
            or any(character in item for character in "\r\n\0")
        ):
            raise VaultError("stored Meaning Card provenance is invalid")
    source_events = provenance.get("source_event_ids")
    source_span = provenance.get("source_span")
    if (
        not isinstance(source_events, list)
        or not source_events
        or source_events != list(dict.fromkeys(source_events))
        or any(not isinstance(item, str) or not item for item in source_events)
        or not isinstance(source_span, dict)
        or set(source_span) != SOURCE_SPAN_FIELDS
        or source_span.get("adapter") not in {"claude-code", "codex"}
    ):
        raise VaultError("stored Meaning Card provenance is invalid")
    for field in ("content_sha256", "span_sha256"):
        if (
            not isinstance(source_span.get(field), str)
            or HASH_RE.fullmatch(source_span[field]) is None
        ):
            raise VaultError("stored Meaning Card provenance is invalid")
    if (
        not isinstance(source_span.get("source_ref"), str)
        or not source_span["source_ref"]
        or isinstance(source_span.get("start_line"), bool)
        or not isinstance(source_span.get("start_line"), int)
        or isinstance(source_span.get("end_line"), bool)
        or not isinstance(source_span.get("end_line"), int)
        or source_span["start_line"] < 1
        or source_span["end_line"] < source_span["start_line"]
    ):
        raise VaultError("stored Meaning Card provenance is invalid")
    try:
        parse_time(provenance.get("generated_at"))
    except (TypeError, ValueError) as error:
        raise VaultError("stored Meaning Card provenance is invalid") from error
    for field, maximum in (
        ("measured_cost_microusd", MAX_COST_MICROUSD),
        ("latency_ms", 300_000),
    ):
        item = provenance.get(field)
        if (
            isinstance(item, bool)
            or not isinstance(item, int)
            or not 0 <= item <= maximum
        ):
            raise VaultError("stored Meaning Card provenance is invalid")
    allowed = set(evidence_ids)
    for name in MEANING_FIELDS:
        _checked_field(
            value.get(name),
            name.replace("_", " "),
            allowed,
            outcome=name == "outcome",
        )
    expected_id = _sha256(
        canonical_json(
            {
                key: nested
                for key, nested in value.items()
                if key != "meaning_card_id"
            }
        )
    )
    if value["meaning_card_id"] != expected_id:
        raise VaultError("stored Meaning Card ID is invalid")
    return value


def _safe_card_directory(root: Path) -> Path:
    return safe_subdirectory(root, "meaning-cards")


def _read_card(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not CARD_FILE_RE.fullmatch(path.name):
        raise VaultError("stored Meaning Card is unsafe")
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o022
            or metadata.st_size > MAX_CARD_BYTES
        ):
            raise VaultError("stored Meaning Card is unsafe")
        raw = path.read_bytes()
        value = json.loads(raw)
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("stored Meaning Card is invalid") from error
    value = _validate_card_record(value)
    if path.name != f"{value['meaning_card_id'].removeprefix('sha256:')}.json":
        raise VaultError("stored Meaning Card ID is invalid")
    return value


def _stored_cards(root: Path) -> list[dict[str, Any]]:
    directory = root / "meaning-cards"
    if not directory.exists():
        return []
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise VaultError("Meaning Card storage is unsafe") from error
    if (
        directory.is_symlink()
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise VaultError("Meaning Card storage is unsafe")
    return [_read_card(path) for path in sorted(directory.iterdir())]


def meaning_card_record_snapshots(
    root: Path,
    policy_version: str,
    episode_id: str,
) -> list[tuple[Path, bytes]]:
    directory = root / "meaning-cards"
    if not directory.exists():
        return []
    cards: list[tuple[Path, bytes]] = []
    for path in sorted(directory.iterdir()):
        value = _read_card(path)
        if (
            value["episode_id"] == episode_id
            and value["provenance"]["policy_version"] == policy_version
        ):
            cards.append((path, path.read_bytes()))
    return cards


def _same_generation(
    card: dict[str, Any],
    episode_id: str,
    packet_sha256: str,
    model: str,
    evaluator_runtime_sha256: str,
    policy_version: str,
    source_span: dict[str, Any],
) -> bool:
    provenance = card.get("provenance")
    return (
        card.get("episode_id") == episode_id
        and isinstance(provenance, dict)
        and provenance.get("contract_version") == CARD_CONTRACT
        and provenance.get("packet_sha256") == packet_sha256
        and provenance.get("evaluator_model") == model
        and provenance.get("evaluator_runtime_sha256")
        == evaluator_runtime_sha256
        and provenance.get("policy_version") == policy_version
        and provenance.get("source_span") == source_span
    )


def _store_card(root: Path, card: dict[str, Any]) -> None:
    _validate_card_record(card)
    ensure_managed_gitignore(root)
    directory = _safe_card_directory(root)
    target = directory / (
        card["meaning_card_id"].removeprefix("sha256:") + ".json"
    )
    data = canonical_json(card) + b"\n"
    if len(data) > MAX_CARD_BYTES:
        raise VaultError("Meaning Card exceeds the storage size limit")
    if target.exists() or target.is_symlink():
        if _read_card(target) != card:
            raise VaultError("stored Meaning Card is conflicting")
        return
    atomic_replace(target, data)


def _answer(state: str, evidence_ids: list[str]) -> dict[str, Any]:
    return {
        "state": state,
        "evidence_references": sorted(set(evidence_ids)),
    }


def _answer_score(state: str) -> float:
    return {"covered": 1.0, "partial": 0.5, "uncovered": 0.0}[state]


def _baseline(card: dict[str, Any]) -> dict[str, Any]:
    evidence = [
        item
        for item in card.get("deterministic_evidence", [])
        if isinstance(item, dict)
        and isinstance(item.get("evidence_id"), str)
    ]
    answers = {
        name: _answer("uncovered", []) for name in QUESTION_FIELDS
    }
    if card.get("task_type"):
        answers["intent"] = _answer("covered", [])
    deliverable = [
        item["evidence_id"]
        for item in evidence
        if item.get("evidence_type") in {"git_commit", "pull_request"}
        and item.get("state") == "success"
    ]
    if deliverable:
        answers["deliverable"] = _answer("covered", deliverable)
    verification = [
        item["evidence_id"]
        for item in evidence
        if item.get("evidence_type") in {"test", "build", "lint"}
        and item.get("state") in {"success", "failure"}
    ]
    outcomes = card.get("deterministic_outcomes")
    known_outcome = (
        isinstance(outcomes, dict)
        and outcomes.get("success", 0) + outcomes.get("failure", 0) > 0
    )
    if verification and known_outcome:
        answers["verification_and_outcome"] = _answer(
            "covered", verification
        )
    elif verification or known_outcome:
        answers["verification_and_outcome"] = _answer(
            "partial", verification
        )
    duration = card.get("measured_duration_ms")
    cost = card.get("measured_cost_usd")
    measured = sum(
        isinstance(item, dict)
        and item.get("state") in {"complete", "partial"}
        for item in (duration, cost)
    )
    if measured == 2:
        answers["time_and_api_cost"] = _answer("covered", [])
    elif measured == 1:
        answers["time_and_api_cost"] = _answer("partial", [])
    return {
        "answers": answers,
        "score": sum(
            _answer_score(item["state"]) for item in answers.values()
        ),
    }


def _comparison(
    baseline: dict[str, Any], meaning_card: dict[str, Any]
) -> dict[str, Any]:
    questions: dict[str, dict[str, str]] = {}
    meaning_states = {
        "intent": "covered",
        "deliverable": (
            "covered"
            if meaning_card["outcome"]["state"] == "success"
            else "partial"
            if meaning_card["outcome"]["state"] in {"unknown", "mixed"}
            else "uncovered"
        ),
        "verification_and_outcome": (
            "covered"
            if meaning_card["outcome"]["state"] in {"success", "failure"}
            else "partial"
        ),
        "reusable_learning": "covered",
        "time_and_api_cost": "covered",
    }
    for name in QUESTION_FIELDS:
        meaning_state = meaning_states[name]
        questions[name] = {
            "baseline": baseline["answers"][name]["state"],
            "meaning": meaning_state,
        }
    baseline_score = baseline["score"]
    meaning_score = sum(
        _answer_score(item) for item in meaning_states.values()
    )
    return {
        "questions": questions,
        "baseline_score": baseline_score,
        "meaning_score": meaning_score,
        "score_lift": meaning_score - baseline_score,
    }


def _result(card: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "meaning generate",
        "baseline": baseline,
        "meaning_card": card,
        "comparison": _comparison(baseline, card),
    }


def generate(
    root: Path,
    episode_id: str,
    source_ref: str,
    start_line: int,
    end_line: int,
    evaluator: str,
    model: str,
    maximum_cost_microusd: int,
    timeout_seconds: int,
    policy_version: str | None = None,
    policy_path: Path | None = None,
) -> dict[str, Any]:
    from reporting import inspect_episode

    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError(
            "meaning evaluator timeout must be between 1 and 300 seconds"
        )
    if (
        isinstance(maximum_cost_microusd, bool)
        or not isinstance(maximum_cost_microusd, int)
        or maximum_cost_microusd <= 0
        or maximum_cost_microusd > MAX_COST_MICROUSD
    ):
        raise VaultError("meaning evaluator cost budget is invalid")
    before = inspect_episode(root, episode_id, policy_version, policy_path)
    source = load_registered_source(root, source_ref)
    selected_content, span_sha256 = _read_registered_span(
        source, start_line, end_line
    )
    _validate_completed_span(source["adapter"], selected_content)
    packet = _build_packet(source["adapter"], selected_content)
    selected_evaluator = _safe_name(evaluator, "meaning evaluator")
    selected_model = _safe_name(model, "meaning evaluator model")
    evaluator_path, evaluator_sha256 = _executable_identity(
        selected_evaluator
    )
    evaluator_runtime_sha256 = evaluator_sha256
    if evaluator_path.name == "flight-recorder-claude-meaning-evaluator":
        shared_path = evaluator_path.parent / (
            "flight-recorder-claude-semantic-evaluator"
        )
        if not shared_path.is_file() or shared_path.is_symlink():
            raise VaultError("meaning evaluator runtime is unsafe")
        evaluator_runtime_sha256 = _sha256(
            canonical_json(
                {
                    "meaning_adapter_sha256": evaluator_sha256,
                    "shared_adapter_sha256": _sha256(
                        shared_path.read_bytes()
                    ),
                }
            )
        )
    if (
        evaluator_path.name in BUNDLED_EVALUATORS
        and timeout_seconds < 240
    ):
        raise VaultError(
            "bundled meaning evaluator timeout must be at least 240 seconds"
        )
    source_span = {
        "source_ref": source_ref,
        "adapter": source["adapter"],
        "content_sha256": source["content_sha256"],
        "span_sha256": span_sha256,
        "start_line": start_line,
        "end_line": end_line,
    }
    baseline = _baseline(before["card"])
    # Validate or migrate the managed ignore boundary before a paid call.
    ensure_managed_gitignore(root)
    for existing in _stored_cards(root):
        if _same_generation(
            existing,
            episode_id,
            packet["packet_sha256"],
            selected_model,
            evaluator_runtime_sha256,
            before["policy_version"],
            source_span,
        ):
            return _result(existing, baseline)
    request = {
        "schema_version": 2,
        "model": selected_model,
        "packet": packet,
        "remaining_cost_microusd": maximum_cost_microusd,
    }
    started = time.monotonic_ns()
    raw_response = _invoke(
        evaluator_path, evaluator_sha256, request, timeout_seconds
    )
    latency_ms = max(0, (time.monotonic_ns() - started) // 1_000_000)
    response, measured_cost = _validate_response(
        raw_response, packet, maximum_cost_microusd
    )
    meaning_card: dict[str, Any] = {
        "schema_version": CARD_VERSION,
        "meaning_card_id": "",
        "episode_id": episode_id,
        **response,
        "provenance": {
            "contract_version": CARD_CONTRACT,
            "packet_sha256": packet["packet_sha256"],
            "packet_evidence_ids": sorted(
                item["evidence_id"] for item in packet["evidence"]
            ),
            "evaluator_model": selected_model,
            "evaluator_adapter": evaluator_path.name,
            "evaluator_adapter_sha256": evaluator_sha256,
            "evaluator_runtime_sha256": evaluator_runtime_sha256,
            "policy_version": before["policy_version"],
            "source_event_ids": before["card"]["source_event_ids"],
            "source_span": source_span,
            "generated_at": _evaluated_at(),
            "measured_cost_microusd": measured_cost,
            "latency_ms": latency_ms,
        },
    }
    meaning_card["meaning_card_id"] = _sha256(
        canonical_json(
            {
                key: value
                for key, value in meaning_card.items()
                if key != "meaning_card_id"
            }
        )
    )
    with vault_lock(root):
        after = inspect_episode(
            root,
            episode_id,
            policy_version,
            policy_path,
            locked=True,
        )
        if (
            after["policy_version"] != before["policy_version"]
            or after["card"]["source_event_ids"]
            != before["card"]["source_event_ids"]
        ):
            raise VaultError(
                "episode evidence changed during meaning generation"
            )
        current_source = load_registered_source(root, source_ref)
        _content, current_span_sha256 = _read_registered_span(
            current_source, start_line, end_line
        )
        if current_span_sha256 != span_sha256:
            raise VaultError(
                "registered session source changed during meaning generation"
            )
        for existing in _stored_cards(root):
            if _same_generation(
                existing,
                episode_id,
                packet["packet_sha256"],
                selected_model,
                evaluator_runtime_sha256,
                before["policy_version"],
                source_span,
            ):
                return _result(existing, baseline)
        _store_card(root, meaning_card)
    return _result(meaning_card, baseline)


def render_generate(value: dict[str, Any]) -> str:
    card = value["meaning_card"]
    comparison = value["comparison"]
    provenance = card["provenance"]
    return "\n".join(
        (
            "Meaning Card generated",
            f"Card ID: {card['meaning_card_id']}",
            f"Episode: {card['episode_id']}",
            (
                "Coverage: "
                f"{comparison['baseline_score']}/5 -> "
                f"{comparison['meaning_score']}/5 "
                f"(+{comparison['score_lift']})"
            ),
            f"Outcome: {card['outcome']['state']}",
            f"Cost: {provenance['measured_cost_microusd']} micro-USD",
            f"Latency: {provenance['latency_ms']} ms",
        )
    )
