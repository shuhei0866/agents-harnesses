#!/usr/bin/env python3
"""Run explicit, privacy-bounded model evaluation for one work episode."""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import os
import re
import resource
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, parse_time, safe_subdirectory
from vault import (
    VaultError,
    atomic_replace,
    authorized_key,
    ensure_managed_gitignore,
    vault_lock,
)


OUTPUT_VERSION = 1
RECORD_VERSION = 1
PROTOCOL_VERSION = 1
DEFAULT_RUBRIC = (
    Path(__file__).resolve().parent.parent / "rubrics/on-demand-v1.json"
)
MAX_ARTIFACT_BYTES = 256 * 1024
MAX_TOTAL_ARTIFACT_BYTES = 1024 * 1024
MAX_EVALUATOR_OUTPUT_BYTES = 64 * 1024
HASH_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._:/@+-]{1,128}$")
RUBRIC_FIELDS = {
    "schema_version",
    "rubric_version",
    "criteria",
    "conclusions",
    "confidence_levels",
    "criterion_states",
}
RESPONSE_FIELDS = {
    "schema_version",
    "conclusion",
    "confidence",
    "evidence_ids",
    "criteria",
}
RECORD_FIELDS = {
    "schema_version",
    "evaluation_id",
    "judgment_type",
    "policy_version",
    "episode_id",
    "rubric_version",
    "rubric_sha256",
    "evaluator",
    "evaluator_sha256",
    "evaluator_protocol_version",
    "model",
    "evaluated_at",
    "input_fingerprint",
    "source_evidence_ids",
    "evidence_ids",
    "artifact_hashes",
    "conclusion",
    "confidence",
    "criteria",
}
CONCLUSIONS = {"successful", "mixed", "unsuccessful", "inconclusive"}
CONFIDENCE_LEVELS = {"low", "medium", "high"}
CRITERION_STATES = {"supported", "unsupported", "unknown"}
CRITERIA = {"goal_achievement", "quality", "efficiency"}


def _sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _safe_name(value: object, description: str) -> str:
    if not isinstance(value, str) or SAFE_NAME_RE.fullmatch(value) is None:
        raise VaultError(f"{description} is invalid")
    return value


def _load_rubric(path: Path | None) -> tuple[dict[str, Any], str]:
    selected = (path or DEFAULT_RUBRIC).expanduser()
    try:
        raw = selected.read_bytes()
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError, UnicodeError) as error:
        raise VaultError("evaluation rubric is unavailable or invalid") from error
    if (
        not isinstance(value, dict)
        or set(value) != RUBRIC_FIELDS
        or value.get("schema_version") != 1
    ):
        raise VaultError("evaluation rubric is invalid")
    for field in (
        "criteria",
        "conclusions",
        "confidence_levels",
        "criterion_states",
    ):
        items = value.get(field)
        if (
            not isinstance(items, list)
            or not items
            or len(items) != len(set(items))
            or any(
                not isinstance(item, str)
                or SAFE_NAME_RE.fullmatch(item) is None
                for item in items
            )
        ):
            raise VaultError("evaluation rubric is invalid")
    _safe_name(value.get("rubric_version"), "rubric version")
    if (
        set(value["criteria"]) != CRITERIA
        or set(value["conclusions"]) != CONCLUSIONS
        or set(value["confidence_levels"]) != CONFIDENCE_LEVELS
        or set(value["criterion_states"]) != CRITERION_STATES
    ):
        raise VaultError("evaluation rubric is unsupported")
    return value, _sha256(canonical_json(value))


def _artifact_scope(paths: list[Path]) -> list[dict[str, Any]]:
    scope: list[dict[str, Any]] = []
    total = 0
    for argument in paths:
        expanded = argument.expanduser().absolute()
        if expanded.is_symlink():
            raise VaultError("evaluation artifact is unsafe")
        try:
            path = expanded.resolve(strict=True)
        except OSError as error:
            raise VaultError("evaluation artifact is unavailable") from error
        try:
            metadata = path.lstat()
        except OSError as error:
            raise VaultError("evaluation artifact is unavailable") from error
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or path.is_symlink()
        ):
            raise VaultError("evaluation artifact is unsafe")
        if metadata.st_size > MAX_ARTIFACT_BYTES:
            raise VaultError("evaluation artifact exceeds the size limit")
        total += metadata.st_size
        if total > MAX_TOTAL_ARTIFACT_BYTES:
            raise VaultError("evaluation artifact scope exceeds the size limit")
        scope.append(
            {
                "path": str(path),
                "size_bytes": metadata.st_size,
                "device": metadata.st_dev,
                "inode": metadata.st_ino,
                "modified_ns": metadata.st_mtime_ns,
                "changed_ns": metadata.st_ctime_ns,
            }
        )
    return scope


def _read_artifacts(
    scope: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    request_items: list[dict[str, Any]] = []
    hashes: list[dict[str, Any]] = []
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    for item in scope:
        path = Path(item["path"])
        descriptor = -1
        try:
            descriptor = os.open(path, flags)
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1
                or metadata.st_size != item["size_bytes"]
                or metadata.st_dev != item["device"]
                or metadata.st_ino != item["inode"]
                or metadata.st_mtime_ns != item["modified_ns"]
                or metadata.st_ctime_ns != item["changed_ns"]
            ):
                raise VaultError("evaluation artifact changed during preview")
            with os.fdopen(descriptor, "rb", closefd=True) as stream:
                descriptor = -1
                raw = stream.read(MAX_ARTIFACT_BYTES + 1)
        except OSError as error:
            raise VaultError(
                "evaluation artifact is unavailable or unsafe"
            ) from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
        if len(raw) > MAX_ARTIFACT_BYTES:
            raise VaultError("evaluation artifact exceeds the size limit")
        try:
            content = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise VaultError("evaluation artifacts must be UTF-8 text") from error
        digest = _sha256(raw)
        request_items.append(
            {
                "sha256": digest,
                "size_bytes": len(raw),
                "content": content,
            }
        )
        hashes.append({"sha256": digest, "size_bytes": len(raw)})
    return request_items, hashes


def _artifact_preview_token(root: Path, scope: list[dict[str, Any]]) -> str:
    key = authorized_key(root, None)
    payload = canonical_json(
        {
            "schema_version": 1,
            "artifacts": scope,
        }
    )
    return "hmac-sha256:" + hmac.new(
        key, payload, hashlib.sha256
    ).hexdigest()


def _episode_request(card: dict[str, Any]) -> dict[str, Any]:
    outcomes = card["deterministic_outcomes"]
    return {
        "episode_id": card["episode_id"],
        "time": card["time"],
        "event_count": card["event_count"],
        "harnesses": card["harnesses"],
        "model_coverage": card["model_coverage"],
        "elapsed_ms": card["elapsed_ms"],
        "measured_duration_ms": card["measured_duration_ms"],
        "measured_cost_usd": card["measured_cost_usd"],
        "retry_count": card["retry_count"],
        "deterministic_outcomes": {
            "success": outcomes["success"],
            "failure": outcomes["failure"],
            "unknown": outcomes["unknown"],
            "not_recorded": outcomes["not_recorded"],
        },
        "deterministic_evidence": [
            {
                "evidence_id": fact["evidence_id"],
                "evidence_type": fact["evidence_type"],
                "state": fact["state"],
                "value": fact["value"],
            }
            for fact in card["deterministic_evidence"]
        ],
    }


def _validate_response(
    raw: bytes,
    rubric: dict[str, Any],
    available_evidence_ids: set[str],
) -> dict[str, Any]:
    if len(raw) > MAX_EVALUATOR_OUTPUT_BYTES:
        raise VaultError("evaluator response exceeds the size limit")
    try:
        response = json.loads(raw)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise VaultError("evaluator returned invalid JSON") from error
    criteria = response.get("criteria") if isinstance(response, dict) else None
    evidence_ids = (
        response.get("evidence_ids") if isinstance(response, dict) else None
    )
    if (
        not isinstance(response, dict)
        or set(response) != RESPONSE_FIELDS
        or response.get("schema_version") != PROTOCOL_VERSION
        or response.get("conclusion") not in rubric["conclusions"]
        or response.get("confidence") not in rubric["confidence_levels"]
        or not isinstance(evidence_ids, list)
        or evidence_ids != sorted(set(evidence_ids))
        or any(
            not isinstance(item, str) or item not in available_evidence_ids
            for item in evidence_ids
        )
        or not isinstance(criteria, dict)
        or set(criteria) != set(rubric["criteria"])
        or any(
            value not in rubric["criterion_states"]
            for value in criteria.values()
        )
    ):
        raise VaultError("evaluator response violates the protocol")
    return response


def _executable_identity(executable: str) -> tuple[Path, str]:
    located = shutil.which(executable)
    if located is None:
        raise VaultError("evaluator executable was not found")
    try:
        resolved = Path(located).resolve(strict=True)
        metadata = resolved.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_mode & 0o022
            or metadata.st_size > 16 * 1024 * 1024
        ):
            raise VaultError("evaluator executable is unsafe")
        digest = _sha256(resolved.read_bytes())
    except OSError as error:
        raise VaultError("evaluator executable is unsafe") from error
    return resolved, digest


def _limit_evaluator_process() -> None:
    resource.setrlimit(
        resource.RLIMIT_FSIZE,
        (MAX_EVALUATOR_OUTPUT_BYTES + 1, MAX_EVALUATOR_OUTPUT_BYTES + 1),
    )
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _invoke(
    executable: Path,
    executable_sha256: str,
    request: dict[str, Any],
    timeout_seconds: int,
) -> bytes:
    try:
        environment = {"PATH": os.environ.get("PATH", os.defpath)}
        for name in ("LANG", "LC_ALL"):
            if name in os.environ:
                environment[name] = os.environ[name]
        environment.update(
            {
                name: value
                for name, value in os.environ.items()
                if name.startswith("FLIGHT_RECORDER_TEST_")
            }
        )
        with tempfile.TemporaryDirectory(
            prefix="flight-recorder-evaluator-"
        ) as working_directory, tempfile.TemporaryFile() as output:
            completed = subprocess.run(
                [str(executable)],
                input=canonical_json(request),
                stdout=output,
                stderr=subprocess.DEVNULL,
                timeout=timeout_seconds,
                check=False,
                env=environment,
                cwd=working_directory,
                preexec_fn=_limit_evaluator_process,
            )
            output.seek(0)
            raw = output.read(MAX_EVALUATOR_OUTPUT_BYTES + 1)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise VaultError("evaluator execution failed") from error
    try:
        current_sha256 = _sha256(executable.read_bytes())
    except OSError as error:
        raise VaultError("evaluator executable changed during evaluation") from error
    if current_sha256 != executable_sha256:
        raise VaultError("evaluator executable changed during evaluation")
    if len(raw) > MAX_EVALUATOR_OUTPUT_BYTES:
        raise VaultError("evaluator response exceeds the size limit")
    if completed.returncode != 0:
        raise VaultError("evaluator execution failed")
    return raw


def _validate_record(
    value: object,
    *,
    evidence_ids: set[str] | None = None,
) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != RECORD_FIELDS
        or value.get("schema_version") != RECORD_VERSION
        or value.get("judgment_type") != "model"
        or value.get("evaluator_protocol_version") != PROTOCOL_VERSION
    ):
        raise VaultError("stored evaluation is invalid")
    for field in (
        "evaluation_id",
        "episode_id",
        "rubric_sha256",
        "evaluator_sha256",
        "input_fingerprint",
    ):
        if (
            not isinstance(value.get(field), str)
            or HASH_RE.fullmatch(value[field]) is None
        ):
            raise VaultError("stored evaluation is invalid")
    for field in ("policy_version", "rubric_version", "evaluator", "model"):
        _safe_name(value.get(field), f"stored evaluation {field}")
    for field in ("source_evidence_ids", "evidence_ids"):
        stored_evidence = value.get(field)
        if (
            not isinstance(stored_evidence, list)
            or stored_evidence != sorted(set(stored_evidence))
            or any(
                not isinstance(item, str) or HASH_RE.fullmatch(item) is None
                for item in stored_evidence
            )
        ):
            raise VaultError("stored evaluation evidence is invalid")
    if (
        not set(value["evidence_ids"]).issubset(
            set(value["source_evidence_ids"])
        )
        or (
            evidence_ids is not None
            and set(value["source_evidence_ids"]) != evidence_ids
        )
    ):
        raise VaultError("stored evaluation evidence is invalid")
    artifacts = value.get("artifact_hashes")
    if not isinstance(artifacts, list):
        raise VaultError("stored evaluation artifacts are invalid")
    for artifact in artifacts:
        if (
            not isinstance(artifact, dict)
            or set(artifact) != {"sha256", "size_bytes"}
            or not isinstance(artifact["sha256"], str)
            or HASH_RE.fullmatch(artifact["sha256"]) is None
            or isinstance(artifact["size_bytes"], bool)
            or not isinstance(artifact["size_bytes"], int)
            or artifact["size_bytes"] < 0
        ):
            raise VaultError("stored evaluation artifacts are invalid")
    if not isinstance(value.get("evaluated_at"), str):
        raise VaultError("stored evaluation timestamp is invalid")
    try:
        parse_time(value["evaluated_at"])
    except ValueError as error:
        raise VaultError("stored evaluation timestamp is invalid") from error
    if (
        value.get("conclusion") not in CONCLUSIONS
        or value.get("confidence") not in CONFIDENCE_LEVELS
    ):
        raise VaultError("stored evaluation judgment is invalid")
    criteria = value.get("criteria")
    if (
        not isinstance(criteria, dict)
        or set(criteria) != CRITERIA
        or any(item not in CRITERION_STATES for item in criteria.values())
    ):
        raise VaultError("stored evaluation criteria are invalid")
    expected_id = _sha256(
        canonical_json(
            {
                key: item
                for key, item in value.items()
                if key != "evaluation_id"
            }
        )
    )
    if value["evaluation_id"] != expected_id:
        raise VaultError("stored evaluation ID is invalid")
    return value


def _stored_evaluations(
    root: Path,
) -> list[tuple[Path, bytes, dict[str, Any]]]:
    directory = root / "evaluations"
    if not directory.exists() and not directory.is_symlink():
        return []
    if directory.is_symlink():
        raise VaultError("evaluation storage is unsafe")
    try:
        metadata = directory.lstat()
        paths = sorted(directory.iterdir())
    except OSError as error:
        raise VaultError("evaluation storage is unsafe") from error
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise VaultError("evaluation storage is unsafe")
    result = []
    for path in paths:
        try:
            item = path.lstat()
            if (
                path.suffix != ".json"
                or not stat.S_ISREG(item.st_mode)
                or item.st_uid != os.geteuid()
                or item.st_nlink != 1
            ):
                raise VaultError("evaluation storage is unsafe")
            raw = path.read_bytes()
            value = _validate_record(json.loads(raw))
            if path.stem != value["evaluation_id"][7:]:
                raise VaultError("stored evaluation filename is invalid")
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise VaultError("stored evaluation is invalid") from error
        result.append((path, raw, value))
    return result


def evaluation_record_snapshots(
    root: Path,
    policy_version: str,
    episode_id: str,
) -> list[tuple[Path, bytes]]:
    return [
        (path, raw)
        for path, raw, value in _stored_evaluations(root)
        if value["policy_version"] == policy_version
        and value["episode_id"] == episode_id
    ]


def load_evaluations(
    root: Path,
    policy_version: str,
    episode_id: str,
    evidence_ids: set[str],
) -> list[dict[str, Any]]:
    result = []
    for _path, _raw, value in _stored_evaluations(root):
        if (
            value["policy_version"] == policy_version
            and value["episode_id"] == episode_id
            and set(value["source_evidence_ids"]) == evidence_ids
        ):
            _validate_record(value, evidence_ids=evidence_ids)
            result.append(value)
    result.sort(key=lambda item: (item["evaluated_at"], item["evaluation_id"]))
    return result


def _evaluated_at() -> str:
    override = os.environ.get("FLIGHT_RECORDER_NOW")
    if override:
        return override
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def evaluate(
    root: Path,
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None,
    rubric_path: Path | None,
    evaluator: str | None,
    model: str | None,
    artifacts: list[Path],
    allow_artifact_content: bool,
    artifact_preview_token: str | None,
    timeout_seconds: int,
) -> dict[str, Any]:
    from reporting import inspect_episode

    if not isinstance(timeout_seconds, int) or not 1 <= timeout_seconds <= 300:
        raise VaultError("evaluator timeout must be between 1 and 300 seconds")
    before = inspect_episode(root, episode_id, policy_version, policy_path)
    scope = _artifact_scope(artifacts)
    preview_token = _artifact_preview_token(root, scope) if scope else None
    if scope and not allow_artifact_content:
        return {
            "schema_version": OUTPUT_VERSION,
            "command": "evaluate",
            "mode": "artifact_scope_preview",
            "episode_id": episode_id,
            "requires_explicit_permission": True,
            "artifact_preview_token": preview_token,
            "artifact_scope": [
                {
                    "path": item["path"],
                    "size_bytes": item["size_bytes"],
                }
                for item in scope
            ],
        }
    if scope and (
        artifact_preview_token is None
        or preview_token is None
        or not hmac.compare_digest(artifact_preview_token, preview_token)
    ):
        raise VaultError(
            "artifact preview is required or the artifact changed"
        )
    if not scope and artifact_preview_token is not None:
        raise VaultError("artifact preview token has no artifact scope")

    selected_evaluator = evaluator or os.environ.get(
        "FLIGHT_RECORDER_EVALUATOR"
    )
    selected_model = model or os.environ.get("FLIGHT_RECORDER_EVALUATOR_MODEL")
    selected_evaluator = _safe_name(selected_evaluator, "evaluator")
    selected_model = _safe_name(selected_model, "evaluator model")
    evaluator_path, evaluator_sha256 = _executable_identity(
        selected_evaluator
    )
    evaluator_id = _safe_name(evaluator_path.name, "evaluator identifier")
    card = before["card"]
    rubric, rubric_sha256 = _load_rubric(rubric_path)
    request_artifacts, artifact_hashes = _read_artifacts(scope)
    episode = _episode_request(card)
    fingerprint_source = {
        "rubric_sha256": rubric_sha256,
        "evaluator": evaluator_id,
        "evaluator_sha256": evaluator_sha256,
        "model": selected_model,
        "policy_version": before["policy_version"],
        "episode_id": episode_id,
        "evidence_ids": sorted(
            fact["evidence_id"] for fact in card["deterministic_evidence"]
        ),
        "artifact_hashes": artifact_hashes,
    }
    input_fingerprint = _sha256(canonical_json(fingerprint_source))
    request = {
        "schema_version": PROTOCOL_VERSION,
        "rubric": rubric,
        "model": selected_model,
        "metadata_only": not bool(request_artifacts),
        "episode": episode,
        "artifacts": request_artifacts,
    }
    response = _validate_response(
        _invoke(
            evaluator_path,
            evaluator_sha256,
            request,
            timeout_seconds,
        ),
        rubric,
        {
            fact["evidence_id"]
            for fact in card["deterministic_evidence"]
        },
    )

    record: dict[str, Any] = {
        "schema_version": RECORD_VERSION,
        "evaluation_id": "",
        "judgment_type": "model",
        "policy_version": before["policy_version"],
        "episode_id": episode_id,
        "rubric_version": rubric["rubric_version"],
        "rubric_sha256": rubric_sha256,
        "evaluator": evaluator_id,
        "evaluator_sha256": evaluator_sha256,
        "evaluator_protocol_version": PROTOCOL_VERSION,
        "model": selected_model,
        "evaluated_at": _evaluated_at(),
        "input_fingerprint": input_fingerprint,
        "source_evidence_ids": sorted(
            fact["evidence_id"]
            for fact in card["deterministic_evidence"]
        ),
        "evidence_ids": response["evidence_ids"],
        "artifact_hashes": artifact_hashes,
        "conclusion": response["conclusion"],
        "confidence": response["confidence"],
        "criteria": response["criteria"],
    }
    record["evaluation_id"] = _sha256(
        canonical_json(
            {
                key: value
                for key, value in record.items()
                if key != "evaluation_id"
            }
        )
    )
    _validate_record(record)
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
            or sorted(
                fact["evidence_id"]
                for fact in after["card"]["deterministic_evidence"]
            )
            != record["source_evidence_ids"]
        ):
            raise VaultError("episode evidence changed during evaluation")
        ensure_managed_gitignore(root)
        directory = safe_subdirectory(root, "evaluations")
        atomic_replace(
            directory / f"{record['evaluation_id'][7:]}.json",
            canonical_json(record) + b"\n",
        )
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "evaluate",
        "mode": "completed",
        "evaluation": record,
    }


def render_evaluate(value: dict[str, Any]) -> str:
    if value["mode"] == "artifact_scope_preview":
        lines = [
            "Evaluation artifact scope preview",
            f"Episode: {value['episode_id']}",
            "Explicit permission required: yes",
            f"Preview token: {value['artifact_preview_token']}",
        ]
        lines.extend(
            f"  {item['path']} ({item['size_bytes']} bytes)"
            for item in value["artifact_scope"]
        )
        return "\n".join(lines)
    item = value["evaluation"]
    return "\n".join(
        (
            "Model evaluation completed",
            f"Evaluation ID: {item['evaluation_id']}",
            f"Rubric: {item['rubric_version']}",
            f"Evaluator/model: {item['evaluator']} / {item['model']}",
            f"Conclusion: {item['conclusion']}",
            f"Confidence: {item['confidence']}",
        )
    )
