"""Local owner-held retention markers for Flight Recorder episodes."""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path

from chunk_rotation import atomic_replace, canonical_json, safe_subdirectory
from vault import VaultError


FORGET_PATH = Path("index/forgotten-episodes.json")


def load_forgotten(root: Path) -> set[tuple[str, str]]:
    path = root / FORGET_PATH
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return set()
    except OSError as error:
        raise VaultError("forgotten episode state is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
    ):
        raise VaultError("forgotten episode state is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("forgotten episode state is invalid") from error
    if (
        not isinstance(value, dict)
        or set(value) != {"schema_version", "episodes"}
        or value["schema_version"] != 1
        or not isinstance(value["episodes"], list)
    ):
        raise VaultError("forgotten episode state is invalid")
    entries: set[tuple[str, str]] = set()
    for item in value["episodes"]:
        if (
            not isinstance(item, dict)
            or set(item) != {"episode_id", "policy_version"}
            or not isinstance(item["episode_id"], str)
            or not isinstance(item["policy_version"], str)
        ):
            raise VaultError("forgotten episode state is invalid")
        entries.add((item["policy_version"], item["episode_id"]))
    if len(entries) != len(value["episodes"]):
        raise VaultError("forgotten episode state is invalid")
    return entries


def store_forgotten(root: Path, entries: set[tuple[str, str]]) -> None:
    directory = safe_subdirectory(root, "index")
    path = root / FORGET_PATH
    value = {
        "schema_version": 1,
        "episodes": [
            {"policy_version": policy, "episode_id": episode}
            for policy, episode in sorted(entries)
        ],
    }
    atomic_replace(path, canonical_json(value) + b"\n")
    path.chmod(0o600)
    directory.chmod(0o700)
