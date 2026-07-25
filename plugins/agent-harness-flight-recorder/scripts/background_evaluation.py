#!/usr/bin/env python3
"""Configure local-only metadata background evaluation."""

from __future__ import annotations

import json
import os
import stat
import fcntl
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from chunk_rotation import canonical_json, safe_subdirectory
from evaluation import _safe_name, _sha256
from relationship_graph import load_policy
from vault import (
    VaultError,
    atomic_replace,
    ensure_managed_gitignore,
    vault_lock,
)


OUTPUT_VERSION = 1
CONFIG_PATH = Path("auto-evaluation/config.json")
ATTEMPTS_PATH = Path("auto-evaluation/attempts.json")
STATUS_PATH = Path("auto-evaluation/status.json")
MAX_UNCERTAINTY_SCORE = 1_000_000_000
MAX_EVALUATIONS_PER_RUN = 100
MAX_COST_MICROUSD_PER_RUN = 1_000_000_000_000


class _AlreadyEvaluated(Exception):
    pass


class _AttemptReserved(Exception):
    pass


class _NoLongerCandidate(Exception):
    pass


def _integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _policy_version(value: object) -> str:
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 128
        or any(
            character
            not in
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            for character in value
        )
    ):
        raise VaultError("auto-evaluation policy version is invalid")
    return value


def validate_config(value: object) -> dict[str, Any]:
    fields = {
        "schema_version",
        "enabled",
        "evaluator",
        "model",
        "policy_version",
        "policy_path",
        "uncertainty_score_below",
        "max_evaluations_per_run",
        "max_cost_microusd_per_run",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise VaultError("auto-evaluation config has invalid fields")
    if value["schema_version"] != 1 or value["enabled"] is not True:
        raise VaultError("auto-evaluation config is invalid")
    _safe_name(value["evaluator"], "auto-evaluation evaluator")
    _safe_name(value["model"], "auto-evaluation model")
    _policy_version(value["policy_version"])
    policy_path = value["policy_path"]
    if policy_path is not None and (
        not isinstance(policy_path, str)
        or not Path(policy_path).is_absolute()
        or len(policy_path) > 4096
    ):
        raise VaultError("auto-evaluation policy path is invalid")
    if value["policy_version"] != "default-v1" and policy_path is None:
        raise VaultError("custom auto-evaluation policy requires --policy")
    uncertainty = value["uncertainty_score_below"]
    evaluations = value["max_evaluations_per_run"]
    cost = value["max_cost_microusd_per_run"]
    if (
        not _integer(uncertainty)
        or not 0 <= uncertainty <= MAX_UNCERTAINTY_SCORE
    ):
        raise VaultError("auto-evaluation uncertainty score is invalid")
    if (
        not _integer(evaluations)
        or not 1 <= evaluations <= MAX_EVALUATIONS_PER_RUN
    ):
        raise VaultError("auto-evaluation evaluation budget is invalid")
    if (
        not _integer(cost)
        or not 0 <= cost <= MAX_COST_MICROUSD_PER_RUN
    ):
        raise VaultError("auto-evaluation cost budget is invalid")
    return value


def configure(
    root: Path,
    evaluator: str,
    model: str,
    policy_version: str | None,
    policy_path: Path | None,
    uncertainty_score_below: int,
    max_evaluations_per_run: int,
    max_cost_microusd_per_run: int,
) -> dict[str, Any]:
    selected_policy_path: str | None = None
    if policy_path is not None:
        selected = policy_path.expanduser().absolute()
        policy_version = load_policy(selected)["policy_version"]
        selected_policy_path = str(selected)
    if policy_version is None:
        raise VaultError("auto-evaluation relationship policy is required")
    config = validate_config(
        {
            "schema_version": 1,
            "enabled": True,
            "evaluator": evaluator,
            "model": model,
            "policy_version": policy_version,
            "policy_path": selected_policy_path,
            "uncertainty_score_below": uncertainty_score_below,
            "max_evaluations_per_run": max_evaluations_per_run,
            "max_cost_microusd_per_run": max_cost_microusd_per_run,
        }
    )
    with run_lock(root, blocking=True):
        with vault_lock(root):
            ensure_managed_gitignore(root)
            directory = safe_subdirectory(root, "auto-evaluation")
            atomic_replace(
                root / CONFIG_PATH,
                canonical_json(config) + b"\n",
            )
            for reset_path in (ATTEMPTS_PATH, STATUS_PATH):
                try:
                    (root / reset_path).unlink()
                except FileNotFoundError:
                    pass
            directory.chmod(0o700)
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "auto-evaluation configure",
        "config": config,
    }


def load_config(root: Path) -> dict[str, Any]:
    path = root / CONFIG_PATH
    try:
        metadata = path.lstat()
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("auto-evaluation config is unsafe")
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("auto-evaluation config is unavailable") from error
    return validate_config(value)


def _load_attempts(root: Path) -> dict[str, dict[str, str]]:
    path = root / ATTEMPTS_PATH
    if not path.exists() and not path.is_symlink():
        return {}
    try:
        metadata = path.lstat()
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("auto-evaluation attempts are invalid") from error
    items = value.get("attempts") if isinstance(value, dict) else None
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o077
        or not isinstance(value, dict)
        or set(value) != {"schema_version", "attempts"}
        or value["schema_version"] != 2
        or not isinstance(items, list)
        or items
        != sorted(
            items,
            key=lambda item: (
                item.get("fingerprint", "")
                if isinstance(item, dict)
                else ""
            ),
        )
        or any(
            not isinstance(item, dict)
            or set(item) != {
                "fingerprint",
                "episode_id",
                "state",
            }
            or not isinstance(item["fingerprint"], str)
            or not item["fingerprint"].startswith("sha256:")
            or not isinstance(item["episode_id"], str)
            or not item["episode_id"].startswith("sha256:")
            or item["state"] not in {"pending", "failed"}
            for item in items
        )
        or len({item["fingerprint"] for item in items}) != len(items)
    ):
        raise VaultError("auto-evaluation attempts are invalid")
    return {item["fingerprint"]: item for item in items}


def _store_attempts(
    root: Path, attempts: dict[str, dict[str, str]]
) -> None:
    atomic_replace(
        root / ATTEMPTS_PATH,
        canonical_json(
            {
                "schema_version": 2,
                "attempts": sorted(
                    attempts.values(),
                    key=lambda item: item["fingerprint"],
                ),
            }
        )
        + b"\n",
    )


def _store_status(root: Path, value: dict[str, Any]) -> None:
    atomic_replace(root / STATUS_PATH, canonical_json(value) + b"\n")


def record_failure(root: Path, diagnostic_code: str) -> None:
    """Record a finite scheduler-side failure without changing sync health."""
    if diagnostic_code not in {"configuration_invalid"}:
        raise VaultError("auto-evaluation diagnostic code is invalid")
    with vault_lock(root):
        safe_subdirectory(root, "auto-evaluation")
        _store_status(
            root,
            {
                "schema_version": 1,
                "state": "error",
                "diagnostic_code": diagnostic_code,
                "attempt_count": 0,
            },
        )


def remove_episode_attempts(
    root: Path, episode_id: str
) -> bytes | None:
    """Remove one episode's retry reservations under caller-held locks."""
    path = root / ATTEMPTS_PATH
    if not path.exists() and not path.is_symlink():
        return None
    attempts = _load_attempts(root)
    snapshot = path.read_bytes()
    remaining = {
        fingerprint: item
        for fingerprint, item in attempts.items()
        if item["episode_id"] != episode_id
    }
    _store_attempts(root, remaining)
    return snapshot


def restore_attempts(root: Path, snapshot: bytes | None) -> None:
    """Restore the exact retry ledger after a failed purge transaction."""
    path = root / ATTEMPTS_PATH
    if snapshot is None:
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        return
    atomic_replace(path, snapshot)


@contextmanager
def run_lock(root: Path, *, blocking: bool):
    path = root.parent / f".{root.name}.auto-evaluation.lock"
    try:
        descriptor = os.open(
            path,
            os.O_CREAT
            | os.O_RDWR
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
    except OSError as error:
        raise VaultError(
            "auto-evaluation run lock is unavailable or unsafe"
        ) from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("auto-evaluation run lock is unsafe")
        operation = fcntl.LOCK_EX
        if not blocking:
            operation |= fcntl.LOCK_NB
        try:
            fcntl.flock(descriptor, operation)
            acquired = True
        except BlockingIOError:
            acquired = False
        yield acquired
    finally:
        os.close(descriptor)


def _run_once(root: Path) -> dict[str, Any]:
    from evaluation import evaluate
    from reporting import report

    config = load_config(root)
    view = report(
        root,
        "3650d",
        config["policy_version"],
        (
            Path(config["policy_path"])
            if config["policy_path"] is not None
            else None
        ),
    )
    candidates = [
        card
        for card in view["cards"]
        if card["confidence"] is None
        or card["confidence"]["minimum_supporting_score"]
        < config["uncertainty_score_below"]
    ]
    evaluated = 0
    idempotent_skips = 0
    attempt_skips = 0
    measured_cost = 0
    with vault_lock(root):
        attempts = _load_attempts(root)
    for card in candidates:
        if evaluated >= config["max_evaluations_per_run"]:
            break
        remaining = config["max_cost_microusd_per_run"] - measured_cost
        if remaining <= 0:
            break
        attempt_fingerprint: str | None = None

        def reserve(actual_card: dict[str, Any]) -> None:
            nonlocal attempt_fingerprint
            confidence = actual_card["confidence"]
            if (
                confidence is not None
                and confidence["minimum_supporting_score"]
                >= config["uncertainty_score_below"]
            ):
                raise _NoLongerCandidate
            source_ids = {
                fact["evidence_id"]
                for fact in actual_card["deterministic_evidence"]
            }
            if any(
                item.get("trigger") == "background"
                and item["model"] == config["model"]
                and set(item["source_evidence_ids"]) == source_ids
                for item in actual_card["model_evaluations"]
            ):
                raise _AlreadyEvaluated
            fingerprint = _sha256(
                canonical_json(
                    {
                        "policy_version": config["policy_version"],
                        "episode_id": actual_card["episode_id"],
                        "evaluator": config["evaluator"],
                        "model": config["model"],
                        "source_evidence_ids": sorted(source_ids),
                    }
                )
            )
            if fingerprint in attempts:
                raise _AttemptReserved
            attempts[fingerprint] = {
                "fingerprint": fingerprint,
                "episode_id": actual_card["episode_id"],
                "state": "pending",
            }
            try:
                with vault_lock(root):
                    _store_attempts(root, attempts)
            except VaultError:
                attempts.pop(fingerprint)
                raise
            attempt_fingerprint = fingerprint

        try:
            result = evaluate(
                root,
                card["episode_id"],
                config["policy_version"],
                (
                    Path(config["policy_path"])
                    if config["policy_path"] is not None
                    else None
                ),
                None,
                config["evaluator"],
                config["model"],
                [],
                False,
                None,
                60,
                trigger="background",
                remaining_cost_microusd=remaining,
                before_invoke=reserve,
            )
        except _NoLongerCandidate:
            continue
        except _AlreadyEvaluated:
            idempotent_skips += 1
            continue
        except _AttemptReserved:
            attempt_skips += 1
            continue
        except VaultError:
            if attempt_fingerprint is not None:
                attempts[attempt_fingerprint]["state"] = "failed"
            status = {
                "schema_version": 1,
                "state": "error",
                "diagnostic_code": "evaluator_failed",
                "attempt_count": len(attempts),
            }
            with vault_lock(root):
                if attempt_fingerprint is not None:
                    _store_attempts(root, attempts)
                _store_status(root, status)
            return {
                "schema_version": OUTPUT_VERSION,
                "command": "auto-evaluation run",
                "state": "error",
                "diagnostic_code": "evaluator_failed",
                "candidate_count": len(candidates),
                "evaluated_count": evaluated,
                "idempotent_skip_count": idempotent_skips,
                "attempt_skip_count": attempt_skips,
                "measured_cost_microusd": measured_cost,
            }
        measured_cost += result["evaluation"]["measured_cost_microusd"]
        evaluated += 1
        assert attempt_fingerprint is not None
        attempts.pop(attempt_fingerprint)
        with vault_lock(root):
            _store_attempts(root, attempts)
    attempt_states = {item["state"] for item in attempts.values()}
    diagnostic_code = (
        "evaluator_failed"
        if "failed" in attempt_states
        else "attempt_pending"
        if "pending" in attempt_states
        else None
    )
    status = {
        "schema_version": 1,
        "state": "error" if diagnostic_code is not None else "healthy",
        "diagnostic_code": diagnostic_code,
        "attempt_count": len(attempts),
    }
    with vault_lock(root):
        _store_status(root, status)
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "auto-evaluation run",
        "state": "completed",
        "candidate_count": len(candidates),
        "evaluated_count": evaluated,
        "idempotent_skip_count": idempotent_skips,
        "attempt_skip_count": attempt_skips,
        "measured_cost_microusd": measured_cost,
    }


def run(root: Path) -> dict[str, Any]:
    with run_lock(root, blocking=False) as acquired:
        if not acquired:
            return {
                "schema_version": OUTPUT_VERSION,
                "command": "auto-evaluation run",
                "state": "busy",
                "candidate_count": 0,
                "evaluated_count": 0,
                "idempotent_skip_count": 0,
                "attempt_skip_count": 0,
                "measured_cost_microusd": 0,
            }
        return _run_once(root)
