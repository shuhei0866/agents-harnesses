#!/usr/bin/env bash
# Authenticated bounded refresh horizon integration contract.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
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

run_cli() {
  local state="$1"
  shift
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$state" \
    "$CLI" "$@"
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

record_event() {
  local state="$1" event_id="$2" recorded_at="$3"
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" "$event_id" "$recorded_at" <<'PY'
import json
import pathlib
import sys

path, event_id, recorded_at = sys.argv[1:]
event = {
    "schema_version": 2,
    "event_id": event_id,
    "recorded_at": recorded_at,
    "harness": "claude-code",
    "source_event": "Stop",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + event_id.replace("-", "")[:24],
    "turn_id_hash": None,
    "workspace_id": "sha256:" + "2" * 24,
    "model": "fixture-model",
    "permission_mode": None,
    "tool": None,
    "metrics": {"duration_ms": 1000},
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": None,
        "task_source": None,
        "branch_or_worktree_id": None,
        "changed_file_fingerprints": [],
        "changed_files_state": "missing",
    },
}
with pathlib.Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

test_three_chunk_drift_advances_through_two_authenticated_horizons() {
  echo "test_three_chunk_drift_advances_through_two_authenticated_horizons:"
  local base="$TEST_ROOT/three-chunks"
  local remote="$base/remote.git" state="$base/vault"
  local recovery="$base/recovery.agekey" err="$base/assert.err"
  mkdir -p "$base"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1 || {
    fail "bounded horizon fixture Vaultを初期化できる"
    return
  }
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "empty baselineを同期できる"
    return
  }
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" <<'PY' >/dev/null 2>"$base/rebuild.err" || {
import pathlib
import sys

import evidence_index
import index_storage

index_storage.cache_index_storage_metrics = lambda _connection: None
root = pathlib.Path(sys.argv[1])
evidence_index.rebuild_index(root, incremental=False)

# Simulate an authenticated v5 database created before the additive partial
# index existed. The next bounded refresh must migrate it in place.
connection = evidence_index._open_existing(root / evidence_index.DATABASE_PATH)
try:
    connection.execute("DROP INDEX relationship_edges_link_candidates")
finally:
    connection.close()
evidence_index.issue_index_seal(root)
PY
    cat "$base/rebuild.err" >&2
    fail "empty authenticated baseline indexを構築できる"
    return
  }
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" <<'PY' >/dev/null 2>&1 || {
import pathlib
import sys

import index_freshness

root = pathlib.Path(sys.argv[1])
(root / index_freshness.STATE_PATH).unlink()
result = index_freshness.status(root)
assert result["state"] == "ready"
PY
    fail "baseline freshnessをreadyにできる"
    return
  }

  record_event "$state" "51000000-0000-4000-8000-000000000001" \
    "2026-08-25T01:00:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "drift chunk 1を同期できる"
    return
  }
  record_event "$state" "52000000-0000-4000-8000-000000000002" \
    "2026-08-25T01:01:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "drift chunk 2を同期できる"
    return
  }
  record_event "$state" "53000000-0000-4000-8000-000000000003" \
    "2026-08-25T01:02:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "drift chunk 3を同期できる"
    return
  }

  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" 2>"$err" <<'PY'
import json
import pathlib
import sqlite3
import sys

import evidence_index
import index_freshness
from vault import VaultError


root = pathlib.Path(sys.argv[1])
expected_event_ids = {
    "51000000-0000-4000-8000-000000000001",
    "52000000-0000-4000-8000-000000000002",
    "53000000-0000-4000-8000-000000000003",
}
provider_snapshots = []
real_load_chunks = evidence_index.load_chunks
real_rebuild = evidence_index.rebuild_incremental_bounded


def tracked_provider(actual_root):
    chunks = real_load_chunks(actual_root)
    provider_snapshots.append(tuple(chunk.chunk_row[0] for chunk in chunks))
    return chunks


evidence_index.load_chunks = tracked_provider
def observed_rebuild(actual_root, *, max_chunks, max_events):
    try:
        return real_rebuild(
            actual_root, max_chunks=max_chunks, max_events=max_events
        )
    except Exception as error:
        print(f"bounded rebuild detail: {error!r}", file=sys.stderr)
        raise


index_freshness.rebuild_incremental_bounded = observed_rebuild


def database_projection():
    connection = sqlite3.connect(
        f"file:{root / evidence_index.DATABASE_PATH}?mode=ro", uri=True
    )
    try:
        return (
            connection.execute("SELECT COUNT(*) FROM source_chunks").fetchone()[0],
            connection.execute("SELECT COUNT(*) FROM source_events").fetchone()[0],
            {
                row[0]
                for row in connection.execute(
                    "SELECT event_id FROM source_events ORDER BY event_id"
                )
            },
        )
    finally:
        connection.close()


assert database_projection() == (0, 0, set())
legacy = sqlite3.connect(
    f"file:{root / evidence_index.DATABASE_PATH}?mode=ro", uri=True
)
try:
    assert legacy.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' "
        "AND name='relationship_edges_link_candidates'"
    ).fetchone()[0] == 0
finally:
    legacy.close()
first = index_freshness.run_pending_refresh(root)
assert first["state"] == "refresh_required", first
assert first["diagnostic_code"] == "source_inventory_drift"
assert database_projection()[0:2] == (2, 2)
indexed = sqlite3.connect(
    f"file:{root / evidence_index.DATABASE_PATH}?mode=ro", uri=True
)
try:
    assert indexed.execute(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' "
        "AND name='relationship_edges_link_candidates'"
    ).fetchone()[0] == 1
finally:
    indexed.close()
first_seal = evidence_index.load_index_seal(root)
assert first_seal["source_inventory"]["chunk_count"] == 2
assert first_seal["source_inventory"]["event_count"] == 2
full_inventory = evidence_index._source_inventory(root)
assert full_inventory["chunk_count"] == 3
assert first_seal["source_inventory"]["sha256"] != full_inventory["sha256"]

sealed_query_calls = []
try:
    evidence_index.read_sealed_query_locked(
        root,
        "default-v1",
        lambda connection, _policy: sealed_query_calls.append(True),
    )
except VaultError as error:
    assert "source" in str(error).lower() or "seal" in str(error).lower()
else:
    raise AssertionError("partial horizon was served as current full source")
assert sealed_query_calls == []

second = index_freshness.run_pending_refresh(root)
assert second["state"] == "ready"
assert second["diagnostic_code"] is None
chunk_count, event_count, event_ids = database_projection()
assert (chunk_count, event_count) == (3, 3)
assert event_ids == expected_event_ids
second_seal = evidence_index.load_index_seal(root)
assert second_seal["source_inventory"]["chunk_count"] == 3
assert second_seal["source_inventory"]["event_count"] == 3
assert second_seal["source_inventory"]["sha256"] == full_inventory["sha256"]

sealed_count = evidence_index.read_sealed_query_locked(
    root,
    "default-v1",
    lambda connection, _policy: connection.execute(
        "SELECT COUNT(*) FROM source_events"
    ).fetchone()[0],
)
assert sealed_count == 3
assert len(provider_snapshots) == 2
assert [len(snapshot) for snapshot in provider_snapshots] == [3, 3]
assert len(set(provider_snapshots[0])) == 3
assert provider_snapshots[0] == provider_snapshots[1]
PY
  then
    pass "3 chunksを2+1で処理しpartial seal fail-closed後にready sealへ到達する"
  else
    cat "$err" >&2
    fail "3 chunksを2+1で処理しpartial seal fail-closed後にready sealへ到達する"
  fi
}

test_three_chunk_drift_advances_through_two_authenticated_horizons

echo
echo "Index freshness integration tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
