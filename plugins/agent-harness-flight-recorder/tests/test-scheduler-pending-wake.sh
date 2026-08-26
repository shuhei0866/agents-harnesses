#!/usr/bin/env bash
# Healthy-scheduler pending inbox wake contract tests.
# External dependencies: python3. Network/provider/Vault access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)" || exit 1
readonly TEST_ROOT
PASS=0
FAIL=0

cleanup() {
  [[ -n "$TEST_ROOT" && "$TEST_ROOT" != "/" && -d "$TEST_ROOT" ]] \
    || return
  [[ "${TEST_ROOT##*/}" == tmp.* ]] || return
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

test_pending_inbox_shortens_only_healthy_due_interval() {
  echo "test_pending_inbox_shortens_only_healthy_due_interval:"
  local err="$TEST_ROOT/due.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import datetime as dt
import pathlib
import sys

import scheduler


base = pathlib.Path(sys.argv[1])
root = base / "due-vault"
inbox = root / "inbox"
inbox.mkdir(parents=True)
inbox.chmod(0o700)
path = inbox / "events.jsonl"

last_success = dt.datetime(2026, 8, 25, 0, 0, tzinfo=dt.timezone.utc)
state = scheduler._state_after_success(None, now=last_success)
next_wake = last_success + dt.timedelta(seconds=scheduler.WAKE_INTERVAL_SECONDS)
daily = last_success + dt.timedelta(seconds=scheduler.HEALTHY_INTERVAL_SECONDS)

# A healthy recorder with no pending bytes keeps the daily network cadence.
path.write_bytes(b"")
path.chmod(0o600)
assert scheduler._scheduler_due(root, state, next_wake) is False
assert scheduler._scheduler_due(root, state, daily) is True

# One complete or partial pending byte is enough to use the existing 5m wake.
path.write_bytes(b"x")
path.chmod(0o600)
assert scheduler._scheduler_due(root, state, next_wake) is True

# Pending inbox changes no backoff/permanent-failure policy.
transient = dict(state)
transient.update({
    "last_error_category": "remote",
    "failure_class": "transient",
    "diagnostic_code": "remote_unavailable",
    "next_action_code": "retry_automatically",
    "consecutive_failure_count": 1,
    "next_retry_at": scheduler._format_time(daily),
})
assert scheduler._scheduler_due(root, transient, next_wake) is False
permanent = dict(transient)
permanent.update({
    "last_error_category": "integrity",
    "failure_class": "permanent",
    "diagnostic_code": "local_integrity_invalid",
    "next_action_code": "repair_configuration",
    "next_retry_at": None,
})
assert scheduler._scheduler_due(root, permanent, daily) is False
PY
  then
    pass "healthy+pendingだけ5分wakeをdueにしemptyはdaily/backoffを維持する"
  else
    cat "$err" >&2
    fail "healthy+pendingだけ5分wakeをdueにしemptyはdaily/backoffを維持する"
  fi
}

test_pending_probe_is_lstat_only_owner_safe_and_bounded() {
  echo "test_pending_probe_is_lstat_only_owner_safe_and_bounded:"
  local err="$TEST_ROOT/probe.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import os
import pathlib
import sys

import scheduler
from vault import VaultError


base = pathlib.Path(sys.argv[1])
root = base / "probe-vault"
inbox = root / "inbox"
inbox.mkdir(parents=True)
inbox.chmod(0o700)
path = inbox / "events.jsonl"
path.write_bytes(b"pending")
path.chmod(0o600)


def forbidden(*_args, **_kwargs):
    raise AssertionError("pending due probe read inbox content")


original_read_bytes = pathlib.Path.read_bytes
original_read_text = pathlib.Path.read_text
original_open = pathlib.Path.open
pathlib.Path.read_bytes = forbidden
pathlib.Path.read_text = forbidden
pathlib.Path.open = forbidden
try:
    assert scheduler._has_pending_inbox(root) is True
finally:
    pathlib.Path.read_bytes = original_read_bytes
    pathlib.Path.read_text = original_read_text
    pathlib.Path.open = original_open

path.write_bytes(b"")
assert scheduler._has_pending_inbox(root) is False
path.unlink()
assert scheduler._has_pending_inbox(root) is False

def rejected(label, prepare):
    if path.exists() or path.is_symlink():
        if path.is_dir() and not path.is_symlink():
            path.rmdir()
        else:
            path.unlink()
    prepare()
    try:
        scheduler._has_pending_inbox(root)
    except VaultError:
        return
    raise AssertionError(f"unsafe pending inbox was accepted: {label}")


outside = base / "outside"
outside.write_bytes(b"x")
rejected("symlink", lambda: path.symlink_to(outside))
rejected("directory", lambda: path.mkdir())


def make_hardlink():
    path.write_bytes(b"x")
    os.link(path, base / "hardlink")


rejected("hardlink", make_hardlink)
(base / "hardlink").unlink()
rejected("group-readable", lambda: (path.write_bytes(b"x"), path.chmod(0o640)))

original_limit = scheduler.MAX_PENDING_INBOX_BYTES
try:
    scheduler.MAX_PENDING_INBOX_BYTES = 4
    rejected("oversized", lambda: (path.write_bytes(b"12345"), path.chmod(0o600)))
finally:
    scheduler.MAX_PENDING_INBOX_BYTES = original_limit

path.unlink()
path.write_bytes(b"x")
path.chmod(0o600)
original_geteuid = scheduler.os.geteuid
scheduler.os.geteuid = lambda: original_geteuid() + 1
try:
    try:
        scheduler._has_pending_inbox(root)
    except VaultError:
        pass
    else:
        raise AssertionError("non-owner pending inbox was accepted")
finally:
    scheduler.os.geteuid = original_geteuid
PY
  then
    pass "pending判定は内容を読まずowner-only regular nlink=1とsize上限を検証する"
  else
    cat "$err" >&2
    fail "pending判定は内容を読まずowner-only regular nlink=1とsize上限を検証する"
  fi
}

test_next_healthy_wake_runs_sync_rotation_request_and_refresh() {
  echo "test_next_healthy_wake_runs_sync_rotation_request_and_refresh:"
  local err="$TEST_ROOT/integration.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import datetime as dt
import pathlib
import sys
import types

import scheduler
from vault import VaultError


base = pathlib.Path(sys.argv[1])
last_success = dt.datetime(2026, 8, 25, 0, 0, tzinfo=dt.timezone.utc)
now = last_success + dt.timedelta(seconds=scheduler.WAKE_INTERVAL_SECONDS)
healthy = scheduler._state_after_success(None, now=last_success)


@contextlib.contextmanager
def acquired_run_lock(_root, *, blocking):
    assert blocking is False
    yield True


def configure(root):
    scheduler.ensure_safe_existing_root = lambda _root: None
    scheduler.ensure_managed_gitignore = lambda _root: None
    scheduler._run_lock = acquired_run_lock
    scheduler._load_state = lambda _root: healthy
    scheduler._now = lambda: now
    scheduler._write_state = lambda _root, _state: None
    (root / "inbox").mkdir(parents=True)
    (root / "inbox").chmod(0o700)


pending_root = base / "pending-vault"
configure(pending_root)
(pending_root / "inbox/events.jsonl").write_bytes(b"one pending event\n")
(pending_root / "inbox/events.jsonl").chmod(0o600)
events = []


def sync(actual_root):
    assert actual_root == pending_root
    events.extend(("sync", "rotate", "request"))


def refresh(actual_root):
    assert actual_root == pending_root
    assert events == ["sync", "rotate", "request"]
    events.append("refresh")


scheduler.sync = sync
scheduler.run_pending_refresh = refresh
scheduler.run(pending_root)
assert events == ["sync", "rotate", "request", "refresh"]

# A broken refresh state is isolated from the two downstream workers.
failure_root = base / "refresh-failure-vault"
configure(failure_root)
(failure_root / "inbox/events.jsonl").write_bytes(b"pending\n")
(failure_root / "inbox/events.jsonl").chmod(0o600)
for relative in (
    "auto-evaluation/config.json",
    "receipt-automation/config.json",
):
    path = failure_root / relative
    path.parent.mkdir(parents=True)
    path.write_text("{}", encoding="utf-8")
downstream = []
scheduler.sync = lambda _root: None
scheduler.run_pending_refresh = lambda _root: (_ for _ in ()).throw(
    VaultError("refresh state unavailable")
)
background = types.ModuleType("background_evaluation")
background.run = lambda _root: downstream.append("evaluation")
background.record_failure = lambda *_args: None
receipt = types.ModuleType("receipt_automation")
receipt.run = lambda _root: downstream.append("receipt")
receipt.record_failure = lambda *_args: None
sys.modules["background_evaluation"] = background
sys.modules["receipt_automation"] = receipt
scheduler.run(failure_root)
assert downstream == ["evaluation", "receipt"]

empty_root = base / "empty-vault"
configure(empty_root)
(empty_root / "inbox/events.jsonl").write_bytes(b"")
(empty_root / "inbox/events.jsonl").chmod(0o600)


def forbidden(*_args, **_kwargs):
    raise AssertionError("empty healthy inbox triggered network or refresh work")


scheduler.sync = forbidden
scheduler.run_pending_refresh = forbidden
scheduler._write_state = forbidden
scheduler.run(empty_root)
PY
  then
    pass "次のhealthy wakeでpendingだけsync→rotate/request→refreshへ進める"
  else
    cat "$err" >&2
    fail "次のhealthy wakeでpendingだけsync→rotate/request→refreshへ進める"
  fi
}

test_pending_refresh_continues_on_five_minute_wakes() {
  echo "test_pending_refresh_continues_on_five_minute_wakes:"
  local err="$TEST_ROOT/refresh-due.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import datetime as dt
import pathlib
import sys

import scheduler


root = pathlib.Path(sys.argv[1]) / "refresh-vault"
(root / "inbox").mkdir(parents=True)
(root / "inbox").chmod(0o700)
inbox = root / "inbox/events.jsonl"
inbox.write_bytes(b"")
inbox.chmod(0o600)
last_success = dt.datetime(2026, 8, 25, 0, 0, tzinfo=dt.timezone.utc)
state = scheduler._state_after_success(None, now=last_success)
next_wake = last_success + dt.timedelta(seconds=scheduler.WAKE_INTERVAL_SECONDS)

scheduler.index_refresh_status = lambda _root: {"state": "refresh_required"}
assert scheduler._scheduler_due(root, state, next_wake) is True
scheduler.index_refresh_status = lambda _root: {"state": "refreshing"}
assert scheduler._scheduler_due(root, state, next_wake) is True
scheduler.index_refresh_status = lambda _root: {"state": "ready"}
assert scheduler._scheduler_due(root, state, next_wake) is False

# Existing scheduler failure policy remains authoritative over refresh work.
failed = dict(state)
failed.update({
    "failure_class": "permanent",
    "diagnostic_code": "local_integrity_invalid",
    "next_action_code": "repair_configuration",
})
scheduler.index_refresh_status = lambda _root: {"state": "refresh_required"}
assert scheduler._scheduler_due(root, failed, next_wake) is False
PY
  then
    pass "refresh_requiredも5分wakeで継続しready/失敗policyは従来cadenceを維持する"
  else
    cat "$err" >&2
    fail "refresh_requiredも5分wakeで継続しready/失敗policyは従来cadenceを維持する"
  fi
}

test_pending_inbox_shortens_only_healthy_due_interval
test_pending_probe_is_lstat_only_owner_safe_and_bounded
test_next_healthy_wake_runs_sync_rotation_request_and_refresh
test_pending_refresh_continues_on_five_minute_wakes

echo
echo "Scheduler pending wake tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
