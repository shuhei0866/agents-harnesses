"""Explicit derived-state forgetting and best-effort Git history purge."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

from chunk_rotation import atomic_replace, canonical_json
from background_evaluation import (
    remove_episode_attempts,
    restore_attempts,
    run_lock as auto_evaluation_lock,
)
from evidence_index import DATABASE_PATH, rebuild_index_locked
from evaluation import evaluation_record_snapshots
from meaning_lift import meaning_card_record_snapshots
from reporting import (
    EPISODE_ID_RE,
    OUTPUT_VERSION,
    _authenticated_query,
    _authenticated_query_locked,
    _policy_selection,
)
from receipt_automation import (
    remove_episode_attempts as remove_receipt_attempts,
    restore_attempts as restore_receipt_attempts,
    run_lock as receipt_automation_lock,
)
from retention_state import load_forgotten, store_forgotten
from semantic_receipts import semantic_receipt_record_snapshots
from value_compiler import value_primitive_card_record_snapshots
from sync import (
    CHUNK_PATH_RE,
    PENDING_PATH,
    RECEIPT_PATH,
    git,
    import_chunks,
    load_pending,
    text_output,
)
from vault import VaultError, load_config, vault_lock


LIMITATION = (
    "Best-effort purge cannot guarantee deletion from independent or "
    "uncontrolled remote clones, provider caches, or backups."
)


def _selection(
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None,
) -> tuple[str, dict[str, Any] | None]:
    if EPISODE_ID_RE.fullmatch(episode_id) is None:
        raise VaultError("episode ID is invalid")
    return _policy_selection(policy_version, policy_path)


def _scope(
    root: Path,
    episode_id: str,
    policy_version: str,
    trusted_policy: dict[str, Any] | None,
    *,
    locked: bool = False,
) -> dict[str, Any]:
    def query(connection: Any, _policy: dict[str, Any]) -> dict[str, Any]:
        rows = list(
            connection.execute(
                """
                SELECT DISTINCT c.source_path, p.cache_path, c.chunk_id
                FROM episode_members AS m
                JOIN source_events AS e ON e.event_id = m.event_id
                JOIN source_chunks AS c ON c.chunk_id = e.chunk_id
                JOIN import_provenance AS p ON p.chunk_id = c.chunk_id
                WHERE m.policy_version = ? AND m.episode_id = ?
                ORDER BY c.source_path
                """,
                (policy_version, episode_id),
            )
        )
        if not rows:
            raise VaultError("episode was not found for relationship policy")
        return {
            "schema_version": OUTPUT_VERSION,
            "command": "purge",
            "episode_id": episode_id,
            "policy_version": policy_version,
            "apply": False,
            "chunks": [
                {
                    "source_path": source,
                    "cache_path": cache,
                    "chunk_id": chunk,
                }
                for source, cache, chunk in rows
            ],
            "evaluation_record_count": len(
                evaluation_record_snapshots(
                    root, policy_version, episode_id
                )
            ),
            "semantic_receipt_record_count": len(
                semantic_receipt_record_snapshots(
                    root, policy_version, episode_id
                )
            ),
            "meaning_card_record_count": len(
                meaning_card_record_snapshots(
                    root, policy_version, episode_id
                )
            ),
            "value_primitive_card_record_count": len(
                value_primitive_card_record_snapshots(
                    root, policy_version, episode_id
                )
            ),
            "limitation": LIMITATION,
        }

    authenticated = (
        _authenticated_query_locked if locked else _authenticated_query
    )
    return authenticated(root, policy_version, query, trusted_policy)


def forget(
    root: Path,
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None,
) -> dict[str, Any]:
    selected, trusted = _selection(episode_id, policy_version, policy_path)
    with vault_lock(root):
        _scope(root, episode_id, selected, trusted, locked=True)
        entries = load_forgotten(root)
        entries.add((selected, episode_id))
        store_forgotten(root, entries)
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "forget",
        "episode_id": episode_id,
        "policy_version": selected,
        "forgotten": True,
    }


def _run_git(root: Path, arguments: list[str], *, env: dict[str, str] | None = None) -> None:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        shell=False,
        env=env,
    )
    if result.returncode != 0:
        raise VaultError("Git history purge failed")


def _validate_remote_namespace(root: Path) -> None:
    config = load_config(root)
    expected = config["remote"]
    assert isinstance(expected, str)
    if text_output(git(root, ["remote", "get-url", "origin"])).strip() != expected:
        raise VaultError("Git origin does not match the Vault remote")
    push_urls = text_output(
        git(root, ["remote", "get-url", "--push", "--all", "origin"])
    ).splitlines()
    if push_urls != [expected]:
        raise VaultError("Git origin push URL does not match the Vault remote")
    output = subprocess.run(
        ["git", "-C", str(root), "ls-remote", "--refs", "origin"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        shell=False,
    )
    if output.returncode != 0:
        raise VaultError("Git history purge failed")
    try:
        lines = output.stdout.decode("utf-8").splitlines()
    except UnicodeError as error:
        raise VaultError("Git history purge failed") from error
    refs = {line.split("\t", 1)[1] for line in lines if "\t" in line}
    if refs - {"refs/heads/main"}:
        raise VaultError(
            "purge requires a dedicated remote with only the main branch"
        )


def _rewrite_history(root: Path, paths: list[str]) -> None:
    if not paths or any(CHUNK_PATH_RE.fullmatch(path) is None for path in paths):
        raise VaultError("purge scope contains an invalid chunk path")
    quoted = " ".join("'" + path + "'" for path in paths)
    environment = os.environ.copy()
    environment["FILTER_BRANCH_SQUELCH_WARNING"] = "1"
    _run_git(
        root,
        [
            "filter-branch",
            "--force",
            "--index-filter",
            f"git rm -q --cached --ignore-unmatch -- {quoted}",
            "--prune-empty",
            "--tag-name-filter",
            "cat",
            "--",
            "--all",
        ],
        env=environment,
    )


def _original_refs(root: Path) -> list[str]:
    refs = (
        subprocess.run(
            ["git", "-C", str(root), "for-each-ref", "--format=%(refname)", "refs/original/"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        .stdout.decode("utf-8", errors="strict")
        .splitlines()
    )
    return [
        ref
        for ref in refs
        if re.fullmatch(r"refs/original/[A-Za-z0-9._/-]+", ref)
    ]


def _restore_history(root: Path) -> None:
    refs = _original_refs(root)
    for ref in refs:
        target = ref.removeprefix("refs/original/")
        oid = text_output(git(root, ["rev-parse", ref])).strip()
        _run_git(root, ["update-ref", target, oid])
    _run_git(root, ["reset", "--hard", "refs/heads/main"])


def _cleanup_original_history(root: Path) -> None:
    for ref in _original_refs(root):
        _run_git(root, ["update-ref", "-d", ref])
    _run_git(root, ["reflog", "expire", "--expire=now", "--all"])
    _run_git(root, ["gc", "--prune=now"])


def _remove_local_derivatives(
    root: Path, scope: dict[str, Any], *, apply: bool = True
) -> None:
    target_paths = {item["source_path"] for item in scope["chunks"]}
    cache_paths: list[Path] = []
    for item in scope["chunks"]:
        cache = root / item["cache_path"]
        expected_cache = (
            f"cache/imported/"
            f"{item['source_path'][len('devices/'):-len('.age')]}"
        )
        if (
            item["cache_path"] != expected_cache
            or cache.is_symlink()
            or not cache.is_file()
        ):
            raise VaultError("purge cache scope is unsafe")
        cache_paths.append(cache)

    receipt_path = root / RECEIPT_PATH
    try:
        receipts = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("import receipt is invalid") from error
    chunks = receipts.get("chunks")
    if receipts.get("schema_version") != 1 or not isinstance(chunks, dict):
        raise VaultError("import receipt is invalid")
    pending = load_pending(root)
    if pending is not None:
        artifact_paths = pending.get("artifact_paths")
        if not isinstance(artifact_paths, list):
            raise VaultError("pending sync state is invalid")
    # Validate owner-held state and the current database before mutating any
    # local derivative. The authenticated scope query already validated the
    # database contents; these checks close path/type races.
    load_forgotten(root)
    database = root / DATABASE_PATH
    if database.is_symlink() or not database.is_file():
        raise VaultError("evidence index is unsafe")
    if not apply:
        return

    for cache in cache_paths:
        cache.unlink()
    for path in target_paths:
        chunks.pop(path, None)
    atomic_replace(receipt_path, canonical_json(receipts) + b"\n")

    if pending is not None:
        assert isinstance(artifact_paths, list)
        pending["artifact_paths"] = [
            path for path in artifact_paths if path not in target_paths
        ]
        atomic_replace(root / PENDING_PATH, canonical_json(pending) + b"\n")

    database.unlink()


def purge(
    root: Path,
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None,
    *,
    apply: bool,
) -> dict[str, Any]:
    selected, trusted = _selection(episode_id, policy_version, policy_path)
    scope = _scope(root, episode_id, selected, trusted)
    if not apply:
        return scope
    # Global order for purge is background evaluation, Receipt automation,
    # then Vault. Each runner takes only its own run lock before Vault, so this
    # order cannot form a cycle and blocks both evaluator types during purge.
    with auto_evaluation_lock(root, blocking=True):
        with receipt_automation_lock(root, blocking=True):
            with vault_lock(root):
                # Reauthenticate and resolve scope under the same exclusive lock
                # used for mutation so a sync/rebuild cannot make the preview stale.
                scope = _scope(
                    root, episode_id, selected, trusted, locked=True
                )
                paths = [item["source_path"] for item in scope["chunks"]]
                _validate_remote_namespace(root)
                # Validate every local input before history or derivative mutation.
                _remove_local_derivatives(root, scope, apply=False)
                original_forgotten = load_forgotten(root)
                pending_path = root / PENDING_PATH
                original_pending = (
                    pending_path.read_bytes() if pending_path.exists() else None
                )
                evaluation_snapshots = evaluation_record_snapshots(
                    root, selected, episode_id
                )
                semantic_receipt_snapshots = semantic_receipt_record_snapshots(
                    root, selected, episode_id
                )
                meaning_card_snapshots = meaning_card_record_snapshots(
                    root, selected, episode_id
                )
                value_primitive_card_snapshots = (
                    value_primitive_card_record_snapshots(
                        root, selected, episode_id
                    )
                )
                attempt_snapshot = remove_episode_attempts(root, episode_id)
                try:
                    receipt_attempt_snapshot = remove_receipt_attempts(
                        root, episode_id
                    )
                except VaultError:
                    restore_attempts(root, attempt_snapshot)
                    raise
                attempt_committed = False
                try:
                    _rewrite_history(root, paths)
                    _remove_local_derivatives(root, scope)
                    rebuild_index_locked(root, incremental=False)
                    forgotten = set(original_forgotten)
                    forgotten.discard((selected, episode_id))
                    store_forgotten(root, forgotten)
                    derivative_snapshots = [
                        *evaluation_snapshots,
                        *semantic_receipt_snapshots,
                        *meaning_card_snapshots,
                        *value_primitive_card_snapshots,
                    ]
                    removed_derivatives: list[tuple[Path, bytes]] = []
                    try:
                        for derivative_path, derivative_bytes in derivative_snapshots:
                            derivative_path.unlink()
                            removed_derivatives.append(
                                (derivative_path, derivative_bytes)
                            )
                    except OSError as error:
                        for derivative_path, derivative_bytes in removed_derivatives:
                            atomic_replace(derivative_path, derivative_bytes)
                        raise VaultError(
                            "derived record storage is unsafe"
                        ) from error
                    try:
                        # Keep refs/original until the remote accepts the rewrite.
                        # A rejection restores the Vault to a retryable state.
                        _run_git(
                            root, ["push", "--force", "origin", "HEAD:main"]
                        )
                    except VaultError:
                        _restore_history(root)
                        import_chunks(root)
                        rebuild_index_locked(root, incremental=False)
                        store_forgotten(root, original_forgotten)
                        if original_pending is None:
                            try:
                                pending_path.unlink()
                            except FileNotFoundError:
                                pass
                        else:
                            atomic_replace(pending_path, original_pending)
                        for evaluation_path, evaluation_bytes in evaluation_snapshots:
                            atomic_replace(evaluation_path, evaluation_bytes)
                        for receipt_path, receipt_bytes in semantic_receipt_snapshots:
                            atomic_replace(receipt_path, receipt_bytes)
                        for card_path, card_bytes in meaning_card_snapshots:
                            atomic_replace(card_path, card_bytes)
                        for card_path, card_bytes in value_primitive_card_snapshots:
                            atomic_replace(card_path, card_bytes)
                        _cleanup_original_history(root)
                        raise
                    _cleanup_original_history(root)
                    attempt_committed = True
                finally:
                    if not attempt_committed:
                        active_error = sys.exc_info()[0] is not None
                        restore_errors: list[Exception] = []
                        for restore, snapshot in (
                            (restore_attempts, attempt_snapshot),
                            (
                                restore_receipt_attempts,
                                receipt_attempt_snapshot,
                            ),
                        ):
                            try:
                                restore(root, snapshot)
                            except Exception as error:
                                restore_errors.append(error)
                        if restore_errors and not active_error:
                            error = restore_errors[0]
                            if isinstance(error, VaultError):
                                raise error
                            raise VaultError(
                                "attempt ledger restoration failed"
                            ) from error
    scope["apply"] = True
    return scope


def render_forget(value: dict[str, Any]) -> str:
    return (
        f"Forgot episode {value['episode_id']} "
        f"for policy {value['policy_version']}.\n"
    )


def render_purge(value: dict[str, Any]) -> str:
    mode = "Applied" if value["apply"] else "Dry run"
    paths = "\n".join(
        f"- {item['source_path']}" for item in value["chunks"]
    )
    return (
        f"{mode}: purge episode {value['episode_id']}\n"
        f"Affected encrypted chunks:\n{paths}\n"
        f"Local evaluation records: {value['evaluation_record_count']}\n"
        "Local Semantic Receipt records: "
        f"{value['semantic_receipt_record_count']}\n"
        "Local Meaning Card records: "
        f"{value['meaning_card_record_count']}\n"
        "Local Value Primitive Card records: "
        f"{value['value_primitive_card_record_count']}\n"
        f"{value['limitation']}\n"
    )
