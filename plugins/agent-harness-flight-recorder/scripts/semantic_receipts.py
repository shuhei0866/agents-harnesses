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

from chunk_rotation import canonical_json, parse_time, safe_subdirectory
from evaluation import (
    MAX_EVALUATOR_OUTPUT_BYTES,
    _episode_request,
    _evaluated_at,
    _executable_identity,
    _invoke,
    _safe_name,
)
from session_sources import (
    SOURCE_REF_RE,
    SUPPORTED_ADAPTERS,
    load_registered_source,
)
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
MAX_RECEIPT_SOURCE_EVENTS = 10_000
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
TEMP_RECEIPT_RE = re.compile(
    r"^\.[0-9a-f]{64}\.json\.[A-Za-z0-9_-]+$"
)
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
RECEIPT_FIELDS = {
    "schema_version",
    "receipt_id",
    "episode_id",
    "task",
    "execution",
    "result",
    "assessment",
    "provenance",
}
PROVENANCE_FIELDS = {
    "evaluator_model",
    "evaluator_adapter",
    "evaluator_adapter_sha256",
    "rubric_version",
    "rubric_sha256",
    "policy_version",
    "source_event_ids",
    "evidence_ids",
    "source_spans",
    "generated_at",
}
SOURCE_SPAN_FIELDS = {
    "source_ref",
    "adapter",
    "content_sha256",
    "span_sha256",
    "start_line",
    "end_line",
}


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
    expected_harness: str | None = None,
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
    if (
        execution.get("harness") not in {"claude-code", "codex"}
        or (
            expected_harness is not None
            and execution.get("harness") != expected_harness
        )
    ):
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

    def strings(item: object) -> list[str]:
        if isinstance(item, str):
            return [item]
        if isinstance(item, dict):
            return [
                text
                for nested in item.values()
                for text in strings(nested)
            ]
        if isinstance(item, list):
            return [
                text
                for nested in item
                for text in strings(nested)
            ]
        return []

    response_strings = strings(value)
    if any(source_path in text for text in response_strings):
        raise VaultError("semantic evaluator response exposed a source path")
    source_fragments: set[str] = set()
    for line in selected_content.splitlines():
        candidate = line.strip()
        if len(candidate) >= 32:
            source_fragments.add(candidate)
        try:
            decoded = json.loads(line)
        except (ValueError, UnicodeError, RecursionError):
            continue
        source_fragments.update(
            text for text in strings(decoded) if len(text.strip()) >= 32
        )
    if any(
        fragment in response_text
        for fragment in source_fragments
        for response_text in response_strings
    ):
        raise VaultError("semantic evaluator response copied raw source content")
    return value, sorted(referenced)


def _bounded_unique_identifiers(
    value: object,
    description: str,
    *,
    maximum: int,
    sorted_values: bool = False,
    digest: bool = False,
    allow_empty: bool = False,
) -> list[str]:
    if (
        not isinstance(value, list)
        or (not value and not allow_empty)
        or len(value) > maximum
        or any(
            not isinstance(item, str)
            or not item
            or len(item) > MAX_SHORT_TEXT_LENGTH
            or (digest and HASH_RE.fullmatch(item) is None)
            for item in value
        )
        or len(set(value)) != len(value)
        or (sorted_values and value != sorted(value))
    ):
        raise VaultError(f"stored Semantic Receipt {description} is invalid")
    return value


def _validate_receipt_record(value: object) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != RECEIPT_FIELDS
        or value.get("schema_version") != RECEIPT_VERSION
        or not isinstance(value.get("receipt_id"), str)
        or HASH_RE.fullmatch(value["receipt_id"]) is None
        or not isinstance(value.get("episode_id"), str)
        or HASH_RE.fullmatch(value["episode_id"]) is None
    ):
        raise VaultError("stored Semantic Receipt is invalid")
    provenance = value.get("provenance")
    if not isinstance(provenance, dict) or set(provenance) != PROVENANCE_FIELDS:
        raise VaultError("stored Semantic Receipt provenance is invalid")
    _safe_name(
        provenance.get("evaluator_model"),
        "stored Semantic Receipt evaluator model",
    )
    _safe_name(
        provenance.get("evaluator_adapter"),
        "stored Semantic Receipt evaluator adapter",
    )
    _safe_name(
        provenance.get("rubric_version"),
        "stored Semantic Receipt rubric version",
    )
    _safe_name(
        provenance.get("policy_version"),
        "stored Semantic Receipt policy version",
    )
    for field in ("evaluator_adapter_sha256", "rubric_sha256"):
        item = provenance.get(field)
        if not isinstance(item, str) or HASH_RE.fullmatch(item) is None:
            raise VaultError("stored Semantic Receipt provenance is invalid")
    generated_at = provenance.get("generated_at")
    try:
        if not isinstance(generated_at, str):
            raise ValueError
        parse_time(generated_at)
    except (TypeError, ValueError) as error:
        raise VaultError(
            "stored Semantic Receipt generation time is invalid"
        ) from error
    source_event_ids = _bounded_unique_identifiers(
        provenance.get("source_event_ids"),
        "source event IDs",
        maximum=MAX_RECEIPT_SOURCE_EVENTS,
    )
    evidence_ids = _bounded_unique_identifiers(
        provenance.get("evidence_ids"),
        "evidence IDs",
        maximum=MAX_RECEIPT_SOURCE_EVENTS,
        sorted_values=True,
        digest=True,
        allow_empty=True,
    )
    spans = provenance.get("source_spans")
    if (
        not isinstance(spans, list)
        or not spans
        or len(spans) > MAX_LIST_ITEMS
    ):
        raise VaultError("stored Semantic Receipt source spans are invalid")
    for span in spans:
        if (
            not isinstance(span, dict)
            or set(span) != SOURCE_SPAN_FIELDS
            or not isinstance(span.get("source_ref"), str)
            or SOURCE_REF_RE.fullmatch(span["source_ref"]) is None
            or span.get("adapter") not in SUPPORTED_ADAPTERS
            or not isinstance(span.get("content_sha256"), str)
            or HASH_RE.fullmatch(span["content_sha256"]) is None
            or not isinstance(span.get("span_sha256"), str)
            or HASH_RE.fullmatch(span["span_sha256"]) is None
        ):
            raise VaultError("stored Semantic Receipt source spans are invalid")
        start = span.get("start_line")
        end = span.get("end_line")
        if (
            isinstance(start, bool)
            or isinstance(end, bool)
            or not isinstance(start, int)
            or not isinstance(end, int)
            or start < 1
            or end < start
            or end - start + 1 > MAX_SPAN_LINES
        ):
            raise VaultError("stored Semantic Receipt source spans are invalid")
    response = {
        "schema_version": 1,
        "task": value["task"],
        "execution": value["execution"],
        "result": value["result"],
        "assessment": value["assessment"],
    }
    _response, referenced = _validate_response(
        canonical_json(response),
        set(evidence_ids),
        {
            "criteria": {name: name for name in RUBRIC_CRITERIA},
            "allowed_states": sorted(ALLOWED_STATES),
        },
        "",
        "\0",
        spans[0]["adapter"] if len(spans) == 1 else None,
    )
    if referenced != evidence_ids:
        raise VaultError("stored Semantic Receipt evidence IDs are invalid")
    expected_id = _sha256(
        canonical_json(
            {
                key: item
                for key, item in value.items()
                if key != "receipt_id"
            }
        )
    )
    if value["receipt_id"] != expected_id:
        raise VaultError("stored Semantic Receipt ID is invalid")
    return value


def _read_stored_receipt(path: Path) -> tuple[bytes, dict[str, Any]]:
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
            or metadata.st_mode & 0o022
            or metadata.st_size > MAX_STORED_RECEIPT_BYTES
        ):
            raise VaultError("stored Semantic Receipt is unsafe")
        with os.fdopen(descriptor, "rb", closefd=True) as stream:
            descriptor = -1
            raw = stream.read(MAX_STORED_RECEIPT_BYTES + 1)
        after = path.lstat()
        if (
            after.st_dev != metadata.st_dev
            or after.st_ino != metadata.st_ino
            or after.st_size != metadata.st_size
            or after.st_mtime_ns != metadata.st_mtime_ns
            or after.st_ctime_ns != metadata.st_ctime_ns
        ):
            raise VaultError("stored Semantic Receipt changed while reading")
        value = _validate_receipt_record(json.loads(raw))
    except VaultError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        raise VaultError("stored Semantic Receipt is invalid or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if path.suffix != ".json" or path.stem != value["receipt_id"][7:]:
        raise VaultError("stored Semantic Receipt filename is invalid")
    return raw, value


def _stored_receipts(root: Path) -> list[tuple[Path, bytes, dict[str, Any]]]:
    directory = root / "semantic-receipts"
    if not directory.exists() and not directory.is_symlink():
        return []
    if directory.is_symlink():
        raise VaultError("Semantic Receipt storage is unsafe")
    try:
        metadata = directory.lstat()
        paths = sorted(
            path
            for path in directory.iterdir()
            if TEMP_RECEIPT_RE.fullmatch(path.name) is None
        )
    except OSError as error:
        raise VaultError("Semantic Receipt storage is unsafe") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o022
    ):
        raise VaultError("Semantic Receipt storage is unsafe")
    return [(path, *_read_stored_receipt(path)) for path in paths]


def load_semantic_receipts(
    root: Path,
    policy_version: str,
    episode_id: str,
    source_event_ids: list[str],
    available_evidence_ids: set[str],
) -> list[dict[str, Any]]:
    result = [
        value
        for _path, _raw, value in _stored_receipts(root)
        if value["episode_id"] == episode_id
        and value["provenance"]["policy_version"] == policy_version
        and value["provenance"]["source_event_ids"] == source_event_ids
        and set(value["provenance"]["evidence_ids"]).issubset(
            available_evidence_ids
        )
    ]
    result.sort(
        key=lambda item: (
            parse_time(item["provenance"]["generated_at"]),
            item["receipt_id"],
        )
    )
    return result


def semantic_receipt_record_snapshots(
    root: Path,
    policy_version: str,
    episode_id: str,
) -> list[tuple[Path, bytes]]:
    return [
        (path, raw)
        for path, raw, value in _stored_receipts(root)
        if value["episode_id"] == episode_id
        and value["provenance"]["policy_version"] == policy_version
    ]


def _store_receipt(root: Path, receipt: dict[str, Any]) -> None:
    _validate_receipt_record(receipt)
    ensure_managed_gitignore(root)
    directory = safe_subdirectory(root, "semantic-receipts")
    target = directory / f"{receipt['receipt_id'].removeprefix('sha256:')}.json"
    data = canonical_json(receipt) + b"\n"
    if len(data) > MAX_STORED_RECEIPT_BYTES:
        raise VaultError("Semantic Receipt exceeds the storage size limit")
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


def _prepare_receipt(
    root: Path,
    before: dict[str, Any],
    episode_id: str,
    source_ref: str,
    start_line: int,
    end_line: int,
    evaluator: str,
    model: str,
    rubric_path: Path,
    timeout_seconds: int,
    remaining_cost_microusd: int | None = None,
) -> dict[str, Any]:
    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError("semantic evaluator timeout must be between 1 and 300 seconds")
    card = before.get("card") if isinstance(before, dict) else None
    if (
        not isinstance(card, dict)
        or card.get("episode_id") != episode_id
        or not isinstance(before.get("policy_version"), str)
    ):
        raise VaultError("episode snapshot is invalid")
    source = load_registered_source(root, source_ref)
    selected_content, span_sha256 = _read_registered_span(
        source, start_line, end_line
    )
    selected_evaluator = _safe_name(evaluator, "semantic evaluator")
    selected_model = _safe_name(model, "semantic evaluator model")
    evaluator_path, evaluator_sha256 = _executable_identity(selected_evaluator)
    rubric, rubric_sha256 = _load_rubric(rubric_path)
    episode = _episode_request(card)
    request = {
        "schema_version": 2 if remaining_cost_microusd is not None else 1,
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
    if remaining_cost_microusd is not None:
        if (
            isinstance(remaining_cost_microusd, bool)
            or not isinstance(remaining_cost_microusd, int)
            or remaining_cost_microusd < 0
        ):
            raise VaultError("semantic evaluator cost budget is invalid")
        request["remaining_cost_microusd"] = remaining_cost_microusd
    raw_response = _invoke(
            evaluator_path,
            evaluator_sha256,
            request,
            timeout_seconds,
        )
    measured_cost_microusd = 0
    if remaining_cost_microusd is not None:
        try:
            automatic_response = json.loads(raw_response)
        except (ValueError, UnicodeError, RecursionError) as error:
            raise VaultError("semantic evaluator returned invalid JSON") from error
        measured_cost_microusd = automatic_response.get(
            "measured_cost_microusd"
        ) if isinstance(automatic_response, dict) else None
        if (
            not isinstance(automatic_response, dict)
            or automatic_response.get("schema_version") != 2
            or isinstance(measured_cost_microusd, bool)
            or not isinstance(measured_cost_microusd, int)
            or measured_cost_microusd < 0
            or measured_cost_microusd > remaining_cost_microusd
        ):
            raise VaultError("semantic evaluator response violates the cost budget")
        automatic_response = dict(automatic_response)
        automatic_response["schema_version"] = 1
        automatic_response.pop("measured_cost_microusd", None)
        raw_response = canonical_json(automatic_response)
    response, evidence_ids = _validate_response(
        raw_response,
        {
            item["evidence_id"]
            for item in card["deterministic_evidence"]
        },
        rubric,
        selected_content,
        source["path"],
        source["adapter"],
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
    result = {
        "schema_version": OUTPUT_VERSION,
        "command": "receipt generate",
        "receipt": receipt,
        **(
            {"measured_cost_microusd": measured_cost_microusd}
            if remaining_cost_microusd is not None
            else {}
        ),
    }
    prepared = {
        "result": result,
        "snapshot": {
            "policy_version": before["policy_version"],
            "source_event_ids": list(card["source_event_ids"]),
            "evidence_ids": [
                item["evidence_id"]
                for item in card["deterministic_evidence"]
            ],
        },
        "source": {
            "source_ref": source_ref,
            "start_line": start_line,
            "end_line": end_line,
            "span_sha256": span_sha256,
        },
    }
    return _validate_prepared_record(prepared)


def _validate_prepared_receipt(
    root: Path,
    prepared: dict[str, Any],
    after: dict[str, Any],
) -> None:
    snapshot = prepared["snapshot"]
    card = after["card"]
    if (
        after["policy_version"] != snapshot["policy_version"]
        or card["source_event_ids"] != snapshot["source_event_ids"]
        or [
            item["evidence_id"]
            for item in card["deterministic_evidence"]
        ]
        != snapshot["evidence_ids"]
    ):
        raise VaultError("episode evidence changed during receipt generation")
    source_snapshot = prepared["source"]
    current_source = load_registered_source(
        root, source_snapshot["source_ref"]
    )
    _content, current_span_sha256 = _read_registered_span(
        current_source,
        source_snapshot["start_line"],
        source_snapshot["end_line"],
    )
    if current_span_sha256 != source_snapshot["span_sha256"]:
        raise VaultError(
            "registered session source changed during receipt generation"
        )


def _validate_prepared_record(value: object) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "result",
        "snapshot",
        "source",
    }:
        raise VaultError("prepared Semantic Receipt is invalid")
    result = value.get("result")
    snapshot = value.get("snapshot")
    source = value.get("source")
    result_fields = (
        set(result) if isinstance(result, dict) else set()
    )
    base_result_fields = {"schema_version", "command", "receipt"}
    measured_cost = (
        result.get("measured_cost_microusd")
        if isinstance(result, dict)
        else None
    )
    if (
        not isinstance(result, dict)
        or frozenset(result_fields)
        not in {frozenset(base_result_fields), frozenset(base_result_fields | {"measured_cost_microusd"})}
        or result.get("schema_version") != OUTPUT_VERSION
        or result.get("command") != "receipt generate"
        or (
            "measured_cost_microusd" in result_fields
            and (
                isinstance(measured_cost, bool)
                or not isinstance(measured_cost, int)
                or not 0 <= measured_cost <= 1_000_000_000_000
            )
        )
        or not isinstance(snapshot, dict)
        or set(snapshot)
        != {"policy_version", "source_event_ids", "evidence_ids"}
        or not isinstance(source, dict)
        or set(source)
        != {"source_ref", "start_line", "end_line", "span_sha256"}
    ):
        raise VaultError("prepared Semantic Receipt is invalid")
    receipt = _validate_receipt_record(result.get("receipt"))
    if len(canonical_json(receipt) + b"\n") > MAX_STORED_RECEIPT_BYTES:
        raise VaultError("prepared Semantic Receipt is invalid")
    try:
        source_event_ids = _bounded_unique_identifiers(
            snapshot.get("source_event_ids"),
            "prepared source event IDs",
            maximum=MAX_RECEIPT_SOURCE_EVENTS,
        )
        evidence_ids = _bounded_unique_identifiers(
            snapshot.get("evidence_ids"),
            "prepared evidence IDs",
            maximum=MAX_RECEIPT_SOURCE_EVENTS,
            digest=True,
            allow_empty=True,
        )
    except VaultError as error:
        raise VaultError("prepared Semantic Receipt is invalid") from error
    if (
        not isinstance(snapshot.get("policy_version"), str)
        or SOURCE_REF_RE.fullmatch(str(source.get("source_ref"))) is None
        or isinstance(source.get("start_line"), bool)
        or not isinstance(source.get("start_line"), int)
        or isinstance(source.get("end_line"), bool)
        or not isinstance(source.get("end_line"), int)
        or source["start_line"] < 1
        or source["end_line"] < source["start_line"]
        or source["end_line"] - source["start_line"] + 1 > MAX_SPAN_LINES
        or HASH_RE.fullmatch(str(source.get("span_sha256"))) is None
    ):
        raise VaultError("prepared Semantic Receipt is invalid")
    provenance = receipt["provenance"]
    spans = provenance["source_spans"]
    if (
        provenance["policy_version"] != snapshot["policy_version"]
        or provenance["source_event_ids"] != source_event_ids
        or not set(provenance["evidence_ids"]).issubset(evidence_ids)
        or len(spans) != 1
        or spans[0]["source_ref"] != source["source_ref"]
        or spans[0]["start_line"] != source["start_line"]
        or spans[0]["end_line"] != source["end_line"]
        or spans[0]["span_sha256"] != source["span_sha256"]
    ):
        raise VaultError("prepared Semantic Receipt is invalid")
    return value


def _store_prepared_receipt(root: Path, prepared: dict[str, Any]) -> None:
    checked = _validate_prepared_record(prepared)
    _store_receipt(root, checked["result"]["receipt"])


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
    remaining_cost_microusd: int | None = None,
) -> dict[str, Any]:
    from reporting import inspect_episode

    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError("semantic evaluator timeout must be between 1 and 300 seconds")
    before = inspect_episode(root, episode_id, policy_version, policy_path)
    prepared = _prepare_receipt(
        root,
        before,
        episode_id,
        source_ref,
        start_line,
        end_line,
        evaluator,
        model,
        rubric_path,
        timeout_seconds,
        remaining_cost_microusd,
    )
    with vault_lock(root):
        after = inspect_episode(
            root,
            episode_id,
            policy_version,
            policy_path,
            locked=True,
        )
        _validate_prepared_receipt(root, prepared, after)
        _store_prepared_receipt(root, prepared)
    return prepared["result"]


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
