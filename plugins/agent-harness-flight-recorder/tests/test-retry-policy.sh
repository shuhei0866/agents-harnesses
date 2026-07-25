#!/usr/bin/env bash
# Durable retry/backoff policy contract tests.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PLUGIN_DIR/scripts"
TEST_ROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_ROOT"
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

test_bounded_deterministic_backoff() {
  echo "test_bounded_deterministic_backoff:"
  if python3 - "$SCRIPTS" <<'PY' 2>/dev/null
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import (
    RETRY_BASE_SECONDS,
    RETRY_CAP_SECONDS,
    retry_delay_seconds,
)

seed = "vault-1:device-1"
first = retry_delay_seconds(seed, 1)
assert RETRY_BASE_SECONDS == 300
assert RETRY_CAP_SECONDS == 86400
assert RETRY_BASE_SECONDS // 2 <= first <= RETRY_BASE_SECONDS
assert first == retry_delay_seconds(seed, 1)
for attempt in range(1, 80):
    nominal = min(
        RETRY_CAP_SECONDS,
        RETRY_BASE_SECONDS * (2 ** min(attempt - 1, 63)),
    )
    delay = retry_delay_seconds(seed, attempt)
    assert nominal // 2 <= delay <= nominal
    assert delay <= RETRY_CAP_SECONDS
try:
    retry_delay_seconds(seed, 0)
except ValueError:
    pass
else:
    raise AssertionError("zero attempt must be rejected")
PY
  then
    pass "backoffは決定的なequal jitterで5分から24時間までに収まる"
  else
    fail "backoffは決定的なequal jitterで5分から24時間までに収まる"
  fi
}

test_retry_state_survives_process_restart() {
  echo "test_retry_state_survives_process_restart:"
  local root="$TEST_ROOT/restart"
  mkdir -m 700 -p "$root/scheduler"
  if python3 - "$SCRIPTS" "$root" <<'PY' 2>/dev/null \
    && python3 - "$SCRIPTS" "$root" <<'PY2' 2>/dev/null
import datetime as dt
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import _state_after_failure, _write_state

root = pathlib.Path(sys.argv[2])
now = dt.datetime(2026, 7, 25, 0, 0, tzinfo=dt.timezone.utc)
state = _state_after_failure(
    None,
    now=now,
    failure_class="transient",
    diagnostic_code="remote_unavailable",
    next_action_code="retry_automatically",
    retry_seed="vault-1:device-1",
)
_write_state(root, state)
PY
import datetime as dt
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import _load_state, _retry_due

root = pathlib.Path(sys.argv[2])
state = _load_state(root)
assert state is not None
assert state["schema_version"] == 2
assert state["failure_class"] == "transient"
assert state["diagnostic_code"] == "remote_unavailable"
assert state["next_action_code"] == "retry_automatically"
assert state["consecutive_failure_count"] == 1
assert state["next_retry_at"] is not None
before = dt.datetime(2026, 7, 25, 0, 0, 1, tzinfo=dt.timezone.utc)
assert _retry_due(state, before) is False
due = dt.datetime.fromisoformat(
    state["next_retry_at"].replace("Z", "+00:00")
)
assert _retry_due(state, due) is True
PY2
  then
    pass "pending retry gateはprocess再起動後も保持され境界時刻で開く"
  else
    fail "pending retry gateはprocess再起動後も保持され境界時刻で開く"
  fi
}

test_failure_and_success_transitions() {
  echo "test_failure_and_success_transitions:"
  if python3 - "$SCRIPTS" <<'PY' 2>/dev/null
import datetime as dt
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import _state_after_failure, _state_after_success, _retry_due

t0 = dt.datetime(2026, 7, 25, 0, 0, tzinfo=dt.timezone.utc)
first = _state_after_failure(
    None,
    now=t0,
    failure_class="transient",
    diagnostic_code="remote_unavailable",
    next_action_code="retry_automatically",
    retry_seed="vault-1:device-1",
)
second = _state_after_failure(
    first,
    now=t0 + dt.timedelta(days=1),
    failure_class="transient",
    diagnostic_code="remote_unavailable",
    next_action_code="retry_automatically",
    retry_seed="vault-1:device-1",
)
assert second["consecutive_failure_count"] == 2
assert second["next_retry_at"] > first["next_retry_at"]

permanent = _state_after_failure(
    second,
    now=t0 + dt.timedelta(days=2),
    failure_class="permanent",
    diagnostic_code="origin_mismatch",
    next_action_code="repair_configuration",
    retry_seed="vault-1:device-1",
)
assert permanent["next_retry_at"] is None
assert _retry_due(permanent, t0 + dt.timedelta(days=100)) is False

success = _state_after_success(permanent, now=t0 + dt.timedelta(days=3))
assert success["last_success_at"] == "2026-07-28T00:00:00Z"
assert success["failure_class"] is None
assert success["diagnostic_code"] is None
assert success["next_action_code"] is None
assert success["next_retry_at"] is None
assert success["consecutive_failure_count"] == 0
PY
  then
    pass "transientは指数増加しpermanentは抑止され成功時に完全resetする"
  else
    fail "transientは指数増加しpermanentは抑止され成功時に完全resetする"
  fi
}

test_v1_migration_and_tamper_validation() {
  echo "test_v1_migration_and_tamper_validation:"
  local root="$TEST_ROOT/migration"
  mkdir -m 700 -p "$root/scheduler"
  printf '%s\n' \
    '{"last_attempt_at":"2026-07-24T00:00:00Z","last_error_category":"remote","last_success_at":null,"schema_version":1}' \
    >"$root/scheduler/state.json"
  chmod 600 "$root/scheduler/state.json"
  if python3 - "$SCRIPTS" "$root" <<'PY' 2>/dev/null
import json
import datetime as dt
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import VaultError, _load_state, _scheduler_due, _write_state

root = pathlib.Path(sys.argv[2])
path = root / "scheduler/state.json"
original = path.read_bytes()
state = _load_state(root)
assert path.read_bytes() == original
assert state["schema_version"] == 2
assert state["failure_class"] == "transient"
assert state["diagnostic_code"] == "remote_unavailable"
assert state["next_retry_at"] is None
_write_state(root, state)
assert json.loads(path.read_text())["schema_version"] == 2

path.write_text(json.dumps({
    "schema_version": 1,
    "last_attempt_at": "2026-07-24T00:00:00Z",
    "last_success_at": None,
    "last_error_category": "sync",
}))
state = _load_state(root)
assert state["failure_class"] == "transient"
assert state["diagnostic_code"] == "remote_unavailable"
assert state["next_action_code"] == "retry_automatically"
assert _scheduler_due(
    state, dt.datetime(2026, 7, 25, tzinfo=dt.timezone.utc)
) is True

bad = dict(state)
bad["unknown"] = "field"
path.write_text(json.dumps(bad))
try:
    _load_state(root)
except VaultError:
    pass
else:
    raise AssertionError("extra state fields must fail closed")
PY
  then
    pass "v1 stateをread-only移行し次のwriteでv2化、tamperはfail closedにする"
  else
    fail "v1 stateをread-only移行し次のwriteでv2化、tamperはfail closedにする"
  fi
}

test_current_failure_ignores_stale_pending() {
  echo "test_current_failure_ignores_stale_pending:"
  local root="$TEST_ROOT/stale-pending"
  mkdir -m 700 -p "$root/queue"
  printf '%s\n' \
    '{"last_error_category":"remote","schema_version":1}' \
    >"$root/queue/pending-sync.json"
  if python3 - "$SCRIPTS" "$root" <<'PY' 2>/dev/null
import datetime as dt
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from scheduler import VaultError, _failure_state

root = pathlib.Path(sys.argv[2])
state = _failure_state(
    root,
    None,
    now=dt.datetime(2026, 7, 25, tzinfo=dt.timezone.utc),
    error=VaultError("current local failure"),
)
assert state["failure_class"] == "permanent"
assert state["diagnostic_code"] == "local_integrity_invalid"
assert state["next_action_code"] == "repair_configuration"
assert state["next_retry_at"] is None
PY
  then
    pass "現在のlocal failureを古いremote pendingでtransientへ誤分類しない"
  else
    fail "現在のlocal failureを古いremote pendingでtransientへ誤分類しない"
  fi
}

test_conflict_and_lock_failure_boundaries() {
  echo "test_conflict_and_lock_failure_boundaries:"
  local root="$TEST_ROOT/failure-boundaries"
  mkdir -m 700 -p "$root/scheduler" "$root/.git/rebase-merge"
  if python3 - "$SCRIPTS" "$root" <<'PY' 2>/dev/null
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
import scheduler
import sync

root = pathlib.Path(sys.argv[2])

original_remote_has_main = sync.remote_has_main
original_git = sync.git
sync.remote_has_main = lambda _root: True
sync.git = lambda *_args, **_kwargs: (_ for _ in ()).throw(
    sync.VaultError("git failed")
)
try:
    try:
        sync.pull_rebase(root)
    except sync.SyncFailure as error:
        assert error.failure_class == "permanent"
        assert error.diagnostic_code == "rebase_conflict"
    else:
        raise AssertionError("rebase conflict must remain permanent")
finally:
    sync.remote_has_main = original_remote_has_main
    sync.git = original_git

original_flock = scheduler.fcntl.flock
original_monotonic = scheduler.time.monotonic
original_sleep = scheduler.time.sleep
ticks = iter((0.0, 6.0))
scheduler.fcntl.flock = lambda *_args: (_ for _ in ()).throw(BlockingIOError())
scheduler.time.monotonic = lambda: next(ticks)
scheduler.time.sleep = lambda _seconds: None
try:
    try:
        with scheduler._run_lock(root, blocking=True):
            raise AssertionError("busy lock must not be acquired")
    except scheduler.VaultError as error:
        assert "already running" in str(error)
    else:
        raise AssertionError("manual lock wait must be bounded")
finally:
    scheduler.fcntl.flock = original_flock
    scheduler.time.monotonic = original_monotonic
    scheduler.time.sleep = original_sleep
PY
  then
    pass "abort失敗でもconflictをpermanentに保ちmanual lock待機をboundedにする"
  else
    fail "abort失敗でもconflictをpermanentに保ちmanual lock待機をboundedにする"
  fi
}

echo "=== Flight Recorder Durable Retry Policy Tests ==="
test_bounded_deterministic_backoff
test_retry_state_survives_process_restart
test_failure_and_success_transitions
test_v1_migration_and_tamper_validation
test_current_failure_ignores_stale_pending
test_conflict_and_lock_failure_boundaries
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
