#!/usr/bin/env bash
# Automatic bounded Evidence Index freshness contract tests.
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

test_repeated_requests_coalesce_and_one_run_is_bounded() {
  echo "test_repeated_requests_coalesce_and_one_run_is_bounded:"
  local err="$TEST_ROOT/coalesced.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness


root = pathlib.Path(sys.argv[1]) / "coalesced-vault"
root.mkdir()

first = index_freshness.request_refresh_locked(root)
state_path = root / index_freshness.STATE_PATH
first_bytes = state_path.read_bytes()
second = index_freshness.request_refresh_locked(root)
second_bytes = state_path.read_bytes()

assert first["state"] == "refresh_required"
assert second == first
assert second_bytes == first_bytes

calls = []
index_freshness.authenticate_incremental_base = lambda _root: None


def bounded_rebuild(actual_root, *, max_chunks, max_events):
    assert actual_root == root
    assert 1 <= max_chunks <= 2
    assert 1 <= max_events <= 5000
    calls.append((max_chunks, max_events))
    return True  # More drift remains after this bounded unit of work.


index_freshness.rebuild_incremental_bounded = bounded_rebuild
result = index_freshness.run_pending_refresh(root)
assert calls == [(index_freshness.MAX_REFRESH_CHUNKS,
                  index_freshness.MAX_REFRESH_EVENTS)]
assert result["state"] == "refresh_required"
assert result["diagnostic_code"] == "source_inventory_drift"
assert result["last_refresh_duration_ms"] >= 0
assert result["last_vault_lock_duration_ms"] >= 0
PY
  then
    pass "重複arrivalを1要求へ畳み1回あたり2 chunks/5000 events以下で更新する"
  else
    cat "$err" >&2
    fail "重複arrivalを1要求へ畳み1回あたり2 chunks/5000 events以下で更新する"
  fi
}

test_refresh_state_machine_is_finite_and_measured() {
  echo "test_refresh_state_machine_is_finite_and_measured:"
  local err="$TEST_ROOT/states.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness
from vault import VaultError


root = pathlib.Path(sys.argv[1]) / "state-vault"
root.mkdir()
observed = []

required_fields = {
    "schema_version",
    "state",
    "diagnostic_code",
    "requested_at",
    "last_attempt_at",
    "last_success_at",
    "last_refresh_duration_ms",
    "last_vault_lock_duration_ms",
}

def assert_status(expected):
    value = index_freshness.status(root)
    assert set(value) == required_fields
    assert value["schema_version"] == 1
    assert value["state"] == expected
    assert value["state"] in {
        "refresh_required", "refreshing", "ready", "error"
    }
    observed.append(expected)
    return value


index_freshness.request_refresh_locked(root)
assert_status("refresh_required")
index_freshness.authenticate_incremental_base = lambda _root: None


def successful_rebuild(_root, *, max_chunks, max_events):
    assert max_chunks > 0 and max_events > 0
    current = assert_status("refreshing")
    assert current["last_attempt_at"] is not None
    return False


index_freshness.rebuild_incremental_bounded = successful_rebuild
ready = index_freshness.run_pending_refresh(root)
assert ready == index_freshness.status(root)
assert_status("ready")
assert ready["diagnostic_code"] is None
assert ready["last_success_at"] is not None
assert ready["last_refresh_duration_ms"] >= ready["last_vault_lock_duration_ms"]

index_freshness.request_refresh_locked(root)
assert_status("refresh_required")


def failed_rebuild(_root, *, max_chunks, max_events):
    raise VaultError("bounded relationship refresh failed")


index_freshness.rebuild_incremental_bounded = failed_rebuild
failed = index_freshness.run_pending_refresh(root)
assert_status("error")
assert failed["diagnostic_code"] == "incremental_refresh_failed"
assert failed["last_success_at"] == ready["last_success_at"]
assert observed == [
    "refresh_required", "refreshing", "ready", "refresh_required", "error"
]
PY
  then
    pass "refresh状態を4値へ閉じ総時間とVault lock時間を別々に残す"
  else
    cat "$err" >&2
    fail "refresh状態を4値へ閉じ総時間とVault lock時間を別々に残す"
  fi
}

test_stale_refreshing_state_is_resumed_after_lock_reacquisition() {
  echo "test_stale_refreshing_state_is_resumed_after_lock_reacquisition:"
  local err="$TEST_ROOT/stale-refreshing.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness


root = pathlib.Path(sys.argv[1]) / "stale-refreshing-vault"
root.mkdir()
required = index_freshness.request_refresh_locked(root)
index_freshness._write(root, {
    **required,
    "state": "refreshing",
    "diagnostic_code": "refresh_in_progress",
    "last_attempt_at": "2026-08-26T00:00:00Z",
})
calls = []
index_freshness.authenticate_incremental_base = lambda _root: calls.append("auth")
index_freshness.rebuild_incremental_bounded = (
    lambda _root, *, max_chunks, max_events: calls.append("rebuild") or False
)
result = index_freshness.run_pending_refresh(root)
assert calls == ["auth", "rebuild"]
assert result["state"] == "ready"
assert result["diagnostic_code"] is None
PY
  then
    pass "refresh lock取得後に残ったrefreshingをstale runとして再開する"
  else
    cat "$err" >&2
    fail "refresh lock取得後に残ったrefreshingをstale runとして再開する"
  fi
}

test_rotation_and_sync_request_refresh_at_mutation_boundary() {
  echo "test_rotation_and_sync_request_refresh_at_mutation_boundary:"
  local err="$TEST_ROOT/mutation-boundary.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import chunk_rotation
import index_freshness
import sync as sync_module
from vault import GIT_SYNC_ALLOWLIST, HASH_KEY_PATH


base = pathlib.Path(sys.argv[1])

rotation_root = base / "rotation-vault"
rotation_root.mkdir()
(rotation_root / HASH_KEY_PATH).write_bytes(b"k" * 32)
rotation_events = []
real_process_job = chunk_rotation.process_job
chunk_rotation.ensure_safe_existing_root = lambda _root: None
chunk_rotation.load_config = lambda _root: {
    "git_sync_allowlist": list(GIT_SYNC_ALLOWLIST),
}
chunk_rotation.verify_recipient_state_hmac = lambda *_args: None
chunk_rotation.ensure_managed_gitignore = lambda _root: None
chunk_rotation.local_device = lambda _config, _root: ("device", pathlib.Path("id"))
chunk_rotation.acquire_inbox = lambda _root: [rotation_root / "job.pending"]
chunk_rotation.process_job = lambda *_args: rotation_events.append("published")


def rotation_request(actual_root):
    assert actual_root == rotation_root
    assert rotation_events == []
    rotation_events.append("requested")
    return index_freshness.request_refresh_locked(actual_root)


chunk_rotation.request_index_refresh_locked = rotation_request
chunk_rotation.rotate_locked(rotation_root)
assert rotation_events == ["requested", "published"]
assert index_freshness.status(rotation_root)["state"] == "refresh_required"

# Rotation and refresh share one event ceiling. A supported inbox can be much
# larger, so rotation must split it before immutable publication rather than
# creating a chunk that no bounded refresh can ever consume.
assert (
    chunk_rotation.MAX_EVENTS_PER_CHUNK
    == index_freshness.MAX_REFRESH_EVENTS
    == 5000
)
split_job = rotation_root / "split.jsonl.pending"
split_job.write_bytes(b"")
chunk_rotation.read_job = lambda *_args: [
    {"schema_version": 1, "ordinal": ordinal}
    for ordinal in range(5001)
]
published_sizes = []
chunk_rotation.publish = lambda *_args: published_sizes.append(len(_args[-1]))
chunk_rotation.fsync_directory = lambda _path: None
real_process_job(rotation_root, {}, pathlib.Path("id"), split_job)
assert published_sizes == [5000, 1]
assert not split_job.exists()

sync_root = base / "sync-vault"
sync_root.mkdir()
sync_events = []
sync_module.rotate_locked = lambda _root: None
sync_module.load_config = lambda _root: {"remote": "private-origin"}
sync_module.ensure_repository = lambda *_args: None
sync_module.strict_preflight = lambda _root: {}
sync_module.validate_candidate_chunks = lambda _root: None
sync_module.stage_allowlist = lambda _root: None
sync_module.commit_if_needed = lambda _root: False
sync_module.local_device = lambda *_args: ("device", pathlib.Path("id"))
sync_module.write_pending = lambda *_args, **_kwargs: None
sync_module.pull_rebase = lambda _root: None
sync_module.verify_after_pull = lambda *_args: None
def changed_import(_root):
    # import_chunks owns the mutation boundary: the refresh request is
    # durable before any decoded cache or receipt is published.
    sync_events.append("requested")
    index_freshness.request_refresh_locked(sync_root)
    sync_events.append("imported")
    return True


sync_module.import_chunks = changed_import
sync_module.push = lambda _root: None
sync_module.clear_pending = lambda _root: None


sync_module.request_index_refresh_locked = lambda _root: (_ for _ in ()).throw(
    AssertionError("sync_locked requested refresh after import publication")
)
sync_module.sync_locked(sync_root)
assert sync_events == ["requested", "imported"]
assert index_freshness.status(sync_root)["state"] == "refresh_required"

# A no-change daily sync must not run an empty graph/Atlas/storage rebuild.
unchanged_root = base / "unchanged-sync-vault"
unchanged_root.mkdir()
sync_events.clear()
sync_module.import_chunks = lambda _root: False
sync_module.request_index_refresh_locked = lambda _root: (_ for _ in ()).throw(
    AssertionError("unchanged sync requested an index refresh")
)
sync_module.sync_locked(unchanged_root)
assert sync_events == []
PY
  then
    pass "rotate publishとsync importの公開前に同じcoalescing refreshを要求する"
  else
    cat "$err" >&2
    fail "rotate publishとsync importの公開前に同じcoalescing refreshを要求する"
  fi
}

test_busy_refresh_lock_skips_concurrent_rebuild() {
  echo "test_busy_refresh_lock_skips_concurrent_rebuild:"
  local err="$TEST_ROOT/concurrent.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import pathlib
import sys

import index_freshness


root = pathlib.Path(sys.argv[1]) / "concurrent-vault"
root.mkdir()
index_freshness.request_refresh_locked(root)


@contextlib.contextmanager
def busy_lock(actual_root, *, blocking):
    assert actual_root == root
    assert blocking is False
    yield False


def forbidden(*_args, **_kwargs):
    raise AssertionError("a concurrent rebuild was started")


index_freshness._refresh_lock = busy_lock
index_freshness.authenticate_incremental_base = forbidden
index_freshness.rebuild_incremental_bounded = forbidden
result = index_freshness.run_pending_refresh(root)
assert result["state"] == "refresh_required"
assert index_freshness.status(root)["state"] == "refresh_required"
PY
  then
    pass "refresh lock取得済みなら競合rebuildを開始せずpendingを保持する"
  else
    cat "$err" >&2
    fail "refresh lock取得済みなら競合rebuildを開始せずpendingを保持する"
  fi
}

test_scheduler_orders_run_refresh_and_vault_locks() {
  echo "test_scheduler_orders_run_refresh_and_vault_locks:"
  local err="$TEST_ROOT/ordering.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import contextlib
import pathlib
import sys

import index_freshness
import scheduler


root = pathlib.Path(sys.argv[1]) / "ordered-vault"
root.mkdir()
events = []


@contextlib.contextmanager
def run_lock(actual_root, *, blocking):
    assert actual_root == root
    assert blocking is False
    events.append("run.enter")
    yield True
    events.append("run.exit")


@contextlib.contextmanager
def refresh_lock(actual_root, *, blocking):
    assert actual_root == root
    assert blocking is False
    assert events[-1] == "refresh.requested"
    events.append("refresh.enter")
    yield True
    events.append("refresh.exit")


@contextlib.contextmanager
def vault_lock(actual_root):
    assert actual_root == root
    assert events[-1] == "refresh.enter"
    events.append("vault.enter")
    yield
    events.append("vault.exit")


def sync(actual_root):
    assert actual_root == root
    assert events == ["run.enter"]
    events.append("sync")
    # sync_locked requests freshness while it owns the Vault mutation boundary.
    request(actual_root)


def request(actual_root):
    assert actual_root == root
    assert events[-1] == "sync"
    events.append("refresh.requested")
    return index_freshness.request_refresh_locked(actual_root)


def rebuild(actual_root, *, max_chunks, max_events):
    assert actual_root == root
    assert events[-1] == "vault.enter"
    events.append("rebuild")
    return False


scheduler._run_lock = run_lock
scheduler.ensure_safe_existing_root = lambda _root: None
scheduler.ensure_managed_gitignore = lambda _root: None
scheduler._load_state = lambda _root: None
scheduler._scheduler_due = lambda _root, _previous, _now: True
scheduler._write_state = lambda _root, _state: None
scheduler.sync = sync
scheduler.run_pending_refresh = index_freshness.run_pending_refresh
index_freshness._refresh_lock = refresh_lock
index_freshness.vault_lock = vault_lock
index_freshness.authenticate_incremental_base = lambda _root: None
index_freshness.rebuild_incremental_bounded = rebuild

scheduler.run(root)
assert events == [
    "run.enter",
    "sync",
    "refresh.requested",
    "refresh.enter",
    "vault.enter",
    "rebuild",
    "vault.exit",
    "refresh.exit",
    "run.exit",
]
PY
  then
    pass "scheduler run lock→sync→refresh lock→Vault lockの順を固定する"
  else
    cat "$err" >&2
    fail "scheduler run lock→sync→refresh lock→Vault lockの順を固定する"
  fi
}

test_missing_or_tampered_seal_requires_explicit_full_rebuild() {
  echo "test_missing_or_tampered_seal_requires_explicit_full_rebuild:"
  local err="$TEST_ROOT/full-only.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import index_freshness
from evidence_index import FullRebuildRequired as LegacyFullRebuildRequired
from vault import VaultError


root = pathlib.Path(sys.argv[1]) / "full-only-vault"
root.mkdir()
incremental_calls = []


def forbidden_incremental(*args, **kwargs):
    incremental_calls.append((args, kwargs))
    raise AssertionError("incremental rebuild must not run")


index_freshness.rebuild_incremental_bounded = forbidden_incremental
for message in ("arbitrary authentication failure", "wording may change"):
    index_freshness.request_refresh_locked(root)

    def reject(_root, reason=message):
        raise index_freshness.FullRebuildRequired(reason)

    index_freshness.authenticate_incremental_base = reject
    result = index_freshness.run_pending_refresh(root)
    assert result["state"] == "error"
    assert result["diagnostic_code"] == "full_rebuild_required"
    assert index_freshness.status(root) == result

assert incremental_calls == []

# A legacy/remote immutable chunk larger than the current producer ceiling is
# legal source evidence, but only an explicit atomic full rebuild can absorb it.
legacy_root = pathlib.Path(sys.argv[1]) / "legacy-oversized-vault"
legacy_root.mkdir()
index_freshness.request_refresh_locked(legacy_root)
index_freshness.authenticate_incremental_base = lambda _root: None
index_freshness.rebuild_incremental_bounded = lambda *_args, **_kwargs: (
    (_ for _ in ()).throw(
        LegacyFullRebuildRequired("legacy chunk requires full rebuild")
    )
)
legacy = index_freshness.run_pending_refresh(legacy_root)
assert legacy["state"] == "error"
assert legacy["diagnostic_code"] == "full_rebuild_required"
PY
  then
    pass "missing/tampered sealは増分禁止でfull_rebuild_requiredへ閉じる"
  else
    cat "$err" >&2
    fail "missing/tampered sealは増分禁止でfull_rebuild_requiredへ閉じる"
  fi
}

test_observatory_hides_counts_until_authenticated_refresh_is_ready() {
  echo "test_observatory_hides_counts_until_authenticated_refresh_is_ready:"
  local err="$TEST_ROOT/observatory.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import pathlib
import sys

import observatory


root = pathlib.Path(sys.argv[1]) / "observatory-vault"
root.mkdir()
calls = []


def forbidden(label):
    def reject(*_args, **_kwargs):
        calls.append(label)
        raise AssertionError(f"{label} ran while refresh was not ready")
    return reject


observatory._bounded_inbox_count = lambda _root: 7
observatory.read_sealed_query_locked = forbidden("sealed-query")
observatory._stored_receipts = forbidden("semantic-receipts")
observatory._stored_value_records = forbidden("value-cards")
observatory._index_storage_snapshot = forbidden("index-storage")
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

base = {
    "schema_version": 1,
    "requested_at": "2026-08-25T00:00:00Z",
    "last_attempt_at": "2026-08-25T00:00:01Z",
    "last_success_at": "2026-08-24T00:00:00Z",
    "last_refresh_duration_ms": 25,
    "last_vault_lock_duration_ms": 10,
}
for state, diagnostic in (
    ("refresh_required", "source_inventory_drift"),
    ("refreshing", "refresh_in_progress"),
    ("error", "full_rebuild_required"),
):
    refresh = {**base, "state": state, "diagnostic_code": diagnostic}
    observatory.index_freshness_status = lambda _root, item=refresh: item
    value = observatory.overview(root)
    assert value["schema_version"] == 2
    assert set(value) == {
        "schema_version",
        "command",
        "index_refresh",
        "recording",
        "episode_formation",
        "comparison_readiness",
        "semantic_coverage",
        "index_storage",
        "receipt_automation",
    }
    assert value["index_refresh"] == refresh
    assert value["recording"] == {
        "state": state,
        "index_schema_version": None,
        "events": None,
        "pending_events": 7,
    }
    assert all(
        item is None
        for item in value["episode_formation"].values()
    )
    assert all(
        item is None
        for item in value["comparison_readiness"].values()
    )
    assert all(item is None for item in value["semantic_coverage"].values())
    assert value["index_storage"] is None
    document = observatory.render_overview_html(value)
    assert "refresh" in document.lower() or "更新" in document

assert calls == []
PY
  then
    pass "Observatoryはready以外の3状態でsealed countsを非公開にする"
  else
    cat "$err" >&2
    fail "Observatoryはready以外の3状態でsealed countsを非公開にする"
  fi
}

test_incremental_relationships_only_score_new_pairs_and_reuse_saved_links() {
  echo "test_incremental_relationships_only_score_new_pairs_and_reuse_saved_links:"
  local err="$TEST_ROOT/relationship-delta.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT" 2>"$err" <<'PY'
import hashlib
import json
import pathlib
import sqlite3
import sys

import relationship_graph
import session_atlas
from chunk_rotation import canonical_json


database = pathlib.Path(sys.argv[1]) / "relationship-delta.sqlite"
connection = sqlite3.connect(database)
connection.executescript(
    """
    PRAGMA user_version = 5;
    PRAGMA foreign_keys = ON;
    CREATE TABLE source_events(
        event_id TEXT PRIMARY KEY,
        recorded_at TEXT NOT NULL,
        workspace_id TEXT,
        relationship_task_id_hash TEXT,
        relationship_branch_or_worktree_id TEXT,
        relationship_changed_file_fingerprints_json TEXT,
        relationship_changed_files_state TEXT
    );
    CREATE TABLE relationship_policies(
        policy_version TEXT PRIMARY KEY,
        schema_version INTEGER NOT NULL,
        policy_sha256 TEXT NOT NULL,
        policy_json TEXT NOT NULL
    );
    CREATE TABLE relationship_evidence(
        policy_version TEXT NOT NULL,
        evidence_id TEXT NOT NULL,
        evidence_json TEXT NOT NULL,
        PRIMARY KEY(policy_version, evidence_id),
        UNIQUE(policy_version, evidence_json),
        FOREIGN KEY(policy_version)
            REFERENCES relationship_policies(policy_version)
    );
    CREATE TABLE relationship_edges(
        policy_version TEXT NOT NULL,
        left_event_id TEXT NOT NULL,
        right_event_id TEXT NOT NULL,
        score INTEGER NOT NULL,
        decision TEXT NOT NULL,
        evidence_id TEXT NOT NULL,
        PRIMARY KEY(policy_version, left_event_id, right_event_id),
        FOREIGN KEY(policy_version, evidence_id)
            REFERENCES relationship_evidence(policy_version, evidence_id)
    );
    CREATE INDEX relationship_edges_link_candidates
    ON relationship_edges(
        policy_version, score DESC, left_event_id, right_event_id, decision
    ) WHERE decision IN ('link', 'component_conflict');
    CREATE TABLE episodes(
        policy_version TEXT NOT NULL,
        episode_id TEXT NOT NULL,
        member_count INTEGER NOT NULL,
        PRIMARY KEY(policy_version, episode_id)
    );
    CREATE TABLE episode_members(
        policy_version TEXT NOT NULL,
        episode_id TEXT NOT NULL,
        event_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        PRIMARY KEY(policy_version, episode_id, event_id)
    );
    """
)

events = [
    ("old-a", "2026-08-25T00:00:00Z"),
    ("old-b", "2026-08-25T00:01:00Z"),
    ("old-c", "2026-08-25T00:02:00Z"),
    ("new-d", "2026-08-25T00:03:00Z"),
]
connection.executemany(
    "INSERT INTO source_events VALUES (?, ?, ?, ?, ?, ?, ?)",
    [
        (event_id, recorded_at, "workspace", None, None, "[]", "complete")
        for event_id, recorded_at in events
    ],
)

policy = relationship_graph.validate_policy(relationship_graph.DEFAULT_POLICY)
encoded = canonical_json(policy).decode("utf-8")
connection.execute(
    "INSERT INTO relationship_policies VALUES (?, ?, ?, ?)",
    (
        policy["policy_version"],
        policy["schema_version"],
        hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
        encoded,
    ),
)
# The old A-B link is authenticated derived state from the previous generation.
# It must remain usable without asking score_pair to revisit this old-old pair.
saved_evidence = "{}"
saved_evidence_id = "sha256:" + hashlib.sha256(
    saved_evidence.encode("utf-8")
).hexdigest()
connection.execute(
    "INSERT INTO relationship_evidence VALUES (?, ?, ?)",
    (policy["policy_version"], saved_evidence_id, saved_evidence),
)
connection.execute(
    "INSERT INTO relationship_edges VALUES (?, ?, ?, ?, ?, ?)",
    (
        policy["policy_version"], "old-a", "old-b", 900, "link",
        saved_evidence_id,
    ),
)
connection.execute(
    "INSERT INTO episodes VALUES (?, ?, ?)",
    (policy["policy_version"], "old-episode", 2),
)
connection.executemany(
    "INSERT INTO episode_members VALUES (?, ?, ?, ?)",
    [
        (policy["policy_version"], "old-episode", "old-a", 0),
        (policy["policy_version"], "old-episode", "old-b", 1),
    ],
)
connection.commit()

scored = []


def instrumented_score(left, right, _policy):
    pair = tuple(sorted((left.event_id, right.event_id)))
    scored.append(pair)
    assert "new-d" in pair, f"old-old pair was rescored: {pair!r}"
    decision = "link" if pair == ("new-d", "old-b") else "no_link"
    return (700 if decision == "link" else 0, decision, json.dumps({"pair": pair}))


def forbidden_full_rebuild(*_args, **_kwargs):
    raise AssertionError("incremental relationship refresh fell back to full rebuild")


incremental = relationship_graph.refresh_relationships_incremental
relationship_graph.score_pair = instrumented_score
relationship_graph.rebuild_relationships = forbidden_full_rebuild
session_atlas.clear_session_atlas = lambda *_args, **_kwargs: None
session_atlas.materialize_session_atlas = lambda *_args, **_kwargs: None

statements = []
connection.set_trace_callback(statements.append)
incremental(connection, policy, {"new-d"})
connection.set_trace_callback(None)

assert scored
assert all("new-d" in pair for pair in scored)
normalized = [" ".join(statement.lower().split()) for statement in statements]
evidence_reads = [
    statement for statement in normalized
    if statement.startswith(
        "select evidence_id,evidence_json from relationship_evidence "
        "where policy_version="
    )
]
assert len(evidence_reads) == 1
assert not any(
    "from relationship_evidence where policy_version=" in statement
    and "and evidence_id=" in statement
    for statement in normalized
)
assert connection.execute("PRAGMA user_version").fetchone()[0] == 5
assert {
    row[1] for row in connection.execute("PRAGMA table_info(relationship_edges)")
} == {
    "policy_version", "left_event_id", "right_event_id", "score",
    "decision", "evidence_id",
}

assert connection.execute(
    "SELECT edge.score, edge.decision, edge.evidence_id, evidence.evidence_json "
    "FROM relationship_edges AS edge "
    "JOIN relationship_evidence AS evidence "
    "ON evidence.policy_version=edge.policy_version "
    "AND evidence.evidence_id=edge.evidence_id "
    "WHERE edge.policy_version=? "
    "AND edge.left_event_id='old-a' AND edge.right_event_id='old-b'",
    (policy["policy_version"],),
).fetchone() == (900, "link", saved_evidence_id, saved_evidence)

components = sorted(
    sorted(row[0] for row in connection.execute(
        "SELECT event_id FROM episode_members "
        "WHERE policy_version=? AND episode_id=? ORDER BY ordinal",
        (policy["policy_version"], episode_id),
    ))
    for (episode_id,) in connection.execute(
        "SELECT episode_id FROM episodes WHERE policy_version=?",
        (policy["policy_version"],),
    )
)
assert components == [["new-d", "old-a", "old-b"], ["old-c"]]
connection.close()
PY
  then
    pass "新規event関与pairだけをscoreし保存済みlink集合からEpisodeを再構成する"
  else
    cat "$err" >&2
    fail "新規event関与pairだけをscoreし保存済みlink集合からEpisodeを再構成する"
  fi
}

test_incremental_replays_prior_component_conflicts_in_global_order() {
  echo "test_incremental_replays_prior_component_conflicts_in_global_order:"
  local err="$TEST_ROOT/conflict-replay.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT/conflict.sqlite" 2>"$err" <<'PY'
import hashlib
import sqlite3
import sys

import relationship_graph
from evidence_index import configure, create_schema
from relationship_graph import DEFAULT_POLICY, Event


connection = sqlite3.connect(sys.argv[1])
configure(connection)
create_schema(connection)
connection.commit()
connection.execute("PRAGMA foreign_keys=OFF")
encoded_policy = relationship_graph.canonical_json(DEFAULT_POLICY).decode("utf-8")
policy_digest = hashlib.sha256(encoded_policy.encode("utf-8")).hexdigest()
connection.execute(
    "INSERT INTO relationship_policies VALUES (?,?,?,?)",
    ("default-v1", 1, policy_digest, encoded_policy),
)
evidence = "{}"
evidence_id = relationship_graph._evidence_id(evidence)
connection.execute(
    "INSERT INTO relationship_evidence VALUES (?,?,?)",
    ("default-v1", evidence_id, evidence),
)
connection.executemany(
    "INSERT INTO relationship_edges VALUES (?,?,?,?,?,?)",
    [
        ("default-v1", "A", "B", 90, "link", evidence_id),
        ("default-v1", "C", "D", 80, "link", evidence_id),
        ("default-v1", "B", "D", 10, "component_conflict", evidence_id),
    ],
)
events = [
    Event("A", "2026-08-26T00:00:00Z", None, "task-1", None, (), "missing"),
    Event("B", "2026-08-26T00:00:01Z", None, None, None, (), "missing"),
    Event("C", "2026-08-26T00:00:02Z", None, "task-2", None, (), "missing"),
    Event("D", "2026-08-26T00:00:03Z", None, None, None, (), "missing"),
    Event("E", "2026-08-26T00:00:04Z", None, "task-2", None, (), "missing"),
    Event("F", "2026-08-26T00:00:05Z", None, "task-2", None, (), "missing"),
]
relationship_graph._events = lambda _connection: events
relationship_graph._candidate_ids = (
    lambda _events, _policy, _new_event_ids=None: iter([
        ("B", "E"), ("B", "F")
    ])
)
new_evidence = '{"new":true}'
relationship_graph.score_pair = lambda *_args: (100, "link", new_evidence)
relationship_graph._replace_episodes = lambda *_args: 1
# Fill the cache with the existing row, then return the same new evidence from
# two candidates. The first insert must switch later misses to point lookup.
relationship_graph.MAX_INCREMENTAL_EVIDENCE_CACHE = 1

statements = []
connection.set_trace_callback(statements.append)
relationship_graph.refresh_relationships_incremental(
    connection, DEFAULT_POLICY, {"E", "F"}
)
connection.set_trace_callback(None)
decisions = dict(connection.execute(
    "SELECT left_event_id || right_event_id,decision "
    "FROM relationship_edges ORDER BY left_event_id,right_event_id"
))
assert decisions == {
    "AB": "component_conflict",
    "BD": "link",
    "BE": "link",
    "BF": "link",
    "CD": "link",
}

assert connection.execute(
    "SELECT COUNT(*) FROM relationship_evidence WHERE policy_version=?",
    ("default-v1",),
).fetchone()[0] == 2
assert connection.execute(
    "SELECT COUNT(*) FROM sqlite_master WHERE type='index' "
    "AND name='relationship_edges_link_candidates' "
    "AND lower(sql) LIKE '%where decision in%component_conflict%'"
).fetchone()[0] == 1
normalized = [" ".join(statement.lower().split()) for statement in statements]
assert not any("relationship_conflict_updates" in item for item in normalized)
assert connection.execute(
    "SELECT COUNT(*) FROM sqlite_temp_master "
    "WHERE name='relationship_decision_updates'"
).fetchone()[0] == 0
assert not any(
    item.startswith("update relationship_edges set decision='link' where policy_version")
    and "left_event_id=" not in item
    for item in normalized
)
assert not any("where policy_version='default-v1' and exists" in item for item in normalized)
targeted = [
    item for item in normalized
    if item.startswith("update relationship_edges set decision=")
]
assert len(targeted) == 2
assert all("left_event_id=" in item and "right_event_id=" in item for item in targeted)
PY
  then
    pass "増分でも旧conflictを含む全link候補をglobal順で再判定する"
  else
    cat "$err" >&2
    fail "増分でも旧conflictを含む全link候補をglobal順で再判定する"
  fi
}

test_incremental_decision_staging_crosses_batch_boundary() {
  echo "test_incremental_decision_staging_crosses_batch_boundary:"
  local err="$TEST_ROOT/decision-staging.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT/staging.sqlite" 2>"$err" <<'PY'
import hashlib
import sqlite3
import sys

import relationship_graph
from evidence_index import configure, create_schema
from relationship_graph import DEFAULT_POLICY, Event


connection = sqlite3.connect(sys.argv[1])
configure(connection)
create_schema(connection)
connection.commit()
connection.execute("PRAGMA foreign_keys=OFF")
encoded_policy = relationship_graph.canonical_json(DEFAULT_POLICY).decode("utf-8")
connection.execute(
    "INSERT INTO relationship_policies VALUES (?,?,?,?)",
    (
        "default-v1", 1,
        hashlib.sha256(encoded_policy.encode("utf-8")).hexdigest(),
        encoded_policy,
    ),
)
evidence = "{}"
evidence_id = relationship_graph._evidence_id(evidence)
connection.execute(
    "INSERT INTO relationship_evidence VALUES (?,?,?)",
    ("default-v1", evidence_id, evidence),
)
edges = [
    (
        "default-v1", f"L{index:04d}", f"R{index:04d}",
        10_000 - index, "link", evidence_id,
    )
    for index in range(1_001)
]
connection.executemany(
    "INSERT INTO relationship_edges VALUES (?,?,?,?,?,?)", edges
)
events = [
    Event(event_id, "2026-08-26T00:00:00Z", None, None, None, (), "missing")
    for edge in edges for event_id in edge[1:3]
]


class RejectingComponents:
    def __init__(self, _events):
        pass

    def join(self, _left, _right):
        return False


relationship_graph._events = lambda _connection: events
relationship_graph._candidate_ids = lambda *_args, **_kwargs: iter(())
relationship_graph.Components = RejectingComponents
relationship_graph._replace_episodes = lambda *_args: 1
statements = []
connection.set_trace_callback(statements.append)
relationship_graph.refresh_relationships_incremental(
    connection, DEFAULT_POLICY, {"L0000"}
)
connection.set_trace_callback(None)
assert connection.execute(
    "SELECT COUNT(*) FROM relationship_edges "
    "WHERE decision='component_conflict'"
).fetchone()[0] == 1_001
assert connection.execute(
    "SELECT COUNT(*) FROM sqlite_temp_master "
    "WHERE name='relationship_decision_updates'"
).fetchone()[0] == 0
targeted = [
    " ".join(statement.lower().split())
    for statement in statements
    if statement.lower().startswith("update relationship_edges set decision=")
]
assert len(targeted) == 1_001
assert all("left_event_id=" in item and "right_event_id=" in item for item in targeted)
connection.close()
PY
  then
    pass "1,001 decision差分を有限batchでstage・PK更新してtempを回収する"
  else
    cat "$err" >&2
    fail "1,001 decision差分を有限batchでstage・PK更新してtempを回収する"
  fi
}

test_authenticated_open_defers_full_integrity_scan_to_writer_boundary() {
  echo "test_authenticated_open_defers_full_integrity_scan_to_writer_boundary:"
  local err="$TEST_ROOT/open-validation.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$TEST_ROOT/open.sqlite" 2>"$err" <<'PY'
import pathlib
import sys

import evidence_index


path = pathlib.Path(sys.argv[1])
connection = evidence_index.sqlite3.connect(path, isolation_level=None)
evidence_index.configure(connection)
evidence_index.create_schema(connection)
connection.close()


def forbidden(_connection):
    raise AssertionError("authenticated open repeated a full integrity scan")


evidence_index.validate_database = forbidden
writable = evidence_index._open_existing(path, authenticated=True)
writable.close()
PY
  then
    pass "認証済みopenは全表integrity scanを重ねずwriter完了境界へ委ねる"
  else
    cat "$err" >&2
    fail "認証済みopenは全表integrity scanを重ねずwriter完了境界へ委ねる"
  fi
}

test_repeated_requests_coalesce_and_one_run_is_bounded
test_refresh_state_machine_is_finite_and_measured
test_stale_refreshing_state_is_resumed_after_lock_reacquisition
test_rotation_and_sync_request_refresh_at_mutation_boundary
test_busy_refresh_lock_skips_concurrent_rebuild
test_scheduler_orders_run_refresh_and_vault_locks
test_missing_or_tampered_seal_requires_explicit_full_rebuild
test_observatory_hides_counts_until_authenticated_refresh_is_ready
test_incremental_relationships_only_score_new_pairs_and_reuse_saved_links
test_incremental_replays_prior_component_conflicts_in_global_order
test_incremental_decision_staging_crosses_batch_boundary
test_authenticated_open_defers_full_integrity_scan_to_writer_boundary

echo
echo "Index freshness tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
