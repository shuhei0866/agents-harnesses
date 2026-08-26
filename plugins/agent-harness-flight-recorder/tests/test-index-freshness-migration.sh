#!/usr/bin/env bash
# Pre-state migration and explicit rebuild freshness recovery contracts.
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

test_missing_state_is_classified_from_authenticated_index() {
  echo "test_missing_state_is_classified_from_authenticated_index:"
  local err="$TEST_ROOT/classification.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness


base = pathlib.Path(sys.argv[1]) / "classification"
base.mkdir()
cases = {
    "current-exact": ("ready", None),
    "source-drift": ("refresh_required", "source_inventory_drift"),
    "old-schema-v4": ("error", "full_rebuild_required"),
    "missing-seal": ("error", "full_rebuild_required"),
    "malformed-seal": ("error", "full_rebuild_required"),
    "tampered-seal": ("error", "full_rebuild_required"),
}
observed = []
for label, expected in cases.items():
    root = base / label
    root.mkdir()
    assert not (root / index_freshness.STATE_PATH).exists()

    def probe(actual_root, item=expected, name=label):
        assert actual_root == root
        observed.append(name)
        return item

    index_freshness._probe_without_state = probe
    value = index_freshness.status(root)
    assert value["state"] == expected[0], (label, value)
    assert value["diagnostic_code"] == expected[1], (label, value)
    assert set(value) == index_freshness.FIELDS
    assert not (root / index_freshness.STATE_PATH).exists()

assert observed == list(cases)
PY
  then
    pass "stateなしはexactだけready、drift/old-v4/seal異常を有限状態へ分類する"
  else
    cat "$err" >&2
    fail "stateなしはexactだけready、drift/old-v4/seal異常を有限状態へ分類する"
  fi
}

test_observatory_renders_migration_state_without_sealed_counts() {
  echo "test_observatory_renders_migration_state_without_sealed_counts:"
  local err="$TEST_ROOT/observatory.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness
import observatory


root = pathlib.Path(sys.argv[1]) / "observatory-migration"
root.mkdir()
index_freshness._probe_without_state = lambda _root: (
    "error", "full_rebuild_required"
)
observatory.index_freshness_status = index_freshness.status
observatory._bounded_inbox_count = lambda _root: 0


def forbidden(*_args, **_kwargs):
    raise AssertionError("migration state attempted an authenticated count read")


observatory._stored_receipts = forbidden
observatory._stored_value_records = forbidden
observatory.read_sealed_query_locked = forbidden
observatory.receipt_automation_status = lambda _root: {
    "schema_version": 1,
    "state": "idle",
    "enabled": False,
    "discovered": 0,
    "matched": 0,
    "ambiguous": 0,
    "missing": 0,
    "active": 0,
    "queued": 0,
    "generated": 0,
    "failed": 0,
    "measured_cost_microusd": 0,
    "diagnostic_code": None,
    "attempt_count": 0,
}

value = observatory.overview(root)
assert value["index_refresh"]["state"] == "error"
assert value["index_refresh"]["diagnostic_code"] == "full_rebuild_required"
assert value["recording"]["events"] is None
document = observatory.render_overview_html(value)
assert "更新" in document or "rebuild" in document.lower()
PY
  then
    pass "old/malformed migrationを固定500にせず有限error表示しcountsを隠す"
  else
    cat "$err" >&2
    fail "old/malformed migrationを固定500にせず有限error表示しcountsを隠す"
  fi
}

test_manual_full_and_incremental_rebuild_recover_state_only_after_success() {
  echo "test_manual_full_and_incremental_rebuild_recover_state_only_after_success:"
  local err="$TEST_ROOT/manual-rebuild.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import evidence_index
import index_freshness
from vault import VaultError


base = pathlib.Path(sys.argv[1]) / "manual"
base.mkdir()


def error_state(root):
    value = index_freshness._empty("error", "full_rebuild_required")
    value.update({
        "requested_at": "2026-08-25T00:00:00Z",
        "last_attempt_at": "2026-08-25T00:00:01Z",
        "last_refresh_duration_ms": 10,
        "last_vault_lock_duration_ms": 8,
    })
    return index_freshness._write(root, value)


def common_stubs(root, events):
    evidence_index.safe_index_directory = lambda actual: (
        events.append("safe") or actual / "index"
    )
    evidence_index.collect_stale_temporaries = lambda _index: events.append(
        "collect"
    )
    evidence_index.load_chunks = lambda actual: (
        events.append("load") or []
    )
    evidence_index.issue_index_seal = lambda actual: events.append("seal")
    evidence_index._authenticate_existing_index_for_write = (
        lambda actual, *, source_may_advance: events.append("authenticate")
    )


for incremental in (False, True):
    root = base / ("incremental" if incremental else "full")
    root.mkdir()
    before = error_state(root)
    before_bytes = (root / index_freshness.STATE_PATH).read_bytes()
    assert index_freshness.request_refresh_locked(root) == before
    assert (root / index_freshness.STATE_PATH).read_bytes() == before_bytes
    events = []
    common_stubs(root, events)
    evidence_index.rebuild_full = lambda actual, chunks: (
        events.append("full") or (0, 0)
    )
    evidence_index.rebuild_incremental = lambda actual, chunks: (
        events.append("incremental") or (0, 0)
    )
    evidence_index.rebuild_index_locked(root, incremental=incremental)
    after = index_freshness.status(root)
    assert before["state"] == "error"
    assert after["state"] == "ready", (incremental, after)
    assert after["diagnostic_code"] is None
    assert after["last_success_at"] is not None
    assert events[-1] == "seal"

# A failed rebuild or failed seal must not erase the actionable old state.
for phase in ("rebuild", "seal"):
    root = base / f"failure-{phase}"
    root.mkdir()
    before = error_state(root)
    events = []
    common_stubs(root, events)

    def fail_rebuild(_root, _chunks):
        raise VaultError("manual rebuild failed")

    def fail_seal(_root):
        raise VaultError("manual seal failed")

    evidence_index.rebuild_full = (
        fail_rebuild if phase == "rebuild" else lambda _root, _chunks: (0, 0)
    )
    if phase == "seal":
        evidence_index.issue_index_seal = fail_seal
    try:
        evidence_index.rebuild_index_locked(root, incremental=False)
    except VaultError:
        pass
    else:
        raise AssertionError(f"manual {phase} failure was accepted")
    assert index_freshness.status(root) == before
PY
  then
    pass "manual full/incremental成功だけreadyへ回復しrebuild/seal失敗は旧errorを保つ"
  else
    cat "$err" >&2
    fail "manual full/incremental成功だけreadyへ回復しrebuild/seal失敗は旧errorを保つ"
  fi
}

test_missing_state_is_classified_from_authenticated_index
test_observatory_renders_migration_state_without_sealed_counts
test_manual_full_and_incremental_rebuild_recover_state_only_after_success

echo
echo "Index freshness migration tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
