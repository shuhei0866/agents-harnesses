#!/usr/bin/env python3
"""Generate bounded, local-only Semantic Receipts from raw session spans."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, safe_subdirectory
from evaluation import (
    MAX_EVALUATOR_OUTPUT_BYTES,
    _episode_request,
    _evaluated_at,
    _executable_identity,
    _invoke,
    _safe_name,
)
from session_sources import load_registered_source
from vault import (
    VaultError,
    atomic_replace,
    ensure_managed_gitignore,
    vault_lock,
)


OUTPUT_VERSION = 1
RECEIPT_VERSION = 1
MAX_RUBRIC_BYTES = 64 * 1024
MAX_SPAN_BYTES = 256 * 1024
MAX_STORED_RECEIPT_BYTES = 128 * 1024
MAX_SPAN_LINES = 10_000
MAX_TEXT_LENGTH = 2_048
MAX_SHORT_TEXT_LENGTH = 256
MAX_LIST_ITEMS = 32
MAX_DURATION_MS = 365 * 24 * 60 * 60 * 1000
MAX_COUNT = 10_000_000
SAFE_TYPE_RE = re.compile(r"^[a-z][a-z0-9_-]{0,63}$")
RUBRIC_FIELDS = {
    "schema_version",
    "rubric_version",
    "criteria",
    "allowed_states",
}
RUBRIC_CRITERIA = {"goal_achievement", "quality", "efficiency"}
ALLOWED_STATES = {"supported", "unsupported", "unknown"}
CONFIDENCE_LEVELS = {"low", "medium", "high"}
DIFFICULTIES = {"trivial", "low", "medium", "high", "unknown"}
OUTCOMES = {"success", "failure", "mixed", "unknown"}
RESPONSE_FIELDS = {
    "schema_version",
    "task",
    "execution",
    "result",
    "assessment",
}
TASK_FIELDS = {
    "type",
    "intent",
    "deliverable",
    "constraints",
    "difficulty",
}
EXECUTION_FIELDS = {
    "harness",
    "model",
    "duration_ms",
    "tool_count",
    "retry_count",
}
RESULT_FIELDS = {"summary", "artifacts", "outcome"}
ASSESSMENT_FIELDS = {"criteria", "confidence"}
CRITERION_FIELDS = {"state", "evidence_references"}


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _bounded_text(
    value: object, description: str, *, maximum: int = MAX_TEXT_LENGTH
) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > maximum
        or any(
            ord(character) < 0x20 and character not in "\t\n"
            for character in value
        )
    ):
        raise VaultError(f"semantic evaluator {description} is invalid")
    return value


def _bounded_string_list(
    value: object,
    description: str,
    *,
    safe_tokens: bool = False,
) -> list[str]:
    if (
        not isinstance(value, list)
        or len(value) > MAX_LIST_ITEMS
        or any(not isinstance(item, str) for item in value)
    ):
        raise VaultError(f"semantic evaluator {description} is invalid")
    checked: list[str] = []
    for item in value:
        if safe_tokens:
            if SAFE_TYPE_RE.fullmatch(item) is None:
                raise VaultError(f"semantic evaluator {description} is invalid")
        else:
            _bounded_text(
                item, description, maximum=MAX_SHORT_TEXT_LENGTH
            )
        checked.append(item)
    if checked != list(dict.fromkeys(checked)):
        raise VaultError(f"semantic evaluator {description} is invalid")
    return checked


def _bounded_integer(value: object, description: str, maximum: int) -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > maximum
    ):
        raise VaultError(f"semantic evaluator {description} is invalid")
    return value


def _load_rubric(path: Path) -> tuple[dict[str, Any], str]:
    selected = path.expanduser()
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        if selected.is_symlink():
            raise VaultError("semantic receipt rubric is unavailable or unsafe")
        descriptor = os.open(selected, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o022
            or metadata.st_size > MAX_RUBRIC_BYTES
        ):
            raise VaultError("semantic receipt rubric is unavailable or unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_RUBRIC_BYTES + 1)
        after = selected.lstat()
        if (
            after.st_dev != metadata.st_dev
            or after.st_ino != metadata.st_ino
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
        ):
            raise VaultError("semantic receipt rubric changed while reading")
        value = json.loads(raw)
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError(
            "semantic receipt rubric is unavailable or invalid"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    criteria = value.get("criteria") if isinstance(value, dict) else None
    states = value.get("allowed_states") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or set(value) != RUBRIC_FIELDS
        or value.get("schema_version") != 1
        or not isinstance(criteria, dict)
        or set(criteria) != RUBRIC_CRITERIA
        or any(
            not isinstance(description, str)
            or not description
            or len(description) > MAX_TEXT_LENGTH
            for description in criteria.values()
        )
        or not isinstance(states, list)
        or len(states) != len(ALLOWED_STATES)
        or set(states) != ALLOWED_STATES
    ):
        raise VaultError("semantic receipt rubric is invalid or unsupported")
    _safe_name(value.get("rubric_version"), "semantic rubric version")
    return value, _sha256(canonical_json(value))


def _read_registered_span(
    record: dict[str, Any], start_line: int, end_line: int
) -> tuple[str, str]:
    if (
        isinstance(start_line, bool)
        or isinstance(end_line, bool)
        or not isinstance(start_line, int)
        or not isinstance(end_line, int)
        or start_line < 1
        or end_line < start_line
        or end_line - start_line + 1 > MAX_SPAN_LINES
    ):
        raise VaultError("semantic source span is invalid")
    path = Path(record["path"])
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_dev != record["device"]
            or metadata.st_ino != record["inode"]
            or metadata.st_size != record["size_bytes"]
            or metadata.st_mtime_ns != record["modified_ns"]
            or metadata.st_ctime_ns != record["changed_ns"]
        ):
            raise VaultError("registered session source changed")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            digest = hashlib.sha256()
            selected = bytearray()
            line_number = 1
            current_line_has_bytes = False
            size_bytes = 0
            while True:
                chunk = stream.read(64 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                size_bytes += len(chunk)
                offset = 0
                while offset < len(chunk):
                    newline = chunk.find(b"\n", offset)
                    boundary = len(chunk) if newline < 0 else newline + 1
                    fragment = chunk[offset:boundary]
                    if start_line <= line_number <= end_line:
                        if len(selected) + len(fragment) > MAX_SPAN_BYTES:
                            raise VaultError(
                                "semantic source span exceeds the size limit"
                            )
                        selected.extend(fragment)
                    current_line_has_bytes = True
                    if newline >= 0:
                        line_number += 1
                        current_line_has_bytes = False
                    offset = boundary
        after = path.lstat()
    except VaultError:
        raise
    except OSError as error:
        raise VaultError(
            "registered session source is unavailable or unsafe"
        ) from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        after.st_dev != metadata.st_dev
        or after.st_ino != metadata.st_ino
        or after.st_size != metadata.st_size
        or after.st_mtime_ns != metadata.st_mtime_ns
        or after.st_ctime_ns != metadata.st_ctime_ns
        or size_bytes != metadata.st_size
        or "sha256:" + digest.hexdigest() != record["content_sha256"]
    ):
        raise VaultError("registered session source changed")
    line_count = line_number - 1 + int(current_line_has_bytes)
    if end_line > line_count:
        raise VaultError("semantic source span is outside the registered source")
    if not selected or len(selected) > MAX_SPAN_BYTES:
        raise VaultError("semantic source span exceeds the size limit")
    try:
        content = bytes(selected).decode("utf-8")
    except UnicodeDecodeError as error:
        raise VaultError("semantic source span must be UTF-8 text") from error
    return content, _sha256(bytes(selected))


def _validate_response(
    raw: bytes,
    available_evidence_ids: set[str],
    rubric: dict[str, Any],
    selected_content: str,
    source_path: str,
) -> tuple[dict[str, Any], list[str]]:
    if len(raw) > MAX_EVALUATOR_OUTPUT_BYTES:
        raise VaultError("semantic evaluator response exceeds the size limit")
    try:
        value = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("semantic evaluator returned invalid JSON") from error
    if (
        not isinstance(value, dict)
        or set(value) != RESPONSE_FIELDS
        or value.get("schema_version") != 1
    ):
        raise VaultError("semantic evaluator response violates the protocol")

    task = value.get("task")
    execution = value.get("execution")
    result = value.get("result")
    assessment = value.get("assessment")
    if not isinstance(task, dict) or set(task) != TASK_FIELDS:
        raise VaultError("semantic evaluator task is invalid")
    if SAFE_TYPE_RE.fullmatch(task.get("type", "")) is None:
        raise VaultError("semantic evaluator task type is invalid")
    _bounded_text(task.get("intent"), "task intent")
    _bounded_text(task.get("deliverable"), "task deliverable")
    _bounded_string_list(task.get("constraints"), "task constraints")
    if task.get("difficulty") not in DIFFICULTIES:
        raise VaultError("semantic evaluator task difficulty is invalid")

    if not isinstance(execution, dict) or set(execution) != EXECUTION_FIELDS:
        raise VaultError("semantic evaluator execution is invalid")
    if execution.get("harness") not in {"claude-code", "codex"}:
        raise VaultError("semantic evaluator execution harness is invalid")
    _safe_name(execution.get("model"), "semantic execution model")
    _bounded_integer(
        execution.get("duration_ms"), "execution duration", MAX_DURATION_MS
    )
    _bounded_integer(
        execution.get("tool_count"), "execution tool count", MAX_COUNT
    )
    _bounded_integer(
        execution.get("retry_count"), "execution retry count", MAX_COUNT
    )

    if not isinstance(result, dict) or set(result) != RESULT_FIELDS:
        raise VaultError("semantic evaluator result is invalid")
    _bounded_text(result.get("summary"), "result summary")
    _bounded_string_list(
        result.get("artifacts"), "result artifacts", safe_tokens=True
    )
    if result.get("outcome") not in OUTCOMES:
        raise VaultError("semantic evaluator result outcome is invalid")

    criteria = assessment.get("criteria") if isinstance(assessment, dict) else None
    if (
        not isinstance(assessment, dict)
        or set(assessment) != ASSESSMENT_FIELDS
        or assessment.get("confidence") not in CONFIDENCE_LEVELS
        or not isinstance(criteria, dict)
        or set(criteria) != set(rubric["criteria"])
    ):
        raise VaultError("semantic evaluator assessment is invalid")
    referenced: set[str] = set()
    for criterion in criteria.values():
        if not isinstance(criterion, dict) or set(criterion) != CRITERION_FIELDS:
            raise VaultError("semantic evaluator assessment is invalid")
        if criterion.get("state") not in rubric["allowed_states"]:
            raise VaultError("semantic evaluator assessment is invalid")
        references = criterion.get("evidence_references")
        if (
            not isinstance(references, list)
            or references != sorted(set(references))
            or any(
                not isinstance(item, str)
                or item not in available_evidence_ids
                for item in references
            )
        ):
            raise VaultError("semantic evaluator evidence references are invalid")
        referenced.update(references)

    serialized = json.dumps(value, sort_keys=True)
    if source_path in serialized:
        raise VaultError("semantic evaluator response exposed a source path")
    for line in selected_content.splitlines():
        candidate = line.strip()
        if len(candidate) >= 32 and candidate in serialized:
            raise VaultError("semantic evaluator response copied raw source content")
    return value, sorted(referenced)


def _store_receipt(root: Path, receipt: dict[str, Any]) -> None:
    ensure_managed_gitignore(root)
    directory = safe_subdirectory(root, "semantic-receipts")
    target = directory / f"{receipt['receipt_id'].removeprefix('sha256:')}.json"
    data = canonical_json(receipt) + b"\n"
    if target.exists() or target.is_symlink():
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
                or metadata.st_size > MAX_STORED_RECEIPT_BYTES
            ):
                raise VaultError("stored Semantic Receipt is unsafe")
            with os.fdopen(descriptor, "rb", closefd=True) as stream:
                descriptor = -1
                existing = stream.read(MAX_STORED_RECEIPT_BYTES + 1)
            after = target.lstat()
        except OSError as error:
            raise VaultError("stored Semantic Receipt is unsafe") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if (
            after.st_dev != metadata.st_dev
            or after.st_ino != metadata.st_ino
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
            or existing != data
        ):
            raise VaultError("stored Semantic Receipt is unsafe or conflicting")
        return
    atomic_replace(target, data)


def generate(
    root: Path,
    episode_id: str,
    source_ref: str,
    start_line: int,
    end_line: int,
    evaluator: str,
    model: str,
    rubric_path: Path,
    timeout_seconds: int,
    policy_version: str | None = None,
    policy_path: Path | None = None,
) -> dict[str, Any]:
    from reporting import inspect_episode

    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError("semantic evaluator timeout must be between 1 and 300 seconds")
    before = inspect_episode(root, episode_id, policy_version, policy_path)
    source = load_registered_source(root, source_ref)
    selected_content, span_sha256 = _read_registered_span(
        source, start_line, end_line
    )
    selected_evaluator = _safe_name(evaluator, "semantic evaluator")
    selected_model = _safe_name(model, "semantic evaluator model")
    evaluator_path, evaluator_sha256 = _executable_identity(selected_evaluator)
    rubric, rubric_sha256 = _load_rubric(rubric_path)
    card = before["card"]
    episode = _episode_request(card)
    request = {
        "schema_version": 1,
        "model": selected_model,
        "rubric": rubric,
        "episode": episode,
        "source": {
            "adapter": source["adapter"],
            "start_line": start_line,
            "end_line": end_line,
            "content_sha256": source["content_sha256"],
            "span_sha256": span_sha256,
            "content": selected_content,
        },
    }
    response, evidence_ids = _validate_response(
        _invoke(
            evaluator_path,
            evaluator_sha256,
            request,
            timeout_seconds,
        ),
        {
            item["evidence_id"]
            for item in card["deterministic_evidence"]
        },
        rubric,
        selected_content,
        source["path"],
    )
    receipt: dict[str, Any] = {
        "schema_version": RECEIPT_VERSION,
        "receipt_id": "",
        "episode_id": episode_id,
        "task": response["task"],
        "execution": response["execution"],
        "result": response["result"],
        "assessment": response["assessment"],
        "provenance": {
            "evaluator_model": selected_model,
            "evaluator_adapter": evaluator_path.name,
            "evaluator_adapter_sha256": evaluator_sha256,
            "rubric_version": rubric["rubric_version"],
            "rubric_sha256": rubric_sha256,
            "policy_version": before["policy_version"],
            "source_event_ids": card["source_event_ids"],
            "evidence_ids": evidence_ids,
            "source_spans": [
                {
                    "source_ref": source_ref,
                    "adapter": source["adapter"],
                    "content_sha256": source["content_sha256"],
                    "span_sha256": span_sha256,
                    "start_line": start_line,
                    "end_line": end_line,
                }
            ],
            "generated_at": _evaluated_at(),
        },
    }
    receipt["receipt_id"] = _sha256(
        canonical_json(
            {
                key: value
                for key, value in receipt.items()
                if key != "receipt_id"
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
            or after["card"]["source_event_ids"] != card["source_event_ids"]
            or [
                item["evidence_id"]
                for item in after["card"]["deterministic_evidence"]
            ]
            != [
                item["evidence_id"]
                for item in card["deterministic_evidence"]
            ]
        ):
            raise VaultError("episode evidence changed during receipt generation")
        current_source = load_registered_source(root, source_ref)
        _content, current_span_sha256 = _read_registered_span(
            current_source, start_line, end_line
        )
        if current_span_sha256 != span_sha256:
            raise VaultError(
                "registered session source changed during receipt generation"
            )
        _store_receipt(root, receipt)
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "receipt generate",
        "receipt": receipt,
    }


def render_generate(value: dict[str, Any]) -> str:
    receipt = value["receipt"]
    return "\n".join(
        (
            "Semantic Receipt generated",
            f"Receipt ID: {receipt['receipt_id']}",
            f"Episode: {receipt['episode_id']}",
            f"Outcome: {receipt['result']['outcome']}",
            f"Confidence: {receipt['assessment']['confidence']}",
        )
    )
