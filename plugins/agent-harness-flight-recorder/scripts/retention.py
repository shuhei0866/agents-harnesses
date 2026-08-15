"""Explicit derived-state forgetting and best-effort Git history purge."""

from __future__ import annotations

import json
import contextlib
import os
import re
import stat
import subprocess
from pathlib import Path
from typing import Any

from chunk_rotation import atomic_replace, canonical_json, fsync_directory
from background_evaluation import (
    remove_episode_attempts,
    restore_attempts,
    run_lock as auto_evaluation_lock,
)
from evidence_index import (
    DATABASE_PATH,
    INDEX_SEAL_PATH,
    issue_index_seal,
    rebuild_index_locked,
)
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
from retention_state import FORGET_PATH, load_forgotten, store_forgotten
from semantic_receipts import semantic_receipt_record_snapshots
from value_compiler import (
    prepared_record_snapshots,
    remove_episode_attempts as remove_value_attempts,
    restore_attempts as restore_value_attempts,
    run_lock as value_compiler_lock,
    value_attempt_record_count,
    value_primitive_card_record_snapshots,
)
from sync import (
    CHUNK_PATH_RE,
    PENDING_PATH,
    RECEIPT_PATH,
    git,
    load_pending,
    text_output,
)
from vault import VaultError, load_config, vault_lock


LIMITATION = (
    "Best-effort purge cannot guarantee deletion from independent or "
    "uncontrolled remote clones, provider caches, or backups."
)
PURGE_RECOVERY_PATH = Path("index/purge-recovery.json")
PURGE_RECOVERY_CONTRACT = "purge-cleanup-recovery-v1"
MAX_PURGE_RECOVERY_BYTES = 4096
GIT_OBJECT_ID_RE = re.compile(r"^[0-9a-f]{40,64}$")
PURGE_ROLLBACK_DIRECTORY = Path("index/purge-index-rollback")
ROLLBACK_COPY_BYTES = 1024 * 1024


def _purge_recovery_directory(root: Path) -> Path:
    directory = root / "index"
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise VaultError("purge recovery directory is unsafe") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise VaultError("purge recovery directory is unsafe")
    return directory


def _validate_purge_recovery(value: object) -> dict[str, Any]:
    fields = {
        "schema_version",
        "contract_version",
        "state",
        "episode_id",
        "policy_version",
        "old_remote_oid",
        "new_rewritten_oid",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise VaultError("purge recovery marker is invalid")
    policy_version = value["policy_version"]
    if (
        isinstance(value["schema_version"], bool)
        or not isinstance(value["schema_version"], int)
        or value["schema_version"] != 1
        or value["contract_version"] != PURGE_RECOVERY_CONTRACT
        or value["state"] != "push_pending"
        or not isinstance(value["episode_id"], str)
        or EPISODE_ID_RE.fullmatch(value["episode_id"]) is None
        or not isinstance(policy_version, str)
        or not policy_version
        or len(policy_version) > 128
        or any(
            character
            not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
            for character in policy_version
        )
        or not isinstance(value["old_remote_oid"], str)
        or GIT_OBJECT_ID_RE.fullmatch(value["old_remote_oid"]) is None
        or not isinstance(value["new_rewritten_oid"], str)
        or GIT_OBJECT_ID_RE.fullmatch(value["new_rewritten_oid"]) is None
        or value["old_remote_oid"] == value["new_rewritten_oid"]
    ):
        raise VaultError("purge recovery marker is invalid")
    return value


def _load_purge_recovery(root: Path) -> dict[str, Any] | None:
    _purge_recovery_directory(root)
    path = root / PURGE_RECOVERY_PATH
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise VaultError("purge recovery marker is unsafe") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_size > MAX_PURGE_RECOVERY_BYTES
        ):
            raise VaultError("purge recovery marker is unsafe")
        chunks = []
        remaining = MAX_PURGE_RECOVERY_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(remaining, 4096))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > MAX_PURGE_RECOVERY_BYTES:
            raise VaultError("purge recovery marker is unsafe")
    except OSError as error:
        raise VaultError("purge recovery marker is unsafe") from error
    finally:
        os.close(descriptor)
    try:
        value = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise VaultError("purge recovery marker is invalid") from error
    return _validate_purge_recovery(value)


def _store_purge_recovery(root: Path, value: dict[str, Any]) -> None:
    expected = _validate_purge_recovery(value)
    _purge_recovery_directory(root)
    path = root / PURGE_RECOVERY_PATH
    atomic_replace(path, canonical_json(expected) + b"\n")
    current = _load_purge_recovery(root)
    if current != expected:
        raise VaultError("purge recovery marker changed while storing")


def _clear_purge_recovery(
    root: Path, expected: dict[str, Any]
) -> None:
    if _load_purge_recovery(root) != expected:
        raise VaultError("purge recovery marker changed")
    path = root / PURGE_RECOVERY_PATH
    try:
        path.unlink()
        fsync_directory(path.parent)
    except OSError as error:
        raise VaultError("purge recovery marker cannot be removed") from error


@contextlib.contextmanager
def _purge_evaluator_locks(root: Path):
    # Value Compiler takes its own run lock before Vault. Purge uses the same
    # order, then preserves the established auto-evaluation/Receipt order.
    with value_compiler_lock(root, blocking=True):
        with auto_evaluation_lock(root, blocking=True):
            yield


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
            "value_compiler_prepared_record_count": len(
                prepared_record_snapshots(
                    root, policy_version, episode_id
                )
            ),
            "value_compiler_attempt_record_count": (
                value_attempt_record_count(
                    root, episode_id, policy_version
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
        issue_index_seal(root)
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


def _ref_snapshot(root: Path, *, require_main: bool = True) -> dict[str, str]:
    output = text_output(
        git(root, ["for-each-ref", "--format=%(refname) %(objectname)"])
    )
    result: dict[str, str] = {}
    for line in output.splitlines():
        try:
            ref, object_id = line.split(" ", 1)
        except ValueError as error:
            raise VaultError("Git history purge failed") from error
        if (
            re.fullmatch(r"refs/[A-Za-z0-9._/-]+", ref) is None
            or re.fullmatch(r"[0-9a-f]{40,64}", object_id) is None
            or ref in result
        ):
            raise VaultError("Git history purge failed")
        result[ref] = object_id
    if require_main and "refs/heads/main" not in result:
        raise VaultError("Git history purge failed")
    return result


def _remote_main_oid(root: Path) -> str:
    output = text_output(
        git(root, ["ls-remote", "--refs", "origin", "refs/heads/main"])
    ).splitlines()
    if len(output) != 1 or "\t" not in output[0]:
        raise VaultError("Git history purge failed")
    object_id, ref = output[0].split("\t", 1)
    if (
        ref != "refs/heads/main"
        or re.fullmatch(r"[0-9a-f]{40,64}", object_id) is None
    ):
        raise VaultError("Git history purge failed")
    return object_id


def _require_synced_main(root: Path) -> str:
    try:
        symbolic_head = text_output(
            git(root, ["symbolic-ref", "--quiet", "HEAD"])
        ).strip()
        head_oid = text_output(git(root, ["rev-parse", "HEAD"])).strip()
        main_oid = text_output(
            git(
                root,
                ["show-ref", "--verify", "--hash", "refs/heads/main"],
            )
        ).strip()
        remote_oid = _remote_main_oid(root)
    except VaultError as error:
        raise VaultError("purge sync required before apply") from error
    if (
        symbolic_head != "refs/heads/main"
        or GIT_OBJECT_ID_RE.fullmatch(head_oid) is None
        or GIT_OBJECT_ID_RE.fullmatch(main_oid) is None
        or head_oid != main_oid
        or main_oid != remote_oid
    ):
        raise VaultError("purge sync required before apply")
    return main_oid


def _push_main_with_lease(
    root: Path,
    *,
    expected_remote_oid: str,
    new_oid: str,
) -> None:
    if (
        GIT_OBJECT_ID_RE.fullmatch(expected_remote_oid) is None
        or GIT_OBJECT_ID_RE.fullmatch(new_oid) is None
    ):
        raise VaultError("Git history purge lease is invalid")
    _run_git(
        root,
        [
            "push",
            f"--force-with-lease=refs/heads/main:{expected_remote_oid}",
            "origin",
            f"{new_oid}:refs/heads/main",
        ],
    )
    if _remote_main_oid(root) != new_oid:
        raise VaultError("Git history purge lease did not converge")


def _cleanup_only_result(marker: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": OUTPUT_VERSION,
        "command": "purge",
        "episode_id": marker["episode_id"],
        "policy_version": marker["policy_version"],
        "apply": True,
        "cleanup_only": True,
        "chunks": [],
        "evaluation_record_count": 0,
        "semantic_receipt_record_count": 0,
        "meaning_card_record_count": 0,
        "value_primitive_card_record_count": 0,
        "value_compiler_prepared_record_count": 0,
        "value_compiler_attempt_record_count": 0,
        "limitation": LIMITATION,
    }


def _resume_purge_recovery(
    root: Path,
    episode_id: str,
    policy_version: str,
) -> dict[str, Any] | None:
    marker = _load_purge_recovery(root)
    if marker is None:
        return None
    if (
        marker["episode_id"] != episode_id
        or marker["policy_version"] != policy_version
    ):
        raise VaultError("purge recovery marker does not match request")
    _validate_remote_namespace(root)
    remote_oid = _remote_main_oid(root)
    local_oid = _ref_snapshot(root)["refs/heads/main"]
    if remote_oid == marker["new_rewritten_oid"]:
        if local_oid != marker["new_rewritten_oid"]:
            raise VaultError("purge recovery local history diverged")
        try:
            _discard_index_projection_snapshots(root)
            _cleanup_original_history(root)
            _clear_purge_recovery(root, marker)
        except Exception as error:
            raise VaultError(
                "remote rewrite applied; local cleanup incomplete; "
                "retry required"
            ) from error
        return _cleanup_only_result(marker)
    if remote_oid == marker["old_remote_oid"]:
        if local_oid == marker["old_remote_oid"]:
            _discard_index_projection_snapshots(root)
            _clear_purge_recovery(root, marker)
            return None
        if local_oid != marker["new_rewritten_oid"]:
            raise VaultError("purge recovery local history diverged")
        _push_main_with_lease(
            root,
            expected_remote_oid=marker["old_remote_oid"],
            new_oid=marker["new_rewritten_oid"],
        )
        try:
            _discard_index_projection_snapshots(root)
            _cleanup_original_history(root)
            _clear_purge_recovery(root, marker)
        except Exception as error:
            raise VaultError(
                "remote rewrite applied; local cleanup incomplete; "
                "retry required"
            ) from error
        return _cleanup_only_result(marker)
    raise VaultError("purge recovery remote history diverged")


def _local_file_snapshots(
    paths: list[Path],
) -> list[tuple[Path, bytes | None, int | None]]:
    snapshots = []
    for path in sorted(set(paths)):
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            snapshots.append((path, None, None))
            continue
        except OSError as error:
            raise VaultError("purge rollback input is unsafe") from error
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
        ):
            raise VaultError("purge rollback input is unsafe")
        try:
            raw = path.read_bytes()
        except OSError as error:
            raise VaultError("purge rollback input is unsafe") from error
        snapshots.append((path, raw, stat.S_IMODE(metadata.st_mode)))
    return snapshots


def _index_projection_snapshot_paths(root: Path) -> tuple[Path, Path]:
    return root / DATABASE_PATH, root / INDEX_SEAL_PATH


def _copy_disk_snapshot(source: Path, target: Path) -> int:
    source_descriptor = -1
    target_descriptor = -1
    try:
        source_descriptor = os.open(
            source,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        before = os.fstat(source_descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or before.st_nlink != 1
        ):
            raise VaultError("purge disk rollback input is unsafe")
        target_descriptor = os.open(
            target,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
        )
        while True:
            block = os.read(source_descriptor, ROLLBACK_COPY_BYTES)
            if not block:
                break
            view = memoryview(block)
            while view:
                written = os.write(target_descriptor, view)
                if written <= 0:
                    raise VaultError("purge disk rollback snapshot failed")
                view = view[written:]
        os.fsync(target_descriptor)
        after = os.fstat(source_descriptor)
        stable_fields = (
            "st_dev",
            "st_ino",
            "st_size",
            "st_mtime_ns",
            "st_mode",
            "st_uid",
            "st_nlink",
        )
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise VaultError("purge disk rollback input changed")
        return stat.S_IMODE(before.st_mode)
    except VaultError:
        raise
    except OSError as error:
        raise VaultError("purge disk rollback snapshot failed") from error
    finally:
        if target_descriptor >= 0:
            os.close(target_descriptor)
        if source_descriptor >= 0:
            os.close(source_descriptor)


def _snapshot_index_projection(
    root: Path,
) -> list[tuple[Path, Path, int]]:
    index = _purge_recovery_directory(root)
    directory = root / PURGE_ROLLBACK_DIRECTORY
    try:
        os.mkdir(directory, 0o700)
    except OSError as error:
        raise VaultError("purge disk rollback directory is unsafe") from error
    snapshots: list[tuple[Path, Path, int]] = []
    try:
        for source in _index_projection_snapshot_paths(root):
            target = directory / source.name
            mode = _copy_disk_snapshot(source, target)
            snapshots.append((source, target, mode))
        fsync_directory(directory)
        fsync_directory(index)
        return snapshots
    except Exception:
        for source in reversed(_index_projection_snapshot_paths(root)):
            target = directory / source.name
            try:
                target.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass
        try:
            directory.rmdir()
        except OSError:
            pass
        raise


def _validate_disk_snapshot(path: Path) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise VaultError("purge disk rollback snapshot is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise VaultError("purge disk rollback snapshot is unsafe")


def _restore_index_projection_snapshots(
    root: Path, snapshots: list[tuple[Path, Path, int]]
) -> list[Exception]:
    if not snapshots:
        return []
    errors: list[Exception] = []
    directory = root / PURGE_ROLLBACK_DIRECTORY
    for target, backup, mode in snapshots:
        try:
            _validate_disk_snapshot(backup)
            os.replace(backup, target)
            target.chmod(mode)
            fsync_directory(target.parent)
        except Exception as error:
            errors.append(error)
    if not errors:
        try:
            directory.rmdir()
            fsync_directory(directory.parent)
            # A copy-backed restore has a new inode even when its bytes are
            # exact, so the restored seal must be rebound to that inode.
            issue_index_seal(root)
        except Exception as error:
            errors.append(error)
    return errors


def _discard_index_projection_snapshots(root: Path) -> None:
    directory = root / PURGE_ROLLBACK_DIRECTORY
    if not directory.exists() and not directory.is_symlink():
        return
    try:
        metadata = directory.lstat()
    except OSError as error:
        raise VaultError("purge disk rollback directory is unsafe") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise VaultError("purge disk rollback directory is unsafe")
    for name in (DATABASE_PATH.name, INDEX_SEAL_PATH.name):
        backup = directory / name
        if not backup.exists() and not backup.is_symlink():
            continue
        _validate_disk_snapshot(backup)
        backup.unlink()
    directory.rmdir()
    fsync_directory(directory.parent)


def _restore_local_file_snapshots(
    snapshots: list[tuple[Path, bytes | None, int | None]],
) -> list[Exception]:
    errors: list[Exception] = []
    for path, raw, mode in snapshots:
        try:
            if raw is None:
                path.unlink()
                fsync_directory(path.parent)
                continue
            assert mode is not None
            atomic_replace(path, raw)
            path.chmod(mode)
        except FileNotFoundError:
            if raw is not None:
                errors.append(
                    VaultError("purge rollback target disappeared")
                )
        except Exception as error:
            errors.append(error)
    return errors


def _restore_ref_snapshot(root: Path, snapshot: dict[str, str]) -> None:
    current = _ref_snapshot(root, require_main=False)
    for ref in sorted(current.keys() - snapshot.keys()):
        if ref.startswith("refs/original/"):
            continue
        _run_git(root, ["update-ref", "-d", ref])
    for ref, object_id in sorted(snapshot.items()):
        _run_git(root, ["update-ref", ref, object_id])
    _run_git(root, ["reset", "--hard", snapshot["refs/heads/main"]])


def _rollback_purge_state(
    root: Path,
    *,
    refs: dict[str, str],
    remote_main_oid: str,
    rewritten_remote_oid: str | None = None,
    files: list[tuple[Path, bytes | None, int | None]],
    value_attempts: bytes | None,
    evaluation_attempts: bytes | None,
    receipt_attempts: bytes | None,
    index_projection_files: list[tuple[Path, Path, int]] | None = None,
) -> list[Exception]:
    """Best-effort restoration of every state mutated after rewrite begins."""
    errors: list[Exception] = []

    # filter-branch may have stopped at any point. Restore its original refs
    # first when available, then reconcile the complete ref namespace to the
    # exact pre-transaction snapshot.
    try:
        legacy_refs = _original_refs(root)
    except Exception as error:
        errors.append(error)
        legacy_refs = []
    if legacy_refs:
        try:
            _restore_history(root)
        except Exception as error:
            errors.append(error)

    exact_refs_restored = False
    try:
        _restore_ref_snapshot(root, refs)
        exact_refs_restored = True
    except Exception as error:
        errors.append(error)

    errors.extend(_restore_local_file_snapshots(files))
    errors.extend(
        _restore_index_projection_snapshots(
            root, index_projection_files or []
        )
    )

    for restore, snapshot in (
        (restore_value_attempts, value_attempts),
        (restore_attempts, evaluation_attempts),
        (restore_receipt_attempts, receipt_attempts),
    ):
        try:
            restore(root, snapshot)
        except Exception as error:
            errors.append(error)

    remote_restored = False
    try:
        current_remote = _remote_main_oid(root)
        if current_remote == remote_main_oid:
            remote_restored = True
        elif (
            rewritten_remote_oid is not None
            and current_remote == rewritten_remote_oid
        ):
            _push_main_with_lease(
                root,
                expected_remote_oid=rewritten_remote_oid,
                new_oid=remote_main_oid,
            )
            remote_restored = True
        else:
            raise VaultError("remote purge rollback history diverged")
    except Exception as error:
        errors.append(error)

    # Never discard refs/original while either exact local refs or the remote
    # still need recovery material.
    if exact_refs_restored and remote_restored:
        try:
            _cleanup_original_history(root)
        except Exception as error:
            errors.append(error)
    return errors


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
    seal = root / INDEX_SEAL_PATH
    if database.is_symlink() or not database.is_file():
        raise VaultError("evidence index is unsafe")
    if seal.is_symlink() or not seal.is_file():
        raise VaultError("evidence index seal is unsafe")
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
    seal.unlink()


def purge(
    root: Path,
    episode_id: str,
    policy_version: str | None,
    policy_path: Path | None,
    *,
    apply: bool,
) -> dict[str, Any]:
    selected, trusted = _selection(episode_id, policy_version, policy_path)
    if not apply:
        return _scope(root, episode_id, selected, trusted)
    # Global order for purge is Value Compiler, background evaluation,
    # Receipt automation, then Vault. Each runner takes only its own run lock
    # before Vault, so this cannot form a cycle and blocks all evaluators.
    with _purge_evaluator_locks(root):
        with receipt_automation_lock(root, blocking=True):
            with vault_lock(root):
                recovered = _resume_purge_recovery(
                    root, episode_id, selected
                )
                if recovered is not None:
                    return recovered
                _require_synced_main(root)
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
                value_prepared_snapshots = prepared_record_snapshots(
                    root, selected, episode_id
                )
                derivative_snapshots = [
                    *evaluation_snapshots,
                    *semantic_receipt_snapshots,
                    *meaning_card_snapshots,
                    *value_primitive_card_snapshots,
                    *value_prepared_snapshots,
                ]
                rollback_paths = [
                    root / item[key]
                    for item in scope["chunks"]
                    for key in ("source_path", "cache_path")
                ]
                rollback_paths.extend(
                    (
                        root / RECEIPT_PATH,
                        root / PENDING_PATH,
                        root / FORGET_PATH,
                        root / PURGE_RECOVERY_PATH,
                    )
                )
                rollback_paths.extend(
                    path for path, _raw in derivative_snapshots
                )
                local_snapshots = _local_file_snapshots(rollback_paths)
                original_refs = _ref_snapshot(root)
                original_remote_main = _remote_main_oid(root)
                value_attempt_snapshot = remove_value_attempts(
                    root, episode_id, selected
                )
                try:
                    attempt_snapshot = remove_episode_attempts(
                        root, episode_id
                    )
                except VaultError:
                    restore_value_attempts(root, value_attempt_snapshot)
                    raise
                try:
                    receipt_attempt_snapshot = remove_receipt_attempts(
                        root, episode_id
                    )
                except VaultError:
                    restore_attempts(root, attempt_snapshot)
                    restore_value_attempts(root, value_attempt_snapshot)
                    raise
                rewritten_oid: str | None = None
                index_projection_snapshots: list[tuple[Path, Path, int]] = []
                try:
                    index_projection_snapshots = _snapshot_index_projection(
                        root
                    )
                    _rewrite_history(root, paths)
                    _remove_local_derivatives(root, scope)
                    rebuild_index_locked(root, incremental=False)
                    forgotten = set(original_forgotten)
                    forgotten.discard((selected, episode_id))
                    store_forgotten(root, forgotten)
                    issue_index_seal(root)
                    try:
                        for derivative_path, _derivative_bytes in derivative_snapshots:
                            derivative_path.unlink()
                    except OSError as error:
                        raise VaultError(
                            "derived record storage is unsafe"
                        ) from error
                    # Keep refs/original until the remote accepts the rewrite.
                    # Any failure from rewrite onward runs the same complete
                    # rollback, including failures before this push.
                    rewritten_oid = _ref_snapshot(root)["refs/heads/main"]
                    recovery_marker = {
                        "schema_version": 1,
                        "contract_version": PURGE_RECOVERY_CONTRACT,
                        "state": "push_pending",
                        "episode_id": episode_id,
                        "policy_version": selected,
                        "old_remote_oid": original_remote_main,
                        "new_rewritten_oid": rewritten_oid,
                    }
                    _store_purge_recovery(root, recovery_marker)
                    _push_main_with_lease(
                        root,
                        expected_remote_oid=original_remote_main,
                        new_oid=rewritten_oid,
                    )
                except Exception as error:
                    rollback_errors = _rollback_purge_state(
                        root,
                        refs=original_refs,
                        remote_main_oid=original_remote_main,
                        rewritten_remote_oid=rewritten_oid,
                        files=local_snapshots,
                        index_projection_files=index_projection_snapshots,
                        value_attempts=value_attempt_snapshot,
                        evaluation_attempts=attempt_snapshot,
                        receipt_attempts=receipt_attempt_snapshot,
                    )
                    if rollback_errors:
                        raise VaultError(
                            "purge failed and rollback incomplete: "
                            f"{error}"
                        ) from error
                    raise
                # A successful remote update is the commit point. Never undo
                # the accepted rewrite because local pruning subsequently
                # failed; retain refs/original as retry material instead.
                try:
                    _discard_index_projection_snapshots(root)
                    _cleanup_original_history(root)
                    _clear_purge_recovery(root, recovery_marker)
                except Exception as error:
                    raise VaultError(
                        "remote rewrite applied; local cleanup incomplete; "
                        "retry required"
                    ) from error
    scope["apply"] = True
    return scope


def render_forget(value: dict[str, Any]) -> str:
    return (
        f"Forgot episode {value['episode_id']} "
        f"for policy {value['policy_version']}.\n"
    )


def render_purge(value: dict[str, Any]) -> str:
    if value.get("cleanup_only") is True:
        return (
            "Recovered committed purge cleanup for episode "
            f"{value['episode_id']} under policy "
            f"{value['policy_version']}.\n"
        )
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
        "Local Value Compiler prepared records: "
        f"{value['value_compiler_prepared_record_count']}\n"
        "Local Value Compiler attempts: "
        f"{value['value_compiler_attempt_record_count']}\n"
        f"{value['limitation']}\n"
    )
