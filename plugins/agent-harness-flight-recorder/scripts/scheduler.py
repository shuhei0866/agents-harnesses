"""Install and run the user-level Flight Recorder sync retry policy."""

from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from chunk_rotation import (
    atomic_replace,
    canonical_json,
    local_device,
    safe_subdirectory,
)
from sync import sync
from vault import (
    VaultError,
    ensure_managed_gitignore,
    ensure_safe_existing_root,
    load_config,
)


LABEL = "io.agent-harness.flight-recorder.sync"
UNIT = "agent-harness-flight-recorder-sync"
STATE_PATH = Path("scheduler/state.json")
MANIFEST_PATH = Path("scheduler/install.json")
RUNTIME_PATH = (
    "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
)
COMMAND_TIMEOUT_SECONDS = 30
WAKE_INTERVAL_SECONDS = 300
HEALTHY_INTERVAL_SECONDS = 86400
RETRY_BASE_SECONDS = 300
RETRY_CAP_SECONDS = 86400
MAX_FAILURE_COUNT = 1_000_000
MANUAL_LOCK_TIMEOUT_SECONDS = 5
LOCK_RETRY_INTERVAL_SECONDS = 0.05
FAILURE_CLASSES = {"transient", "permanent"}
DIAGNOSTIC_CODES = {
    "remote_unavailable",
    "origin_mismatch",
    "rebase_conflict",
    "local_integrity_invalid",
}
NEXT_ACTION_CODES = {"retry_automatically", "repair_configuration"}
STATE_V2_FIELDS = {
    "schema_version",
    "last_attempt_at",
    "last_success_at",
    "last_error_category",
    "failure_class",
    "diagnostic_code",
    "next_action_code",
    "consecutive_failure_count",
    "next_retry_at",
}


def platform_name() -> str:
    override = os.environ.get("FLIGHT_RECORDER_SCHEDULER_PLATFORM")
    if override is not None:
        if override not in ("macos", "linux"):
            raise VaultError("scheduler platform override is invalid")
        return override
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    raise VaultError("scheduler platform is unsupported")


def _cli_path() -> Path:
    path = (Path(__file__).parent / "flight-recorder").resolve()
    if not path.is_file():
        raise VaultError("flight-recorder CLI path is invalid")
    return path


def _absolute_env(name: str, default: Path) -> Path:
    raw = os.environ.get(name)
    path = Path(raw) if raw is not None else default
    if not path.is_absolute() or "\n" in str(path) or "\0" in str(path):
        raise VaultError("scheduler configuration path is invalid")
    return path


def _targets(platform: str) -> list[Path]:
    home = _absolute_env("HOME", Path.home())
    config = _absolute_env(
        "XDG_CONFIG_HOME", home / ".config"
    )
    if platform == "macos":
        return [home / "Library" / "LaunchAgents" / f"{LABEL}.plist"]
    directory = config / "systemd" / "user"
    return [directory / f"{UNIT}.service", directory / f"{UNIT}.timer"]


def _configuration_base(platform: str) -> Path:
    home = _absolute_env("HOME", Path.home())
    if platform == "macos":
        return home
    return _absolute_env("XDG_CONFIG_HOME", home / ".config")


def _validate_directory_chain(
    platform: str, directory: Path, *, create: bool
) -> None:
    base = _configuration_base(platform)
    try:
        relative = directory.relative_to(base)
    except ValueError as error:
        raise VaultError("scheduler configuration path is invalid") from error
    current = base
    for part in (".", *relative.parts):
        if part != ".":
            current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            if not create:
                return
            current.mkdir(mode=0o700)
            metadata = current.lstat()
        except OSError as error:
            raise VaultError("scheduler configuration directory is unsafe") from error
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o022
        ):
            raise VaultError("scheduler configuration directory is unsafe")


def _runtime_path() -> str:
    test_path = os.environ.get(
        "AGENT_FLIGHT_RECORDER_TEST_SCHEDULER_RUNTIME_PATH"
    )
    if test_path is not None:
        if os.environ.get("FLIGHT_RECORDER_SCHEDULER_PLATFORM") is None:
            raise VaultError("scheduler runtime path override is test-only")
        return test_path
    return RUNTIME_PATH


def _validate_runtime_commands(runtime_path: str) -> None:
    for command in ("git", "age", "python3"):
        if shutil.which(command, path=runtime_path) is None:
            raise VaultError(f"required command is unavailable: {command}")


def _systemd_quote(value: str) -> str:
    if "\n" in value or "\r" in value or "\0" in value:
        raise VaultError("scheduler configuration value is invalid")
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("%", "%%")
    )
    if not any(
        character.isspace() or character in "\\\"'"
        for character in value
    ) and "%" not in value:
        return value
    return '"' + escaped + '"'


def _systemd_exec_quote(value: str) -> str:
    # systemd expands $VAR/${VAR} in ExecStart= even inside double quotes.
    # A doubled dollar is the documented literal form for executable paths.
    return _systemd_quote(value.replace("$", "$$"))


def _expected(root: Path, platform: str) -> dict[Path, bytes]:
    cli = _cli_path()
    runtime_path = _runtime_path()
    targets = _targets(platform)
    if platform == "macos":
        value = {
            "Label": LABEL,
            "ProgramArguments": [str(cli), "scheduler", "run"],
            "EnvironmentVariables": {
                "FLIGHT_RECORDER_STATE_DIR": str(root),
                "PATH": runtime_path,
            },
            "StartInterval": WAKE_INTERVAL_SECONDS,
            "RunAtLoad": True,
            "ProcessType": "Background",
        }
        return {
            targets[0]: plistlib.dumps(value, sort_keys=True)
        }
    service = (
        "[Unit]\n"
        "Description=Agent Harness Flight Recorder sync\n\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"Environment={_systemd_quote(f'FLIGHT_RECORDER_STATE_DIR={root}')} "
        f"{_systemd_quote(f'PATH={runtime_path}')}\n"
        f"ExecStart={_systemd_exec_quote(str(cli))} scheduler run\n"
    ).encode()
    timer = (
        "[Unit]\n"
        "Description=Wake Agent Harness Flight Recorder sync policy\n\n"
        "[Timer]\n"
        "OnCalendar=*:0/5\n"
        "Persistent=true\n\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    ).encode()
    return {targets[0]: service, targets[1]: timer}


def _safe_existing(path: Path) -> bytes | None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise VaultError("scheduler configuration is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise VaultError("scheduler configuration is unsafe")
    try:
        return path.read_bytes()
    except OSError as error:
        raise VaultError("scheduler configuration is unsafe") from error


def _run_command(
    arguments: list[str],
    *,
    allowed: tuple[int, ...] = (0,),
    capture: bool = False,
) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            shell=False,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
    except FileNotFoundError as error:
        raise VaultError("required scheduler command is unavailable") from error
    except subprocess.TimeoutExpired as error:
        raise VaultError("scheduler command timed out") from error
    if result.returncode not in allowed:
        raise VaultError("scheduler command failed")
    return result


def _command(arguments: list[str], *, allowed: tuple[int, ...] = (0,)) -> None:
    _run_command(arguments, allowed=allowed)


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _manifest_value(
    platform: str,
    expected: dict[Path, bytes],
    *,
    phase: str,
    previous_targets: dict[str, str] | None,
) -> dict[str, Any]:
    identifiers = [LABEL] if platform == "macos" else [
        f"{UNIT}.service",
        f"{UNIT}.timer",
    ]
    return {
        "schema_version": 1,
        "platform": platform,
        "manager_identifiers": identifiers,
        "phase": phase,
        "targets": {
            str(path): _digest(data) for path, data in expected.items()
        },
        "previous_targets": previous_targets,
    }


def _validate_scheduler_directory(root: Path) -> bool:
    directory = root / "scheduler"
    try:
        metadata = directory.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        raise VaultError("scheduler state directory is unsafe") from error
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise VaultError("scheduler state directory is unsafe")
    return True


def _load_manifest(root: Path) -> dict[str, Any] | None:
    if not _validate_scheduler_directory(root):
        return None
    path = root / MANIFEST_PATH
    data = _safe_existing(path)
    if data is None:
        return None
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("scheduler install manifest is invalid") from error
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schema_version",
            "platform",
            "manager_identifiers",
            "phase",
            "targets",
            "previous_targets",
        }
        or value.get("schema_version") != 1
        or value.get("platform") not in ("macos", "linux")
        or value.get("phase") not in ("installing", "active")
        or not isinstance(value.get("manager_identifiers"), list)
        or not isinstance(value.get("targets"), dict)
        or (
            value.get("previous_targets") is not None
            and not isinstance(value.get("previous_targets"), dict)
        )
    ):
        raise VaultError("scheduler install manifest is invalid")
    identifiers = (
        [LABEL]
        if value["platform"] == "macos"
        else [f"{UNIT}.service", f"{UNIT}.timer"]
    )
    if value["manager_identifiers"] != identifiers:
        raise VaultError("scheduler install manifest is invalid")
    for target_set in (value["targets"], value["previous_targets"] or {}):
        if any(
            not isinstance(path, str)
            or not Path(path).is_absolute()
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            for path, digest in target_set.items()
        ):
            raise VaultError("scheduler install manifest is invalid")
    return value


def _write_manifest(root: Path, value: dict[str, Any]) -> None:
    directory = safe_subdirectory(root, "scheduler")
    path = root / MANIFEST_PATH
    atomic_replace(path, canonical_json(value) + b"\n")
    path.chmod(0o600)
    directory.chmod(0o700)


def _manifest_target_hashes(
    manifest: dict[str, Any],
) -> dict[str, set[str]]:
    hashes = {
        path: {digest} for path, digest in manifest["targets"].items()
    }
    for path, digest in (manifest["previous_targets"] or {}).items():
        hashes.setdefault(path, set()).add(digest)
    return hashes


def _validate_manifest_scope(
    manifest: dict[str, Any],
    platform: str,
    expected: dict[Path, bytes],
) -> None:
    if (
        manifest["platform"] != platform
        or set(manifest["targets"]) != {str(path) for path in expected}
        or not set(manifest["previous_targets"] or {}).issubset(
            {str(path) for path in expected}
        )
    ):
        raise VaultError("scheduler install manifest is not for this configuration")


def _validate_owned_files(
    existing: dict[Path, bytes | None],
    manifest: dict[str, Any],
) -> None:
    allowed = _manifest_target_hashes(manifest)
    for path, data in existing.items():
        if data is not None and _digest(data) not in allowed.get(str(path), set()):
            raise VaultError("scheduler configuration is not managed by Flight Recorder")


def _manager_origins(platform: str) -> dict[str, Path]:
    if platform == "macos":
        result = _run_command(
            ["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
            allowed=(0, 3, 113),
            capture=True,
        )
        if result.returncode != 0:
            return {}
        match = re.search(r"(?m)^\s*path\s*=\s*(.+?)\s*$", result.stdout)
        if match is None:
            raise VaultError("loaded scheduler origin cannot be verified")
        raw = match.group(1).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] == '"':
            raw = raw[1:-1]
        path = Path(raw)
        if not path.is_absolute():
            raise VaultError("loaded scheduler origin is invalid")
        return {LABEL: path}

    origins: dict[str, Path] = {}
    for identifier in (f"{UNIT}.service", f"{UNIT}.timer"):
        result = _run_command(
            [
                "systemctl",
                "--user",
                "show",
                "--property=LoadState",
                "--property=FragmentPath",
                identifier,
            ],
            capture=True,
        )
        properties: dict[str, str] = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                name, value = line.split("=", 1)
                properties[name] = value
        load_state = properties.get("LoadState")
        fragment = properties.get("FragmentPath")
        if load_state == "not-found" and not fragment:
            continue
        if load_state is None or not fragment:
            raise VaultError("loaded scheduler origin cannot be verified")
        path = Path(fragment)
        if not path.is_absolute():
            raise VaultError("loaded scheduler origin is invalid")
        origins[identifier] = path
    return origins


def _validate_manager_origins(
    platform: str,
    origins: dict[str, Path],
    expected: dict[Path, bytes],
) -> None:
    paths = list(expected)
    allowed = (
        {LABEL: paths[0]}
        if platform == "macos"
        else {
            f"{UNIT}.service": paths[0],
            f"{UNIT}.timer": paths[1],
        }
    )
    if any(allowed.get(identifier) != path for identifier, path in origins.items()):
        raise VaultError("scheduler name is owned by another configuration")


@contextlib.contextmanager
def _scheduler_transaction() -> Any:
    directory = Path("/tmp") / (
        f"agent-harness-flight-recorder-{os.geteuid()}"
    )
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    except OSError as error:
        raise VaultError("scheduler transaction lock is unavailable") from error
    try:
        directory_metadata = directory.lstat()
    except OSError as error:
        raise VaultError("scheduler transaction lock is unsafe") from error
    if (
        not stat.S_ISDIR(directory_metadata.st_mode)
        or directory_metadata.st_uid != os.geteuid()
        or directory_metadata.st_mode & 0o077
    ):
        raise VaultError("scheduler transaction lock is unsafe")
    lock_path = directory / "install.lock"
    if lock_path.is_symlink():
        raise VaultError("scheduler transaction lock is unsafe")
    try:
        descriptor = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as error:
        raise VaultError("scheduler transaction lock is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("scheduler transaction lock is unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise VaultError("scheduler configuration is busy") from error
        yield
    finally:
        os.close(descriptor)


def _install(root: Path) -> None:
    ensure_safe_existing_root(root)
    ensure_managed_gitignore(root)
    platform = platform_name()
    expected = _expected(root, platform)
    _validate_runtime_commands(_runtime_path())
    for path in expected:
        _validate_directory_chain(platform, path.parent, create=True)
    existing = {path: _safe_existing(path) for path in expected}
    manifest = _load_manifest(root)
    if manifest is None:
        if any(data is not None for data in existing.values()):
            raise VaultError(
                "scheduler configuration is not managed by Flight Recorder"
            )
    else:
        _validate_manifest_scope(manifest, platform, expected)
        _validate_owned_files(existing, manifest)
    origins = _manager_origins(platform)
    _validate_manager_origins(platform, origins, expected)
    if manifest is None and origins:
        raise VaultError("scheduler name is owned by another configuration")

    previous_manifest = manifest
    previous_bytes = dict(existing)
    previous_hashes = {
        str(path): _digest(data)
        for path, data in existing.items()
        if data is not None
    } or None
    installing_manifest = _manifest_value(
        platform,
        expected,
        phase="installing",
        previous_targets=previous_hashes,
    )
    activation_attempted = False
    loaded_before = bool(origins)
    configuration_changed = any(
        existing[path] != data for path, data in expected.items()
    )
    try:
        _write_manifest(root, installing_manifest)
        for path, data in expected.items():
            if existing[path] == data:
                continue
            atomic_replace(path, data)
            path.chmod(0o600)
        if platform == "macos":
            if origins and configuration_changed:
                activation_attempted = True
                _command(
                    ["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"],
                    allowed=(0, 3, 113),
                )
            if not origins or configuration_changed:
                activation_attempted = True
                _command(
                    [
                        "launchctl",
                        "bootstrap",
                        f"gui/{os.getuid()}",
                        str(next(iter(expected))),
                    ]
                )
        else:
            _command(["systemctl", "--user", "daemon-reload"])
            activation_attempted = True
            _command(
                ["systemctl", "--user", "enable", "--now", f"{UNIT}.timer"]
            )
            if loaded_before and configuration_changed:
                _command(
                    ["systemctl", "--user", "restart", f"{UNIT}.timer"]
                )
        _write_manifest(
            root,
            _manifest_value(
                platform,
                expected,
                phase="active",
                previous_targets=None,
            ),
        )
    except (OSError, VaultError) as error:
        if activation_attempted:
            try:
                rollback_origins = _manager_origins(platform)
                _validate_manager_origins(
                    platform, rollback_origins, expected
                )
                if platform == "macos":
                    if rollback_origins:
                        _command(
                            [
                                "launchctl",
                                "bootout",
                                f"gui/{os.getuid()}/{LABEL}",
                            ],
                            allowed=(0, 3, 113),
                        )
                elif rollback_origins:
                    _command(
                        [
                            "systemctl",
                            "--user",
                            "disable",
                            "--now",
                            f"{UNIT}.timer",
                        ],
                        allowed=(0, 1, 5),
                    )
            except VaultError:
                pass
        for path, data in previous_bytes.items():
            try:
                if data is None:
                    path.unlink(missing_ok=True)
                else:
                    atomic_replace(path, data)
                    path.chmod(0o600)
            except OSError:
                pass
        try:
            manifest_path = root / MANIFEST_PATH
            if previous_manifest is None:
                manifest_path.unlink(missing_ok=True)
            else:
                _write_manifest(root, previous_manifest)
        except (OSError, VaultError):
            pass
        if platform == "linux":
            try:
                _command(["systemctl", "--user", "daemon-reload"])
                if loaded_before:
                    _command(
                        [
                            "systemctl",
                            "--user",
                            "enable",
                            "--now",
                            f"{UNIT}.timer",
                        ]
                    )
                    _command(
                        ["systemctl", "--user", "restart", f"{UNIT}.timer"]
                    )
            except VaultError:
                pass
        elif loaded_before:
            try:
                _command(
                    [
                        "launchctl",
                        "bootstrap",
                        f"gui/{os.getuid()}",
                        str(next(iter(expected))),
                    ]
                )
            except VaultError:
                pass
        if isinstance(error, OSError):
            raise VaultError("scheduler installation failed") from error
        raise


def _uninstall(root: Path) -> None:
    try:
        ensure_safe_existing_root(root)
        platform = platform_name()
        expected = _expected(root, platform)
        for path in expected:
            _validate_directory_chain(platform, path.parent, create=False)
        existing = {path: _safe_existing(path) for path in expected}
        manifest = _load_manifest(root)
        if manifest is None:
            if any(data is not None for data in existing.values()):
                raise VaultError(
                    "scheduler configuration is not managed by Flight Recorder"
                )
            return
        _validate_manifest_scope(manifest, platform, expected)
        _validate_owned_files(existing, manifest)
        origins = _manager_origins(platform)
        _validate_manager_origins(platform, origins, expected)
        if platform == "macos":
            if origins:
                _command(
                    ["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"],
                    allowed=(0, 3, 113),
                )
        else:
            _command(
                ["systemctl", "--user", "disable", "--now", f"{UNIT}.timer"],
                allowed=(0, 1, 5),
            )
        for path in expected:
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        (root / MANIFEST_PATH).unlink(missing_ok=True)
        if platform == "linux":
            _command(["systemctl", "--user", "daemon-reload"])
    except OSError as error:
        raise VaultError("scheduler uninstall failed") from error


def install(root: Path) -> None:
    ensure_safe_existing_root(root)
    with _scheduler_transaction():
        _install(root)


def uninstall(root: Path) -> None:
    ensure_safe_existing_root(root)
    with _scheduler_transaction():
        _uninstall(root)


def _format_time(value: dt.datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise VaultError("scheduler timestamp is invalid")
    return (
        value.astimezone(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def _parse_time(value: str) -> dt.datetime:
    if not isinstance(value, str):
        raise VaultError("scheduler timestamp is invalid")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise VaultError("scheduler timestamp is invalid") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise VaultError("scheduler timestamp is invalid")
    return parsed.astimezone(dt.timezone.utc)


def _now() -> dt.datetime:
    override = os.environ.get("AGENT_FLIGHT_RECORDER_TEST_NOW")
    if override is not None:
        if os.environ.get("FLIGHT_RECORDER_SCHEDULER_PLATFORM") is None:
            raise VaultError("scheduler time override is test-only")
        return _parse_time(override).replace(microsecond=0)
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def retry_delay_seconds(seed: str, failure_count: int) -> int:
    if (
        not isinstance(seed, str)
        or not seed
        or isinstance(failure_count, bool)
        or not isinstance(failure_count, int)
        or failure_count < 1
    ):
        raise ValueError("retry policy input is invalid")
    exponent = min(failure_count - 1, 63)
    nominal = min(RETRY_CAP_SECONDS, RETRY_BASE_SECONDS * (2**exponent))
    lower = nominal // 2
    span = nominal - lower
    digest = hashlib.sha256(
        f"{seed}:{failure_count}".encode("utf-8")
    ).digest()
    return lower + int.from_bytes(digest[:8], "big") % (span + 1)


def _state_after_failure(
    previous: dict[str, Any] | None,
    *,
    now: dt.datetime,
    failure_class: str,
    diagnostic_code: str,
    next_action_code: str,
    retry_seed: str,
) -> dict[str, Any]:
    if (
        failure_class not in FAILURE_CLASSES
        or diagnostic_code not in DIAGNOSTIC_CODES
        or next_action_code not in NEXT_ACTION_CODES
    ):
        raise VaultError("scheduler failure classification is invalid")
    previous_count = (
        previous.get("consecutive_failure_count", 0) if previous else 0
    )
    if (
        isinstance(previous_count, bool)
        or not isinstance(previous_count, int)
        or previous_count < 0
        or previous_count >= MAX_FAILURE_COUNT
    ):
        raise VaultError("scheduler state is invalid")
    count = previous_count + 1
    next_retry = None
    if failure_class == "transient":
        delay = retry_delay_seconds(retry_seed, count)
        next_retry = _format_time(now + dt.timedelta(seconds=delay))
    category = (
        "remote"
        if diagnostic_code == "remote_unavailable"
        else "rebase"
        if diagnostic_code == "rebase_conflict"
        else "integrity"
    )
    return {
        "schema_version": 2,
        "last_attempt_at": _format_time(now),
        "last_success_at": (
            previous.get("last_success_at") if previous else None
        ),
        "last_error_category": category,
        "failure_class": failure_class,
        "diagnostic_code": diagnostic_code,
        "next_action_code": next_action_code,
        "consecutive_failure_count": count,
        "next_retry_at": next_retry,
    }


def _state_after_success(
    previous: dict[str, Any] | None, *, now: dt.datetime
) -> dict[str, Any]:
    timestamp = _format_time(now)
    return {
        "schema_version": 2,
        "last_attempt_at": timestamp,
        "last_success_at": timestamp,
        "last_error_category": None,
        "failure_class": None,
        "diagnostic_code": None,
        "next_action_code": None,
        "consecutive_failure_count": 0,
        "next_retry_at": None,
    }


def _retry_due(state: dict[str, Any], now: dt.datetime) -> bool:
    failure_class = state.get("failure_class")
    if failure_class == "permanent":
        return False
    if failure_class != "transient":
        return True
    next_retry = state.get("next_retry_at")
    return next_retry is None or now >= _parse_time(next_retry)


def _scheduler_due(
    state: dict[str, Any] | None, now: dt.datetime
) -> bool:
    if state is None:
        return True
    if state.get("failure_class") is not None:
        return _retry_due(state, now)
    last_success = state.get("last_success_at")
    if last_success is None:
        return True
    return now >= _parse_time(last_success) + dt.timedelta(
        seconds=HEALTHY_INTERVAL_SECONDS
    )


def _retry_seed(root: Path) -> str:
    try:
        config = load_config(root)
        device_id, _ = local_device(config, root)
        vault_id = config.get("vault_id")
        if isinstance(vault_id, str):
            return f"{vault_id}:{device_id}"
    except VaultError:
        pass
    return hashlib.sha256(str(root).encode("utf-8")).hexdigest()


def _write_state(root: Path, value: dict[str, Any]) -> None:
    directory = safe_subdirectory(root, "scheduler")
    path = root / STATE_PATH
    atomic_replace(path, canonical_json(value) + b"\n")
    path.chmod(0o600)
    directory.chmod(0o700)


def _load_state(root: Path) -> dict[str, Any] | None:
    if not _validate_scheduler_directory(root):
        return None
    path = root / STATE_PATH
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise VaultError("scheduler state is unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid != os.geteuid()
        or metadata.st_mode & 0o077
    ):
        raise VaultError("scheduler state is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("scheduler state is invalid") from error
    if not isinstance(value, dict):
        raise VaultError("scheduler state is invalid")
    if value.get("schema_version") == 1:
        if set(value) != {
            "schema_version",
            "last_attempt_at",
            "last_success_at",
            "last_error_category",
        } or any(
            field is not None and not isinstance(field, str)
            for field in (
                value.get("last_attempt_at"),
                value.get("last_success_at"),
                value.get("last_error_category"),
            )
        ):
            raise VaultError("scheduler state is invalid")
        for field in ("last_attempt_at", "last_success_at"):
            timestamp = value.get(field)
            if timestamp is not None:
                _parse_time(timestamp)
        category = value.get("last_error_category")
        if category not in (None, "remote", "rebase", "integrity", "sync"):
            raise VaultError("scheduler state is invalid")
        # "sync" was the pre-classification generic category. It is not local
        # proof, so retry once and derive the current classification.
        transient = category in ("remote", "rebase", "sync")
        return {
            "schema_version": 2,
            "last_attempt_at": value.get("last_attempt_at"),
            "last_success_at": value.get("last_success_at"),
            "last_error_category": (
                "remote"
                if transient
                else "integrity"
                if category is not None
                else None
            ),
            "failure_class": (
                "transient"
                if transient
                else "permanent"
                if category is not None
                else None
            ),
            "diagnostic_code": (
                "remote_unavailable"
                if transient
                else "local_integrity_invalid"
                if category is not None
                else None
            ),
            "next_action_code": (
                "retry_automatically"
                if transient
                else "repair_configuration"
                if category is not None
                else None
            ),
            "consecutive_failure_count": 1 if category is not None else 0,
            "next_retry_at": None,
        }
    if value.get("schema_version") != 2 or set(value) != STATE_V2_FIELDS:
        raise VaultError("scheduler state is invalid")
    for field in (
        "last_attempt_at",
        "last_success_at",
        "last_error_category",
        "failure_class",
        "diagnostic_code",
        "next_action_code",
        "next_retry_at",
    ):
        if value.get(field) is not None and not isinstance(value[field], str):
            raise VaultError("scheduler state is invalid")
    for field in ("last_attempt_at", "last_success_at", "next_retry_at"):
        if value.get(field) is not None:
            _parse_time(value[field])
    count = value.get("consecutive_failure_count")
    if (
        isinstance(count, bool)
        or not isinstance(count, int)
        or count < 0
        or count >= MAX_FAILURE_COUNT
    ):
        raise VaultError("scheduler state is invalid")
    failure_class = value.get("failure_class")
    diagnostic = value.get("diagnostic_code")
    action = value.get("next_action_code")
    retry = value.get("next_retry_at")
    category = value.get("last_error_category")
    if category not in (None, "remote", "rebase", "integrity"):
        raise VaultError("scheduler state is invalid")
    if failure_class is None:
        if (
            diagnostic is not None
            or action is not None
            or retry is not None
            or count != 0
            or value.get("last_error_category") is not None
        ):
            raise VaultError("scheduler state is invalid")
    elif (
        failure_class not in FAILURE_CLASSES
        or diagnostic not in DIAGNOSTIC_CODES
        or action not in NEXT_ACTION_CODES
        or count < 1
    ):
        raise VaultError("scheduler state is invalid")
    elif failure_class == "transient" and (
        diagnostic != "remote_unavailable"
        or action != "retry_automatically"
        or category != "remote"
    ):
        raise VaultError("scheduler state is invalid")
    elif failure_class == "permanent" and (
        retry is not None or action != "repair_configuration"
    ):
        raise VaultError("scheduler state is invalid")
    elif failure_class == "permanent":
        expected_category = (
            "rebase" if diagnostic == "rebase_conflict" else "integrity"
        )
        if category != expected_category:
            raise VaultError("scheduler state is invalid")
    if failure_class is not None and value.get("last_attempt_at") is None:
        raise VaultError("scheduler state is invalid")
    if retry is not None:
        attempt_time = _parse_time(value["last_attempt_at"])
        retry_time = _parse_time(retry)
        if (
            retry_time < attempt_time
            or retry_time
            > attempt_time + dt.timedelta(seconds=RETRY_CAP_SECONDS)
        ):
            raise VaultError("scheduler state is invalid")
    return value


@contextlib.contextmanager
def _run_lock(root: Path, *, blocking: bool) -> Any:
    directory = safe_subdirectory(root, "scheduler")
    lock_path = directory / "run.lock"
    if lock_path.is_symlink():
        raise VaultError("scheduler run lock is unsafe")
    try:
        descriptor = os.open(
            lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
        )
    except OSError as error:
        raise VaultError("scheduler run lock is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1
            or metadata.st_mode & 0o077
        ):
            raise VaultError("scheduler run lock is unsafe")
        deadline = time.monotonic() + MANUAL_LOCK_TIMEOUT_SECONDS
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not blocking:
                    yield False
                    return
                if time.monotonic() >= deadline:
                    raise VaultError("synchronization is already running")
                time.sleep(LOCK_RETRY_INTERVAL_SECONDS)
            except OSError as error:
                raise VaultError("scheduler run lock is unavailable") from error
        yield True
    finally:
        os.close(descriptor)


def _failure_state(
    root: Path,
    previous: dict[str, Any] | None,
    *,
    now: dt.datetime,
    error: VaultError,
) -> dict[str, Any]:
    failure_class = getattr(error, "failure_class", None)
    diagnostic_code = getattr(error, "diagnostic_code", None)
    next_action_code = getattr(error, "next_action_code", None)
    if (
        failure_class not in FAILURE_CLASSES
        or diagnostic_code not in DIAGNOSTIC_CODES
        or next_action_code not in NEXT_ACTION_CODES
    ):
        # Current remote operations are wrapped in SyncFailure by sync.py.
        # An unclassified error therefore has no current proof of transience;
        # never let a stale pending marker override the current failure.
        failure_class = "permanent"
        diagnostic_code = "local_integrity_invalid"
        next_action_code = "repair_configuration"
    return _state_after_failure(
        previous,
        now=now,
        failure_class=failure_class,
        diagnostic_code=diagnostic_code,
        next_action_code=next_action_code,
        retry_seed=_retry_seed(root),
    )


def run(root: Path) -> None:
    ensure_safe_existing_root(root)
    ensure_managed_gitignore(root)
    should_evaluate = False
    with _run_lock(root, blocking=False) as acquired:
        if not acquired:
            return
        previous = _load_state(root)
        now = _now()
        if not _scheduler_due(previous, now):
            return
        try:
            sync(root)
        except VaultError as error:
            _write_state(
                root,
                _failure_state(root, previous, now=now, error=error),
            )
            return
        _write_state(root, _state_after_success(previous, now=now))
        should_evaluate = True
    config_path = root / "auto-evaluation/config.json"
    if should_evaluate and (
        config_path.exists() or config_path.is_symlink()
    ):
        try:
            from background_evaluation import (
                record_failure,
                run as run_evaluation,
            )

            run_evaluation(root)
        except VaultError:
            # Automatic evaluation is deliberately outside sync health.
            # Preserve a finite local diagnostic when configuration itself
            # fails before the evaluator can write its normal status.
            try:
                record_failure(root, "configuration_invalid")
            except VaultError:
                pass
    receipt_config_path = root / "receipt-automation/config.json"
    if should_evaluate and (
        receipt_config_path.exists() or receipt_config_path.is_symlink()
    ):
        try:
            from receipt_automation import (
                record_failure as record_receipt_failure,
                run as run_receipt_automation,
            )

            run_receipt_automation(root)
        except VaultError:
            # Semantic receipt automation is also outside sync health. Its
            # worker writes finite diagnostics for evaluator failures.
            try:
                record_receipt_failure(root, "configuration_invalid")
            except VaultError:
                pass


def manual_sync(root: Path) -> None:
    """Run an explicit sync outside backoff and reconcile either outcome."""
    ensure_safe_existing_root(root)
    ensure_managed_gitignore(root)
    with _run_lock(root, blocking=True) as acquired:
        if not acquired:  # pragma: no cover - blocking acquisition cannot skip.
            raise VaultError("scheduler run lock is unavailable")
        previous = _load_state(root)
        now = _now()
        try:
            sync(root)
        except VaultError as error:
            _write_state(
                root,
                _failure_state(root, previous, now=now, error=error),
            )
            raise
        _write_state(root, _state_after_success(previous, now=now))


def status(root: Path) -> dict[str, Any]:
    platform = platform_name()
    expected = _expected(root, platform)
    try:
        for path in expected:
            _validate_directory_chain(platform, path.parent, create=False)
        existing = {path: _safe_existing(path) for path in expected}
        present = [value is not None for value in existing.values()]
        if any(present) and not all(present):
            raise VaultError("scheduler configuration is incomplete")
        manifest = _load_manifest(root)
        if manifest is None:
            if any(present):
                raise VaultError("scheduler configuration provenance is missing")
            configured = False
        else:
            _validate_manifest_scope(manifest, platform, expected)
            _validate_owned_files(existing, manifest)
            if (
                manifest["phase"] != "active"
                or not all(
                    existing[path] == data for path, data in expected.items()
                )
            ):
                raise VaultError("scheduler configuration is incomplete")
            origins = _manager_origins(platform)
            _validate_manager_origins(platform, origins, expected)
            if len(origins) != (1 if platform == "macos" else 2):
                raise VaultError("scheduler is not loaded")
            configured = True
        state = _load_state(root)
        error = state.get("last_error_category") if state else None
        health = (
            "unconfigured"
            if not configured
            else "error"
            if error is not None
            else "healthy"
            if state and state.get("last_success_at")
            else "idle"
        )
        return {
            "state": health,
            "configured": configured,
            "platform": platform,
            "last_attempt_at": (
                state.get("last_attempt_at") if state else None
            ),
            "last_success_at": (
                state.get("last_success_at") if state else None
            ),
            "last_error_category": error,
            "failure_class": (
                state.get("failure_class") if state else None
            ),
            "diagnostic_code": (
                state.get("diagnostic_code") if state else None
            ),
            "next_action_code": (
                state.get("next_action_code") if state else None
            ),
            "consecutive_failure_count": (
                state.get("consecutive_failure_count") if state else 0
            ),
            "next_retry_at": (
                state.get("next_retry_at") if state else None
            ),
        }
    except VaultError:
        return {
            "state": "invalid",
            "configured": None,
            "platform": platform,
            "last_attempt_at": None,
            "last_success_at": None,
            "last_error_category": None,
            "failure_class": None,
            "diagnostic_code": None,
            "next_action_code": None,
            "consecutive_failure_count": None,
            "next_retry_at": None,
        }
