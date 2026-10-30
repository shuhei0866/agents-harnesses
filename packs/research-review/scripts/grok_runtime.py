#!/usr/bin/env python3
"""Local, on-demand Grok routine runner. No daemon, automatic retry or Drive API."""
from __future__ import annotations

import argparse
import fcntl
import getpass
import json
import os
import re
import stat
import sys
import tempfile
import uuid
import warnings
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from grok_webhook import send_once, valid_configuration
from mac_keychain import MacKeychain
from research_review import ContractError, inspect, lint, load, require, sha, unique_pairs

LIMIT = 256 * 1024
DEFAULT_ROOT = Path.home() / ".local/share/agents-harnesses/research-review"
NAME = re.compile(r"[A-Za-z0-9_-]{1,80}\.(?:md|txt)")


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":"), allow_nan=False).encode("utf-8")


def read_json(path, limit=LIMIT):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as file:
        require(stat.S_ISREG(os.fstat(file.fileno()).st_mode), "expected a regular file")
        raw = file.read(limit + 1)
    require(len(raw) <= limit, "input too large")
    def reject(value):
        raise ContractError("non-finite JSON number")
    return json.loads(raw, object_pairs_hook=unique_pairs, parse_constant=reject), raw


def write_new(path, raw):
    with os.fdopen(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb") as file:
        file.write(raw)
        file.flush()
        os.fsync(file.fileno())


def save(path, value):
    temp = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    write_new(temp, encoded(value))
    os.replace(temp, path)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def private_directory(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and not path.is_symlink()
            and info.st_uid == os.getuid() and not info.st_mode & 0o077,
            "runtime directory must be owned by this user with mode 700")


@contextmanager
def locked(root):
    private_directory(root)
    fd = os.open(root / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    except BlockingIOError:
        raise ContractError("runtime busy") from None
    finally:
        os.close(fd)


def config(root):
    value, _ = read_json(root / "profile.json")
    require(isinstance(value, dict), "invalid profile")
    require(type(value.get("schema_version")) is int and value["schema_version"] == 1 and
            re.fullmatch(r"[a-f0-9]{32}", value.get("keychain_account", "")), "invalid profile")
    require(valid_configuration(value["origin"] + "/", "placeholder", value["origin"]),
            "invalid profile origin")
    require(re.fullmatch(r"https://drive\.google\.com/drive/folders/[A-Za-z0-9_-]+",
                         value["output_folder"]), "invalid output folder")
    for key, minimum, maximum in (("daily_limit", 1, 20), ("max_chars", 100, 5000),
                                  ("time_budget_minutes", 1, 30)):
        require(type(value.get(key)) is int and minimum <= value[key] <= maximum,
                "invalid profile cap")
    return value


def configure(root, origin, folder, daily_limit=3, max_chars=1200, minutes=5):
    with locked(root):
        profile = {"schema_version": 1, "origin": origin.rstrip("/"),
                   "output_folder": folder.rstrip("/"), "daily_limit": daily_limit,
                   "max_chars": max_chars, "time_budget_minutes": minutes,
                   "keychain_account": uuid.uuid4().hex, "endpoint_sha256": None}
        require(not (root / "profile.json").exists(), "profile already exists")
        write_new(root / "profile.json", encoded(profile))
        try:
            config(root)
        except Exception:
            (root / "profile.json").unlink()
            raise
        private_directory(root / "jobs")
        return {"configured": True, "credentials_stored": False, "output_folder": profile["output_folder"]}


def credential(root, action, keychain=None):
    require(sys.stdin.isatty() and sys.stderr.isatty(), "run credential setup in a local terminal")
    with locked(root):
        cfg = config(root)
        store = keychain or MacKeychain()
        if action == "forget":
            store.forget(cfg["keychain_account"])
            return {"credentials_removed": True, "routine_paused": False}
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            endpoint = getpass.getpass("Routine URL (hidden): ")
            key = getpass.getpass("Bare webhook key (hidden): ")
        require(valid_configuration(endpoint, key, cfg["origin"]), "invalid routine configuration")
        pin = sha(endpoint.encode())
        require(cfg["endpoint_sha256"] in (None, pin), "endpoint differs from configured routine")
        # Pin first. A failed Keychain operation can be repeated with the same URL.
        cfg["endpoint_sha256"] = pin
        save(root / "profile.json", cfg)
        store.put(cfg["keychain_account"], encoded({"endpoint": endpoint, "key": key}),
                  replace=action == "replace")
        return {"credentials_stored": True, "secret_values_logged": False}


def job_path(root, task_id):
    require(isinstance(task_id, str) and re.fullmatch(r"[a-f0-9]{32}", task_id), "invalid task id")
    return root / "jobs" / task_id


def prepare(root, question, period, zone="UTC"):
    with locked(root):
        cfg = config(root)
        require(isinstance(question, str) and 0 < len(question.strip()) <= 2000,
                "question must contain 1-2000 characters")
        require(isinstance(period, str) and 0 < len(period.strip()) <= 200,
                "period must be specified")
        require(isinstance(zone, str) and 0 < len(zone.strip()) <= 80, "timezone must be specified")
        task_id = uuid.uuid4().hex
        directory = job_path(root, task_id)
        directory.mkdir(mode=0o700)
        bundle = {"schema_version": 1, "task": {
            "id": task_id, "question": question, "period": period, "timezone": zone,
            "recipient": "Research coordinator", "researcher": "Researcher",
            "allowed_sources": ["public web and public X posts"],
            "allowed_actions": ["read public sources", "message existing authorized research/review roles",
                                "write task files and one result to the configured output folder"],
            "time_budget": "%d minutes; return partial results when exhausted" % cfg["time_budget_minutes"],
            "max_chars": cfg["max_chars"]}, "sources": [], "claims": [],
            "artifacts": [{"id": "report", "kind": "report", "path": "report.md",
                           "claim_ids": [], "unknown_claim_ids": []}], "review": None}
        task_hash = sha(encoded(bundle["task"]))
        # The installed routine holds the contract. Send a literal template rather
        # than asking the coordinator to translate or rename schema fields.
        payload = {"schema_version": 1, "task_id": task_id, "task_sha256": task_hash,
                   "output_folder": cfg["output_folder"], "output_name": task_id + ".json",
                   "bundle_template": bundle}
        write_new(directory / "request.json", encoded(payload))
        write_new(directory / "state.json", encoded({"status": "prepared"}))
        return {"task_id": task_id, "status": "prepared", "question": question,
                "output_folder": cfg["output_folder"], "output_name": task_id + ".json"}


def submit(root, task_id, keychain=None, sender=send_once, now=None):
    with locked(root):
        cfg = config(root)
        directory = job_path(root, task_id)
        state, _ = read_json(directory / "state.json")
        require(state["status"] == "prepared", "task has already reserved a send")
        require(not (root / "pending.json").exists(), "another task remains pending; inspect it first")
        payload, raw = read_json(directory / "request.json")
        require(payload["task_id"] == task_id and payload["output_folder"] == cfg["output_folder"],
                "request differs from profile")
        require(payload["bundle_template"]["task"]["id"] == task_id and
                sha(encoded(payload["bundle_template"]["task"])) == payload["task_sha256"],
                "task fingerprint mismatch")
        day = (now or datetime.now(timezone.utc)).astimezone(timezone.utc).date().isoformat()
        count = 0
        for path in (root / "jobs").glob("*/attempt.json"):
            attempt, _ = read_json(path)
            count += attempt.get("day_utc") == day
        require(count < cfg["daily_limit"], "daily send reservation limit reached (UTC)")
        credentials = json.loads((keychain or MacKeychain()).get(cfg["keychain_account"]),
                                 object_pairs_hook=unique_pairs)
        require(set(credentials) == {"endpoint", "key"} and
                all(isinstance(v, str) for v in credentials.values()), "invalid Keychain data")
        endpoint, key = credentials["endpoint"], credentials["key"]
        require(valid_configuration(endpoint, key, cfg["origin"]) and
                sha(endpoint.encode()) == cfg["endpoint_sha256"], "routine pin mismatch")
        attempt = {"task_id": task_id, "day_utc": day, "request_sha256": sha(raw),
                   "endpoint_sha256": cfg["endpoint_sha256"],
                   "attempted_at": datetime.now(timezone.utc).isoformat(), "status": "reserved"}
        # Durable markers precede any network call. Crashes consume the reservation
        # and keep pending blocked; they never trigger a second POST.
        write_new(directory / "attempt.json", encoded(attempt))
        save(root / "pending.json", {"task_id": task_id})
        save(directory / "state.json", {"status": "reserved"})
        result = sender(payload["bundle_template"], endpoint, key, cfg["origin"], payload=raw)
        save(directory / "state.json", result)
        if result["status"] in {"not_sent", "not_accepted"}:
            (root / "pending.json").unlink()
        return result


def status(root):
    with locked(root):
        cfg = config(root)
        result = {"profile_present": True, "output_folder": cfg["output_folder"],
                  "credentials_pinned": cfg["endpoint_sha256"] is not None,
                  "daily_limit_utc": cfg["daily_limit"], "pending": None}
        if (root / "pending.json").exists():
            pending, _ = read_json(root / "pending.json")
            state, _ = read_json(job_path(root, pending["task_id"]) / "state.json")
            result["pending"] = {"task_id": pending["task_id"], "state": state,
                                 "output_name": pending["task_id"] + ".json"}
        return result


def collect(root, task_id, input_path, folder, file_id):
    with locked(root):
        cfg = config(root)
        require(folder == cfg["output_folder"], "result folder does not match profile")
        require(isinstance(file_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,200}", file_id),
                "invalid Drive file id")
        directory = job_path(root, task_id)
        request, _ = read_json(directory / "request.json")
        require((directory / "attempt.json").exists(), "task was not submitted")
        state, _ = read_json(directory / "state.json")
        require(state["status"] in {"reserved", "accepted", "unknown", "received"},
                "task cannot receive a result")
        value, raw = read_json(input_path)
        received = directory / "received"
        if received.exists():
            receipt, _ = read_json(received / "receipt.json")
            saved, saved_raw = read_json(received / "raw-return.json")
            current = load(received / "bundle.json")
            digest = inspect(current, received)[-1]
            require(raw == saved_raw and saved == value and
                    receipt["task_id"] == task_id and receipt["drive_file_id"] == file_id and
                    receipt["raw_return_sha256"] == sha(raw) and receipt["target_digest"] == digest,
                    "existing receipt differs from supplied result")
            return finish_collection(root, directory, receipt)
        require(set(value) == {"schema_version", "task_id", "task_sha256", "bundle", "files"}
                and type(value["schema_version"]) is int and value["schema_version"] == 1
                and value["task_id"] == task_id and value["task_sha256"] == request["task_sha256"],
                "result does not match request")
        bundle, files = value["bundle"], value["files"]
        require(isinstance(bundle, dict) and bundle.get("task") == request["bundle_template"]["task"],
                "returned task was changed")
        require(isinstance(files, dict) and 1 <= len(files) <= 8 and
                all(isinstance(k, str) and NAME.fullmatch(k) and isinstance(v, str)
                    for k, v in files.items()), "invalid result files")
        artifacts = bundle.get("artifacts")
        require(isinstance(artifacts, list) and all(isinstance(a, dict) and
                isinstance(a.get("path"), str) for a in artifacts) and
                {a["path"] for a in artifacts} == set(files), "result artifact set mismatch")
        # Materialize exact JSON UTF-8 strings, never a rendered chat preview.
        stage = Path(tempfile.mkdtemp(prefix="receive-", dir=directory))
        for name, content in files.items():
            write_new(stage / name, content.encode("utf-8"))
        write_new(stage / "bundle.json", encoded(bundle))
        write_new(stage / "raw-return.json", raw)
        loaded = load(stage / "bundle.json")
        *_, hashes, lengths, digest = inspect(loaded, stage)
        require(sum(lengths[a["id"]] for a in artifacts if a["kind"] == "report") <= cfg["max_chars"],
                "report exceeds configured length")
        checks = lint(loaded, stage)
        write_new(stage / "lint.json", encoded(checks))
        receipt = {"status": "received", "task_id": task_id, "research_complete": False,
                   "source_truth_verified": False, "target_digest": digest,
                   "artifact_sha256": hashes, "drive_file_id": file_id,
                   "raw_return_sha256": sha(raw), "structurally_complete": checks["structurally_complete"]}
        save(stage / "receipt.json", receipt)
        os.rename(stage, received)
        return finish_collection(root, directory, receipt)


def finish_collection(root, directory, receipt):
    if (root / "pending.json").exists():
        pending, _ = read_json(root / "pending.json")
        require(pending["task_id"] == receipt["task_id"], "pending task mismatch")
    save(directory / "state.json", receipt)
    if (root / "pending.json").exists():
        (root / "pending.json").unlink()
    return receipt


def reconcile(root, task_id, observation):
    """Free a slot only after external observation; this never resends a task."""
    require(isinstance(observation, str) and 10 <= len(observation.strip()) <= 1000,
            "record the observed completion, cancellation or definitive rejection")
    with locked(root):
        pending, _ = read_json(root / "pending.json")
        require(pending["task_id"] == task_id, "pending task mismatch")
        directory = job_path(root, task_id)
        state, _ = read_json(directory / "state.json")
        record = directory / "reconciliation.json"
        if record.exists():
            existing, _ = read_json(record)
            require(existing.get("task_id") == task_id and existing.get("observation") == observation
                    and existing.get("resend") is False, "existing reconciliation differs")
        else:
            save(record, {"task_id": task_id, "prior_state": state, "observation": observation,
                          "observed_at": datetime.now(timezone.utc).isoformat(), "resend": False})
        save(directory / "state.json", {"status": "reconciled", "task_id": task_id})
        (root / "pending.json").unlink()
        return {"status": "reconciled", "automatic_retry": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("configure")
    p.add_argument("--origin", required=True)
    p.add_argument("--output-folder", required=True)
    p.add_argument("--daily-limit", type=int, default=3)
    p.add_argument("--max-chars", type=int, default=1200)
    p.add_argument("--minutes", type=int, default=5)
    commands.add_parser("credential").add_argument("action", choices=["add", "replace", "forget"])
    p = commands.add_parser("prepare")
    p.add_argument("--question", required=True)
    p.add_argument("--period", required=True)
    p.add_argument("--timezone", default="UTC")
    commands.add_parser("status")
    commands.add_parser("submit").add_argument("task_id")
    p = commands.add_parser("collect")
    p.add_argument("task_id")
    p.add_argument("input", type=Path)
    p.add_argument("--folder-url", required=True)
    p.add_argument("--file-id", required=True)
    p = commands.add_parser("reconcile")
    p.add_argument("task_id")
    p.add_argument("--observation", required=True)
    args = parser.parse_args()
    try:
        root = args.root.expanduser().absolute()
        if args.command == "configure":
            result = configure(root, args.origin, args.output_folder, args.daily_limit,
                               args.max_chars, args.minutes)
        elif args.command == "credential":
            result = credential(root, args.action)
        elif args.command == "prepare":
            result = prepare(root, args.question, args.period, args.timezone)
        elif args.command == "submit":
            result = submit(root, args.task_id)
        elif args.command == "status":
            result = status(root)
        elif args.command == "collect":
            result = collect(root, args.task_id, args.input, args.folder_url, args.file_id)
        else:
            result = reconcile(root, args.task_id, args.observation)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (ContractError, OSError, ValueError, TypeError, KeyError, RecursionError, getpass.GetPassWarning):
        # No untrusted exception text, source contents or credentials in logs.
        print(json.dumps({"status": "failed", "automatic_retry": False,
                          "reason": "inspect local configuration or job records; do not resend"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
