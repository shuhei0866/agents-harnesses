#!/usr/bin/env python3
"""Manage the local Flight Recorder vault and its age recipients."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from urllib.parse import urlsplit


RECIPIENT_RE = re.compile(r"^age1[023456789acdefghjklmnpqrstuvwxyz]{20,}$")
CONFIG_NAME = "vault.json"
ENVELOPE_PATH = Path("keys/correlation-key.age")
DEVICE_IDENTITY_PATH = Path("keys/device.agekey")
HASH_KEY_PATH = Path("hash.key")
INIT_MARKER_PATH = Path(".init-in-progress")
CONFIG_PATHS = {
    "correlation_key_envelope": str(ENVELOPE_PATH),
    "device_identity": str(DEVICE_IDENTITY_PATH),
}
CONFIG_FIELDS = {
    "schema_version",
    "vault_id",
    "remote",
    "devices",
    "recovery_recipients",
    "recipient_state_hmac",
    "paths",
    "git_sync_allowlist",
}
GIT_SYNC_ALLOWLIST = [
    ".gitignore",
    CONFIG_NAME,
    str(ENVELOPE_PATH),
    "devices/**/*.jsonl.age",
]
LEGACY_GIT_SYNC_ALLOWLIST = [".gitignore", CONFIG_NAME, str(ENVELOPE_PATH)]
PRE_SCHEDULER_GITIGNORE = """# Local-only Flight Recorder state
/hash.key
/events.jsonl
/keys/*.agekey
/inbox/
/queue/
/quarantine/
/devices/**/*
!/devices/**/
!/devices/**/*.jsonl.age
/chunks/
/index/
/cache/
/tmp/
/.init-in-progress
/*.lock
/*.tmp
"""
GITIGNORE = PRE_SCHEDULER_GITIGNORE.replace(
    "/tmp/\n", "/tmp/\n/scheduler/\n"
)
assert "/scheduler/\n" in GITIGNORE
PRE_EVALUATION_GITIGNORE = GITIGNORE
GITIGNORE = PRE_EVALUATION_GITIGNORE.replace(
    "/scheduler/\n", "/scheduler/\n/evaluations/\n"
)
assert "/evaluations/\n" in GITIGNORE
PRE_AUTO_EVALUATION_GITIGNORE = GITIGNORE
GITIGNORE = PRE_AUTO_EVALUATION_GITIGNORE.replace(
    "/evaluations/\n", "/evaluations/\n/auto-evaluation/\n"
)
assert "/auto-evaluation/\n" in GITIGNORE
PRE_SEMANTIC_RECEIPT_GITIGNORE = GITIGNORE
GITIGNORE = PRE_SEMANTIC_RECEIPT_GITIGNORE.replace(
    "/auto-evaluation/\n",
    "/auto-evaluation/\n/session-sources/\n/semantic-receipts/\n",
)
assert "/session-sources/\n" in GITIGNORE
assert "/semantic-receipts/\n" in GITIGNORE
PRE_RECEIPT_AUTOMATION_GITIGNORE = GITIGNORE
GITIGNORE = PRE_RECEIPT_AUTOMATION_GITIGNORE.replace(
    "/semantic-receipts/\n",
    "/semantic-receipts/\n/receipt-automation/\n",
)
assert "/receipt-automation/\n" in GITIGNORE
LEGACY_GITIGNORE = """# Local-only Flight Recorder state
/hash.key
/events.jsonl
/keys/*.agekey
/inbox/
/chunks/
/index/
/cache/
/tmp/
/.init-in-progress
/*.lock
/*.tmp
"""


class VaultError(RuntimeError):
    pass


def state_root() -> Path:
    override = os.environ.get("FLIGHT_RECORDER_STATE_DIR")
    if override:
        path = Path(override).expanduser()
        if not path.is_absolute():
            raise VaultError("FLIGHT_RECORDER_STATE_DIR must be absolute")
        return path
    state_home = os.environ.get("XDG_STATE_HOME")
    if state_home:
        return (
            Path(state_home).expanduser().absolute()
            / "agent-harness-flight-recorder"
        )
    home = os.environ.get("HOME")
    if not home:
        raise VaultError("HOME or FLIGHT_RECORDER_STATE_DIR is required")
    return (
        Path(home).expanduser().absolute()
        / ".local/state/agent-harness-flight-recorder"
    )


@contextlib.contextmanager
def vault_lock(root: Path):
    """Serialize state transitions without placing a lock inside the Git tree."""
    root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = root.parent / f".{root.name}.lock"
    flags = os.O_CREAT | os.O_RDWR
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise VaultError("vault lock is unavailable or unsafe") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or metadata.st_uid != os.geteuid()
        ):
            raise VaultError("vault lock is unsafe")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def validate_recipient(recipient: str) -> None:
    if not RECIPIENT_RE.fullmatch(recipient):
        raise VaultError("recipient is not a valid native age recipient")


def validate_remote(remote: str) -> None:
    if not remote.strip() or any(char in remote for char in "\r\n\0"):
        raise VaultError("remote must be a non-empty Git URL")
    parsed = urlsplit(remote)
    if parsed.scheme and (parsed.username is not None or parsed.password is not None):
        raise VaultError("remote URLs must not contain credentials")


def run(command: list[str], *, stdin: bytes | None = None) -> bytes:
    try:
        completed = subprocess.run(
            command,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            shell=False,
        )
    except FileNotFoundError as error:
        raise VaultError(f"required command is unavailable: {command[0]}") from error
    if completed.returncode != 0:
        # age may include sensitive path details in stderr. Keep the CLI error generic.
        raise VaultError(f"{command[0]} failed")
    return completed.stdout


def write_exclusive(path: Path, data: bytes, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short write")
            view = view[written:]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def json_bytes(value: dict[str, object]) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def canonical_recipient_state(config: dict[str, object]) -> bytes:
    value = {
        "vault_id": config["vault_id"],
        "devices": config["devices"],
        "recovery_recipients": config["recovery_recipients"],
    }
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def recipient_state_hmac(config: dict[str, object], key: bytes) -> str:
    return hmac.new(key, canonical_recipient_state(config), hashlib.sha256).hexdigest()


def set_recipient_state_hmac(config: dict[str, object], key: bytes) -> None:
    config["recipient_state_hmac"] = recipient_state_hmac(config, key)


def verify_recipient_state_hmac(config: dict[str, object], key: bytes) -> None:
    expected = config["recipient_state_hmac"]
    if not isinstance(expected, str) or not hmac.compare_digest(
        expected, recipient_state_hmac(config, key)
    ):
        raise VaultError("vault recipient metadata authentication failed")


def all_recipients(config: dict[str, object]) -> list[str]:
    devices = config["devices"]
    recovery = config["recovery_recipients"]
    assert isinstance(devices, list)
    assert isinstance(recovery, list)
    return [device["recipient"] for device in devices] + list(recovery)


def derive_recipient(identity: Path) -> str:
    value = run(["age-keygen", "-y", str(identity)]).decode("utf-8").strip()
    validate_recipient(value)
    return value


def encrypt(key: bytes, recipients: list[str], output: Path) -> None:
    command = ["age", "-o", str(output)]
    for recipient in recipients:
        command.extend(["-r", recipient])
    run(command, stdin=key)
    if not output.is_file() or output.is_symlink():
        raise VaultError("age did not create an envelope")
    os.chmod(output, 0o600)


def decrypt(envelope: Path, identity: Path) -> bytes:
    plaintext = run(["age", "-d", "-i", str(identity), str(envelope)])
    if len(plaintext) != 32:
        raise VaultError("correlation key has an invalid length")
    return plaintext


def load_config(root: Path) -> dict[str, object]:
    path = root / CONFIG_NAME
    if path.is_symlink() or not path.is_file():
        raise VaultError("vault configuration is missing or unsafe")
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("vault configuration is invalid") from error
    if (
        not isinstance(config, dict)
        or set(config) != CONFIG_FIELDS
        or config.get("schema_version") != 1
    ):
        raise VaultError("unsupported vault configuration")
    try:
        uuid.UUID(config["vault_id"])
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        raise VaultError("vault ID is invalid") from error
    remote = config.get("remote")
    if not isinstance(remote, str):
        raise VaultError("vault remote is invalid")
    validate_remote(remote)
    devices = config.get("devices")
    recovery = config.get("recovery_recipients")
    if not isinstance(devices, list) or not devices:
        raise VaultError("vault device registry is invalid")
    device_ids: list[str] = []
    device_recipients: list[str] = []
    for device in devices:
        if not isinstance(device, dict) or set(device) != {"device_id", "recipient"}:
            raise VaultError("vault device registry is invalid")
        try:
            uuid.UUID(device["device_id"])
        except (TypeError, ValueError, AttributeError) as error:
            raise VaultError("vault device ID is invalid") from error
        recipient = device["recipient"]
        if not isinstance(recipient, str):
            raise VaultError("vault device recipient is invalid")
        validate_recipient(recipient)
        device_ids.append(device["device_id"])
        device_recipients.append(recipient)
    if len(set(device_ids)) != len(device_ids):
        raise VaultError("vault device IDs must be unique")
    if not isinstance(recovery, list) or not recovery:
        raise VaultError("vault recovery recipients are invalid")
    for recipient in recovery:
        if not isinstance(recipient, str):
            raise VaultError("vault recovery recipient is invalid")
        validate_recipient(recipient)
    recipients = device_recipients + recovery
    if len(set(recipients)) != len(recipients):
        raise VaultError("vault recipients must be unique")
    if config.get("paths") != CONFIG_PATHS:
        raise VaultError("vault paths are invalid")
    if config.get("git_sync_allowlist") not in (
        GIT_SYNC_ALLOWLIST,
        LEGACY_GIT_SYNC_ALLOWLIST,
    ):
        raise VaultError("vault Git allowlist is invalid")
    mac = config.get("recipient_state_hmac")
    if not isinstance(mac, str) or not re.fullmatch(r"[0-9a-f]{64}", mac):
        raise VaultError("vault recipient metadata authenticator is invalid")
    return config


def ensure_safe_existing_root(root: Path) -> None:
    if root.is_symlink():
        raise VaultError("vault root must not be a symlink")
    if not root.exists():
        return
    if not root.is_dir():
        raise VaultError("vault root must be a directory")
    keys_dir = root / "keys"
    if keys_dir.is_symlink():
        raise VaultError("vault keys directory must not be a symlink")
    for relative in (CONFIG_NAME, ENVELOPE_PATH, DEVICE_IDENTITY_PATH):
        candidate = root / relative
        if candidate.is_symlink():
            raise VaultError("vault contains an unsafe symlink")


def ensure_managed_gitignore(root: Path) -> None:
    path = root / ".gitignore"
    try:
        metadata = path.lstat()
    except OSError as error:
        raise VaultError("vault Git ignore file is missing or unsafe") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or metadata.st_mode & 0o022
    ):
        raise VaultError("vault Git ignore file is unsafe")
    try:
        contents = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise VaultError("vault Git ignore file is unsafe") from error
    if contents in (
        LEGACY_GITIGNORE,
        PRE_SCHEDULER_GITIGNORE,
        PRE_EVALUATION_GITIGNORE,
        PRE_AUTO_EVALUATION_GITIGNORE,
        PRE_SEMANTIC_RECEIPT_GITIGNORE,
    ):
        atomic_replace(path, GITIGNORE.encode("utf-8"))
    elif contents != GITIGNORE:
        raise VaultError("vault Git ignore file is not managed by this version")


def recover_interrupted_init(root: Path) -> None:
    marker = root / INIT_MARKER_PATH
    if not marker.exists():
        return
    if marker.is_symlink() or not marker.is_file():
        raise VaultError("vault initialization marker is unsafe")
    try:
        state = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VaultError("vault initialization marker is invalid") from error
    if not isinstance(state, dict) or not isinstance(
        state.get("created_hash_key"), bool
    ):
        raise VaultError("vault initialization marker is invalid")
    for relative in (
        DEVICE_IDENTITY_PATH,
        ENVELOPE_PATH,
        Path(CONFIG_NAME),
        Path(".gitignore"),
    ):
        candidate = root / relative
        if candidate.is_symlink():
            raise VaultError("interrupted vault contains an unsafe symlink")
        if candidate.is_file():
            candidate.unlink()
    if state["created_hash_key"]:
        candidate = root / HASH_KEY_PATH
        if candidate.is_symlink():
            raise VaultError("interrupted vault contains an unsafe key")
        if candidate.is_file():
            candidate.unlink()
    keys_dir = root / "keys"
    if keys_dir.is_dir():
        try:
            keys_dir.rmdir()
        except OSError as error:
            raise VaultError("interrupted vault needs manual repair") from error
    marker.unlink()
    fsync_directory(root)


def existing_init_is_noop(root: Path, remote: str, recovery: str) -> bool:
    config_path = root / CONFIG_NAME
    if not config_path.exists():
        return False
    config = load_config(root)
    if config.get("remote") != remote or recovery not in config["recovery_recipients"]:
        raise VaultError("vault is already initialized with different arguments")
    required = (root / DEVICE_IDENTITY_PATH, root / ENVELOPE_PATH, root / HASH_KEY_PATH)
    if not all(path.is_file() and not path.is_symlink() for path in required):
        raise VaultError("vault is only partially initialized")
    key = decrypt(root / ENVELOPE_PATH, root / DEVICE_IDENTITY_PATH)
    verify_recipient_state_hmac(config, key)
    materialize_local_key(root, key)
    os.chmod(root, 0o700)
    os.chmod(root / "keys", 0o700)
    os.chmod(root / DEVICE_IDENTITY_PATH, 0o600)
    os.chmod(root / HASH_KEY_PATH, 0o600)
    return True


def init_vault_locked(root: Path, remote: str, recovery: str) -> None:
    ensure_safe_existing_root(root)
    if root.exists():
        recover_interrupted_init(root)
        ensure_safe_existing_root(root)
    if existing_init_is_noop(root, remote, recovery):
        return

    if root.exists():
        unexpected = [
            item
            for item in root.iterdir()
            if item.name not in {"events.jsonl", "hash.key", "inbox"}
        ]
        if unexpected:
            raise VaultError("refusing to initialize a non-empty vault directory")
        inbox = root / "inbox"
        if inbox.exists():
            if inbox.is_symlink() or not inbox.is_dir():
                raise VaultError("existing recorder inbox is unsafe")
            if any(
                item.name not in {"events.jsonl", "events.lock"}
                or item.is_symlink()
                or not item.is_file()
                for item in inbox.iterdir()
            ):
                raise VaultError("existing recorder inbox is unsafe")
        existing_key = root / HASH_KEY_PATH
        if existing_key.exists() and (
            existing_key.is_symlink()
            or not existing_key.is_file()
            or len(existing_key.read_bytes()) != 32
        ):
            raise VaultError("existing correlation key is invalid")

    root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    stage = Path(tempfile.mkdtemp(prefix=f".{root.name}.init-", dir=root.parent))
    os.chmod(stage, 0o700)
    committed: list[Path] = []
    marker = root / INIT_MARKER_PATH
    try:
        keys = stage / "keys"
        keys.mkdir(mode=0o700)
        identity = keys / "device.agekey"
        run(["age-keygen", "-o", str(identity)])
        if identity.is_symlink() or not identity.is_file():
            raise VaultError("age-keygen did not create an identity")
        os.chmod(identity, 0o600)
        device_recipient = derive_recipient(identity)

        current_key = root / HASH_KEY_PATH
        if current_key.is_file():
            key = current_key.read_bytes()
        else:
            # Avoid NUL and LF so the 32-byte key also survives shell-oriented
            # recovery checks. Rejection sampling retains essentially all of the
            # entropy of a uniformly random 256-bit key.
            while True:
                key = secrets.token_bytes(32)
                if b"\0" not in key and b"\n" not in key:
                    break
        staged_key = stage / HASH_KEY_PATH
        write_exclusive(staged_key, key)
        recipients = [device_recipient, recovery]
        encrypt(key, recipients, stage / ENVELOPE_PATH)

        vault_id = str(uuid.uuid4())
        device_id = str(uuid.uuid4())
        config: dict[str, object] = {
            "schema_version": 1,
            "vault_id": vault_id,
            "remote": remote,
            "devices": [{"device_id": device_id, "recipient": device_recipient}],
            "recovery_recipients": [recovery],
            "paths": CONFIG_PATHS,
            "git_sync_allowlist": GIT_SYNC_ALLOWLIST,
        }
        set_recipient_state_hmac(config, key)
        write_exclusive(stage / CONFIG_NAME, json_bytes(config))
        write_exclusive(stage / ".gitignore", GITIGNORE.encode("utf-8"))

        if not root.exists():
            os.replace(stage, root)
            os.chmod(root, 0o700)
            os.chmod(root / "keys", 0o700)
            os.chmod(root / DEVICE_IDENTITY_PATH, 0o600)
            os.chmod(root / HASH_KEY_PATH, 0o600)
            fsync_directory(root / "keys")
            fsync_directory(root)
            fsync_directory(root.parent)
            return

        os.chmod(root, 0o700)
        (root / "keys").mkdir(mode=0o700)
        created_hash_key = not current_key.exists()
        write_exclusive(
            marker,
            json_bytes({"created_hash_key": created_hash_key}),
        )
        fsync_directory(root)
        for relative in (
            DEVICE_IDENTITY_PATH,
            ENVELOPE_PATH,
            CONFIG_NAME,
            Path(".gitignore"),
        ):
            destination = root / relative
            if destination.exists() or destination.is_symlink():
                raise VaultError("refusing to overwrite partial vault state")
            os.replace(stage / relative, destination)
            committed.append(destination)
        if not current_key.exists():
            os.replace(staged_key, current_key)
            committed.append(current_key)
        os.chmod(root / "keys", 0o700)
        os.chmod(current_key, 0o600)
        fsync_directory(root / "keys")
        fsync_directory(root)
        marker.unlink()
        fsync_directory(root)
    except BaseException:
        for path in reversed(committed):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
        keys_dir = root / "keys"
        if keys_dir.is_dir():
            try:
                keys_dir.rmdir()
            except OSError:
                pass
        try:
            marker.unlink()
        except FileNotFoundError:
            pass
        if root.is_dir() and not any(root.iterdir()):
            try:
                root.rmdir()
            except OSError:
                pass
        raise
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def init_vault(root: Path, remote: str, recovery: str) -> None:
    validate_remote(remote)
    validate_recipient(recovery)
    with vault_lock(root):
        init_vault_locked(root, remote, recovery)


def atomic_replace(path: Path, data: bytes, mode: int = 0o600) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def authorized_key(root: Path, identity_argument: str | None) -> bytes:
    envelope = root / ENVELOPE_PATH
    identity = (
        Path(identity_argument).expanduser().absolute()
        if identity_argument
        else root / DEVICE_IDENTITY_PATH
    )
    if envelope.is_symlink() or not envelope.is_file():
        raise VaultError("correlation key envelope is missing or unsafe")
    if identity.is_symlink() or not identity.is_file():
        raise VaultError("identity is missing or unsafe")
    return decrypt(envelope, identity)


def materialize_local_key(root: Path, key: bytes) -> None:
    local_key = root / HASH_KEY_PATH
    if local_key.is_symlink():
        raise VaultError("local correlation key is unsafe")
    if local_key.exists():
        if not local_key.is_file():
            raise VaultError("local correlation key is unsafe")
        existing = local_key.read_bytes()
        if len(existing) != 32 or not secrets.compare_digest(existing, key):
            raise VaultError("local correlation key does not match the envelope")
        os.chmod(local_key, 0o600)
        return
    write_exclusive(local_key, key)
    fsync_directory(root)


def publish_recipient_update(
    root: Path, config: dict[str, object], key: bytes
) -> None:
    envelope = root / ENVELOPE_PATH
    config_path = root / CONFIG_NAME
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".correlation-key.", dir=envelope.parent
    )
    os.close(descriptor)
    temporary_envelope = Path(temporary_name)
    temporary_envelope.unlink()
    try:
        encrypt(key, all_recipients(config), temporary_envelope)
        set_recipient_state_hmac(config, key)
        previous_envelope = envelope.read_bytes()
        # Publish the envelope first. A stop before config replacement is
        # recoverable by repeating the command from the old authenticated
        # recipient registry.
        os.replace(temporary_envelope, envelope)
        fsync_directory(envelope.parent)
        try:
            atomic_replace(config_path, json_bytes(config))
        except BaseException:
            atomic_replace(envelope, previous_envelope)
            raise
    finally:
        try:
            temporary_envelope.unlink()
        except FileNotFoundError:
            pass


def add_device_locked(
    root: Path, recipient: str, identity_argument: str | None
) -> None:
    ensure_safe_existing_root(root)
    config = load_config(root)
    key = authorized_key(root, identity_argument)
    verify_recipient_state_hmac(config, key)
    materialize_local_key(root, key)

    devices = config["devices"]
    assert isinstance(devices, list)
    if recipient not in all_recipients(config):
        devices.append({"device_id": str(uuid.uuid4()), "recipient": recipient})
    publish_recipient_update(root, config, key)


def add_device(root: Path, recipient: str, identity_argument: str | None) -> None:
    validate_recipient(recipient)
    with vault_lock(root):
        add_device_locked(root, recipient, identity_argument)


def join_device_locked(root: Path, identity_argument: str) -> None:
    ensure_safe_existing_root(root)
    if not (root / "keys").is_dir():
        raise VaultError("vault keys directory is missing")
    os.chmod(root, 0o700)
    os.chmod(root / "keys", 0o700)
    config = load_config(root)
    key = authorized_key(root, identity_argument)
    verify_recipient_state_hmac(config, key)
    materialize_local_key(root, key)

    identity = root / DEVICE_IDENTITY_PATH
    if identity.is_symlink():
        raise VaultError("device identity is unsafe")
    if identity.exists() and not identity.is_file():
        raise VaultError("device identity is unsafe")

    devices = config["devices"]
    recovery_recipients = config["recovery_recipients"]
    assert isinstance(devices, list)
    assert isinstance(recovery_recipients, list)
    authorizing_identity = Path(identity_argument).expanduser().absolute()
    authorizing_recipient = derive_recipient(authorizing_identity)
    enrolled_recipients = [device["recipient"] for device in devices]

    if authorizing_recipient in enrolled_recipients:
        if identity.exists():
            recipient = derive_recipient(identity)
            if recipient != authorizing_recipient:
                raise VaultError("local device identity conflicts with enrolled identity")
        else:
            write_exclusive(identity, authorizing_identity.read_bytes())
            recipient = derive_recipient(identity)
            if recipient != authorizing_recipient:
                identity.unlink()
                raise VaultError("failed to adopt enrolled device identity")
            fsync_directory(identity.parent)
    elif authorizing_recipient in recovery_recipients:
        if not identity.exists():
            identity.parent.mkdir(mode=0o700, exist_ok=True)
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=".device.", dir=identity.parent
            )
            os.close(descriptor)
            temporary_identity = Path(temporary_name)
            temporary_identity.unlink()
            try:
                run(["age-keygen", "-o", str(temporary_identity)])
                if (
                    temporary_identity.is_symlink()
                    or not temporary_identity.is_file()
                ):
                    raise VaultError("age-keygen did not create an identity")
                os.chmod(temporary_identity, 0o600)
                os.replace(temporary_identity, identity)
                fsync_directory(identity.parent)
            finally:
                try:
                    temporary_identity.unlink()
                except FileNotFoundError:
                    pass
        recipient = derive_recipient(identity)
    else:
        raise VaultError("authorizing identity is not in the recipient registry")

    os.chmod(identity, 0o600)
    if recipient not in all_recipients(config):
        devices.append({"device_id": str(uuid.uuid4()), "recipient": recipient})
    publish_recipient_update(root, config, key)


def join_device(root: Path, identity_argument: str) -> None:
    with vault_lock(root):
        join_device_locked(root, identity_argument)


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(prog="flight-recorder")
    commands = top.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init")
    init.add_argument("--remote", required=True)
    init.add_argument("--recovery-recipient", required=True)
    device = commands.add_parser("device")
    device_commands = device.add_subparsers(dest="device_command", required=True)
    add = device_commands.add_parser("add")
    add.add_argument("--recipient", required=True)
    add.add_argument("--identity")
    join = device_commands.add_parser("join")
    join.add_argument("--identity", required=True)
    commands.add_parser("rotate")
    commands.add_parser("sync")
    rebuild = commands.add_parser("rebuild-index")
    rebuild.add_argument("--incremental", action="store_true")
    relationships = commands.add_parser("rebuild-relationships")
    relationships.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    status = commands.add_parser("status")
    status.add_argument("--json", action="store_true")
    report = commands.add_parser("report")
    report.add_argument("--last", required=True)
    report_policy = report.add_mutually_exclusive_group()
    report_policy.add_argument("--policy-version")
    report_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    report.add_argument("--json", action="store_true")
    inspect = commands.add_parser("inspect")
    inspect.add_argument("episode_id")
    inspect_policy = inspect.add_mutually_exclusive_group()
    inspect_policy.add_argument("--policy-version")
    inspect_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    inspect.add_argument("--json", action="store_true")
    evaluate = commands.add_parser("evaluate")
    evaluate.add_argument("episode_id")
    evaluate_policy = evaluate.add_mutually_exclusive_group()
    evaluate_policy.add_argument("--policy-version")
    evaluate_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    evaluate.add_argument("--rubric", type=Path)
    evaluate.add_argument("--evaluator")
    evaluate.add_argument("--model")
    evaluate.add_argument("--artifact", action="append", type=Path, default=[])
    evaluate.add_argument("--allow-artifact-content", action="store_true")
    evaluate.add_argument("--artifact-preview-token")
    evaluate.add_argument("--timeout", type=int, default=60)
    evaluate.add_argument("--json", action="store_true")
    automatic = commands.add_parser("auto-evaluation")
    automatic_commands = automatic.add_subparsers(
        dest="auto_evaluation_command", required=True
    )
    automatic_configure = automatic_commands.add_parser("configure")
    automatic_configure.add_argument("--evaluator", required=True)
    automatic_configure.add_argument("--model", required=True)
    automatic_policy = automatic_configure.add_mutually_exclusive_group(
        required=True
    )
    automatic_policy.add_argument("--policy-version")
    automatic_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    automatic_configure.add_argument(
        "--uncertainty-score-below", type=int, required=True
    )
    automatic_configure.add_argument(
        "--max-evaluations-per-run", type=int, required=True
    )
    automatic_configure.add_argument(
        "--max-cost-microusd-per-run", type=int, required=True
    )
    automatic_configure.add_argument("--json", action="store_true")
    automatic_run = automatic_commands.add_parser("run")
    automatic_run.add_argument("--json", action="store_true")
    source = commands.add_parser("source")
    source_commands = source.add_subparsers(
        dest="source_command", required=True
    )
    source_register = source_commands.add_parser("register")
    source_register.add_argument(
        "--adapter", required=True, choices=("claude-code", "codex")
    )
    source_register.add_argument("--path", required=True, type=Path)
    source_register.add_argument("--json", action="store_true")
    receipt = commands.add_parser("receipt")
    receipt_commands = receipt.add_subparsers(
        dest="receipt_command", required=True
    )
    receipt_generate = receipt_commands.add_parser("generate")
    receipt_generate.add_argument("episode_id")
    receipt_policy = receipt_generate.add_mutually_exclusive_group()
    receipt_policy.add_argument("--policy-version")
    receipt_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    receipt_generate.add_argument("--source-ref", required=True)
    receipt_generate.add_argument("--span-start-line", required=True, type=int)
    receipt_generate.add_argument("--span-end-line", required=True, type=int)
    receipt_generate.add_argument("--evaluator", required=True)
    receipt_generate.add_argument("--model", required=True)
    receipt_generate.add_argument("--rubric", required=True, type=Path)
    receipt_generate.add_argument("--timeout", type=int, default=60)
    receipt_generate.add_argument("--json", action="store_true")
    receipt_auto = commands.add_parser("receipt-auto")
    receipt_auto_commands = receipt_auto.add_subparsers(
        dest="receipt_auto_command", required=True
    )
    receipt_auto_configure = receipt_auto_commands.add_parser("configure")
    receipt_auto_configure.add_argument(
        "--claude-code-root", required=True, type=Path
    )
    receipt_auto_configure.add_argument("--codex-root", required=True, type=Path)
    receipt_auto_configure.add_argument("--evaluator", required=True)
    receipt_auto_configure.add_argument("--model", required=True)
    receipt_auto_configure.add_argument("--rubric", required=True, type=Path)
    receipt_auto_configure.add_argument("--policy-version", required=True)
    receipt_auto_configure.add_argument(
        "--quiescence-seconds", required=True, type=int
    )
    receipt_auto_configure.add_argument(
        "--max-receipts-per-run", required=True, type=int
    )
    receipt_auto_configure.add_argument(
        "--max-cost-microusd-per-run", required=True, type=int
    )
    receipt_auto_configure.add_argument("--json", action="store_true")
    receipt_auto_run = receipt_auto_commands.add_parser("run")
    receipt_auto_run.add_argument("--json", action="store_true")
    forget = commands.add_parser("forget")
    forget.add_argument("episode_id")
    forget_policy = forget.add_mutually_exclusive_group()
    forget_policy.add_argument("--policy-version")
    forget_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    forget.add_argument("--json", action="store_true")
    purge = commands.add_parser("purge")
    purge.add_argument("episode_id")
    purge_policy = purge.add_mutually_exclusive_group()
    purge_policy.add_argument("--policy-version")
    purge_policy.add_argument(
        "--policy", "--policy-file", dest="policy", type=Path
    )
    purge.add_argument("--apply", action="store_true")
    purge.add_argument("--json", action="store_true")
    scheduler = commands.add_parser("scheduler")
    scheduler_commands = scheduler.add_subparsers(
        dest="scheduler_command", required=True
    )
    scheduler_commands.add_parser("install")
    scheduler_commands.add_parser("uninstall")
    scheduler_commands.add_parser("run")
    return top


def main() -> int:
    args = parser().parse_args()
    root = state_root()
    if args.command == "init":
        init_vault(root, args.remote, args.recovery_recipient)
    elif args.command == "device" and args.device_command == "add":
        add_device(root, args.recipient, args.identity)
    elif args.command == "device" and args.device_command == "join":
        join_device(root, args.identity)
    elif args.command in (
        "rotate",
        "sync",
        "rebuild-index",
        "rebuild-relationships",
        "status",
        "report",
        "inspect",
        "evaluate",
        "auto-evaluation",
        "source",
        "receipt",
        "receipt-auto",
        "forget",
        "purge",
        "scheduler",
    ):
        # The shell wrapper executes this file as __main__. Register that module
        # under its import name so chunk_rotation shares this VaultError class
        # instead of loading a second copy that the CLI exception handler misses.
        sys.modules.setdefault("vault", sys.modules[__name__])
        if args.command == "rotate":
            from chunk_rotation import rotate

            rotate(root)
        elif args.command == "sync":
            from scheduler import manual_sync

            manual_sync(root)
        elif args.command == "rebuild-index":
            from evidence_index import rebuild_index

            rebuild_index(root, incremental=args.incremental)
        elif args.command == "rebuild-relationships":
            from evidence_index import rebuild_relationship_views

            rebuild_relationship_views(root, args.policy)
        elif args.command in ("status", "report", "inspect"):
            from reporting import (
                emit,
                inspect_episode,
                render_inspect,
                render_report,
                render_status,
                report,
                status,
            )

            if args.command == "status":
                value = status(root)
                emit(value, as_json=args.json, human=render_status(value))
            elif args.command == "report":
                value = report(
                    root, args.last, args.policy_version, args.policy
                )
                emit(value, as_json=args.json, human=render_report(value))
            else:
                value = inspect_episode(
                    root,
                    args.episode_id,
                    args.policy_version,
                    args.policy,
                )
                emit(value, as_json=args.json, human=render_inspect(value))
        elif args.command == "evaluate":
            from evaluation import evaluate, render_evaluate
            from reporting import emit

            value = evaluate(
                root,
                args.episode_id,
                args.policy_version,
                args.policy,
                args.rubric,
                args.evaluator,
                args.model,
                args.artifact,
                args.allow_artifact_content,
                args.artifact_preview_token,
                args.timeout,
            )
            emit(value, as_json=args.json, human=render_evaluate(value))
        elif args.command == "auto-evaluation":
            from background_evaluation import configure, run as run_automatic
            from reporting import emit

            if args.auto_evaluation_command == "configure":
                value = configure(
                    root,
                    args.evaluator,
                    args.model,
                    args.policy_version,
                    args.policy,
                    args.uncertainty_score_below,
                    args.max_evaluations_per_run,
                    args.max_cost_microusd_per_run,
                )
                human = "Automatic evaluation configured.\n"
            else:
                value = run_automatic(root)
                human = (
                    "Automatic evaluation completed: "
                    f"{value['evaluated_count']} evaluated.\n"
                )
            emit(
                value,
                as_json=args.json,
                human=human,
            )
        elif args.command == "source":
            from reporting import emit
            from session_sources import register, render_register

            value = register(root, args.adapter, args.path)
            emit(value, as_json=args.json, human=render_register(value))
        elif args.command == "receipt":
            from reporting import emit
            from semantic_receipts import generate, render_generate

            value = generate(
                root,
                args.episode_id,
                args.source_ref,
                args.span_start_line,
                args.span_end_line,
                args.evaluator,
                args.model,
                args.rubric,
                args.timeout,
                args.policy_version,
                args.policy,
            )
            emit(value, as_json=args.json, human=render_generate(value))
        elif args.command == "receipt-auto":
            from receipt_automation import configure, run as run_receipt_automation
            from reporting import emit

            if args.receipt_auto_command == "configure":
                value = configure(
                    root,
                    args.claude_code_root,
                    args.codex_root,
                    args.evaluator,
                    args.model,
                    args.rubric,
                    args.policy_version,
                    args.quiescence_seconds,
                    args.max_receipts_per_run,
                    args.max_cost_microusd_per_run,
                )
                human = "Automatic Semantic Receipts configured.\n"
            else:
                value = run_receipt_automation(root)
                human = (
                    "Automatic Semantic Receipts completed: "
                    f"{value['generated_count']} generated.\n"
                )
            emit(value, as_json=args.json, human=human)
        elif args.command in ("forget", "purge"):
            from reporting import emit
            from retention import (
                forget,
                purge,
                render_forget,
                render_purge,
            )

            if args.command == "forget":
                value = forget(
                    root,
                    args.episode_id,
                    args.policy_version,
                    args.policy,
                )
                emit(value, as_json=args.json, human=render_forget(value))
            else:
                value = purge(
                    root,
                    args.episode_id,
                    args.policy_version,
                    args.policy,
                    apply=args.apply,
                )
                emit(value, as_json=args.json, human=render_purge(value))
        else:
            from scheduler import install, run, uninstall

            if args.scheduler_command == "install":
                install(root)
            elif args.scheduler_command == "uninstall":
                uninstall(root)
            elif args.scheduler_command == "run":
                # Handled sync failures are recorded in scheduler status and
                # deliberately exit zero so OS managers do not create a retry
                # storm. Unsafe setup or integrity failures still fail closed.
                run(root)
            else:
                raise VaultError("unsupported scheduler command")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VaultError as error:
        print(f"flight-recorder: {error}", file=sys.stderr)
        raise SystemExit(1)
