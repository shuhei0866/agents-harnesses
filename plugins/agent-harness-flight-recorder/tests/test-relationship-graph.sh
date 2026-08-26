#!/usr/bin/env bash
# Event v2/v3 / versioned relationship graph contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
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

run_cli() {
  local state="$1"
  shift
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$state" "$CLI" "$@"
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

init_vault() {
  local base="$1"
  local remote="$base/remote.git" state="$base/vault"
  local recovery="$base/recovery.agekey"
  mkdir -p "$base"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
}

append_v1_event() {
  local state="$1" event_id="$2" recorded_at="$3" harness="$4"
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" "$event_id" "$recorded_at" "$harness" <<'PY'
import json
import pathlib
import sys

path, event_id, recorded_at, harness = sys.argv[1:]
event = {
    "schema_version": 1,
    "event_id": event_id,
    "recorded_at": recorded_at,
    "harness": harness,
    "source_event": "Stop",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + "1" * 24,
    "turn_id_hash": None,
    "workspace_id": "sha256:" + "2" * 24,
    "model": None,
    "permission_mode": None,
    "tool": None,
    "metrics": None,
    "outcome": None,
}
with pathlib.Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

append_v2_event() {
  local state="$1" event_id="$2" recorded_at="$3" harness="$4"
  local task_hash="$5" workspace_hash="$6" branch_hash="$7"
  local files_csv="$8" files_state="${9:-complete}"
  mkdir -p "$state/inbox"
  python3 - \
    "$state/inbox/events.jsonl" "$event_id" "$recorded_at" "$harness" \
    "$task_hash" "$workspace_hash" "$branch_hash" "$files_csv" "$files_state" <<'PY'
import json
import pathlib
import sys

(
    path,
    event_id,
    recorded_at,
    harness,
    task_hash,
    workspace_hash,
    branch_hash,
    files_csv,
    files_state,
) = sys.argv[1:]

def nullable(value):
    return None if value == "-" else value

files = [] if files_csv == "-" else files_csv.split(",")
task = nullable(task_hash)
event = {
    "schema_version": 2,
    "event_id": event_id,
    "recorded_at": recorded_at,
    "harness": harness,
    "source_event": "Stop",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + "a" * 24,
    "turn_id_hash": None,
    "workspace_id": nullable(workspace_hash),
    "model": None,
    "permission_mode": None,
    "tool": None,
    "metrics": None,
    "outcome": None,
    "relationship_context": {
        "task_id_hash": task,
        "task_source": "payload" if task is not None else None,
        "branch_or_worktree_id": nullable(branch_hash),
        "changed_file_fingerprints": files,
        "changed_files_state": files_state,
    },
}
with pathlib.Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

graph_snapshot() {
  python3 - "$1" <<'PY'
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
snapshot = {}
for table in (
    "relationship_policies",
    "relationship_evidence",
    "relationship_edges",
    "episodes",
    "episode_members",
):
    rows = [tuple(row) for row in connection.execute(f'SELECT * FROM "{table}"')]
    snapshot[table] = sorted(rows, key=repr)
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":"), default=str))
PY
}

default_graph_snapshot() {
  python3 - "$1" <<'PY'
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
snapshot = {}
for table in (
    "relationship_policies",
    "relationship_evidence",
    "relationship_edges",
    "episodes",
    "episode_members",
):
    rows = [
        tuple(row)
        for row in connection.execute(
            f'SELECT * FROM "{table}" WHERE policy_version = ?',
            ("default-v1",),
        )
    ]
    snapshot[table] = sorted(rows, key=repr)
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":"), default=str))
PY
}

source_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = list(connection.execute(
    "SELECT event_id, canonical_event_json FROM source_events ORDER BY event_id"
))
digest = hashlib.sha256()
for event_id, canonical in rows:
    digest.update(event_id.encode())
    digest.update(b"\0")
    digest.update(canonical.encode())
    digest.update(b"\0")
print(digest.hexdigest())
PY
}

test_recorder_emits_private_domain_separated_event_v2() {
  echo "test_recorder_emits_private_domain_separated_event_v2:"
  local base="$TEST_ROOT/recorder-v2"
  local input="$base/input.json"
  local output="$base/events.jsonl" out="$base/out" err="$base/err"
  mkdir -p "$base"
  python3 - "$input" <<'PY'
import json
import pathlib
import sys

canary = "RAW_RELATIONSHIP_CANARY_79b7.py"
payload = {
    "hook_event_name": "Stop",
    "session_id": "session",
    "cwd": "/private/workspace",
    "task_id": canary,
    "branch_or_worktree": canary,
    "changed_files": [
        canary,
        "private/second.py",
        ".env",
        "node_modules/secret.ts",
        "../escape.py",
        "/absolute.py",
        "notes.txt",
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  AGENT_FLIGHT_RECORDER_PATH="$output" \
    AGENT_FLIGHT_RECORDER_HASH_KEY="stable-relationship-test-key" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-25T00:00:00Z" \
    "$RECORDER" --harness claude-code <"$input" >"$out" 2>"$err"

  if python3 - "$output" <<'PY' 2>/dev/null
import json
import pathlib
import re
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
assert "RAW_RELATIONSHIP_CANARY_79b7" not in raw
assert "/private/workspace" not in raw
assert "private/second.py" not in raw
event = json.loads(raw)
assert event["schema_version"] == 3
assert event["operation_kind"] is None
context = event["relationship_context"]
assert set(context) == {
    "task_id_hash",
    "task_source",
    "branch_or_worktree_id",
    "changed_file_fingerprints",
    "changed_files_state",
}
identifiers = [
    context["task_id_hash"],
    context["branch_or_worktree_id"],
    context["changed_file_fingerprints"][0],
]
assert all(re.fullmatch(r"sha256:[0-9a-f]{24}", item) for item in identifiers)
# Identical raw text in three semantic domains must not be linkable by equality.
assert len({identifiers[0], identifiers[1], identifiers[2]}) == 3
assert len(context["changed_file_fingerprints"]) == 2
assert context["task_source"] == "payload"
assert context["changed_files_state"] == "complete"
PY
  then
    pass "Event v3はraw値を捨てprivacy-safe contextだけを保存する"
  else
    fail "Event v3はraw値を捨てprivacy-safe contextだけを保存する"
  fi

  python3 - "$input" <<'PY'
import json
import pathlib
import sys

payload = {
    "hook_event_name": "Stop",
    "session_id": "session",
    "cwd": "/private/workspace",
    "changed_files": [f"src/TRUNCATION_CANARY_{number:04d}.py" for number in range(300)],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload), encoding="utf-8")
PY
  : >"$output"
  AGENT_FLIGHT_RECORDER_PATH="$output" \
    AGENT_FLIGHT_RECORDER_HASH_KEY="stable-relationship-test-key" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-25T00:00:01Z" \
    "$RECORDER" --harness codex <"$input" >"$out" 2>"$err"
  if python3 - "$output" <<'PY' 2>/dev/null
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
event = json.loads(raw)
context = event["relationship_context"]
assert context["changed_files_state"] == "truncated"
assert 0 < len(context["changed_file_fingerprints"]) < 300
assert "TRUNCATION_CANARY_" not in raw
PY
  then
    pass "changed-file fingerprintsをboundedに収集しtruncationを明示する"
  else
    fail "changed-file fingerprintsをboundedに収集しtruncationを明示する"
  fi

  local repo="$base/repo" git_input="$base/git-input.json"
  local git_output="$base/git-events.jsonl"
  git init -q "$repo"
  printf '%s\n' 'initial' >"$repo/tracked.py"
  git -C "$repo" add tracked.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    commit -qm initial
  printf '%s\n' 'changed' >>"$repo/tracked.py"
  printf '%s\n' 'new' >"$repo/new.py"
  printf '%s\n' 'secret' >"$repo/.env"
  python3 - "$git_input" "$repo" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
    json.dumps({
        "hook_event_name": "Stop",
        "session_id": "session",
        "cwd": sys.argv[2],
    }),
    encoding="utf-8",
)
PY
  AGENT_FLIGHT_RECORDER_PATH="$git_output" \
    AGENT_FLIGHT_RECORDER_HASH_KEY="stable-relationship-test-key" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-25T00:00:02Z" \
    "$RECORDER" --harness codex <"$git_input" >"$out" 2>"$err"
  if python3 - "$git_output" <<'PY' 2>/dev/null
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
context = json.loads(raw)["relationship_context"]
assert context["changed_files_state"] == "complete"
assert len(context["changed_file_fingerprints"]) == 2
assert context["branch_or_worktree_id"] is not None
assert "tracked.py" not in raw
assert "new.py" not in raw
assert ".env" not in raw
PY
  then
    pass "Git fallbackはallowlistedなtracked・untracked pathだけをHMAC化する"
  else
    fail "Git fallbackはallowlistedなtracked・untracked pathだけをHMAC化する"
  fi
}

test_mixed_v1_v2_inbox_is_lossless_and_versioned() {
  echo "test_mixed_v1_v2_inbox_is_lossless_and_versioned:"
  local base="$TEST_ROOT/mixed"
  local state="$base/vault"
  init_vault "$base" || {
    fail "mixed-version fixtureを初期化できる"
    return
  }
  append_v1_event "$state" "00000000-0000-4000-8000-000000000001" \
    "2026-07-25T01:00:00Z" claude-code
  append_v2_event "$state" "00000000-0000-4000-8000-000000000002" \
    "2026-07-25T01:00:01Z" codex \
    "sha256:111111111111111111111111" \
    "sha256:222222222222222222222222" \
    "sha256:333333333333333333333333" \
    "sha256:444444444444444444444444"
  if ! run_cli "$state" sync >/dev/null 2>&1; then
    fail "mixed Event v1/v2 inboxを同期できる"
    return
  fi
  if python3 - "$state" <<'PY' 2>/dev/null
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
chunks = []
events = []
for path in sorted((root / "cache" / "imported").rglob("*.jsonl")):
    rows = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line
    ]
    chunks.append((rows[0]["event_schema_version"], rows[0]["event_count"]))
    events.extend(rows[1:])
assert sorted(chunks) == [(1, 1), (2, 1)]
assert {event["schema_version"] for event in events} == {1, 2}
assert {event["event_id"] for event in events} == {
    "00000000-0000-4000-8000-000000000001",
    "00000000-0000-4000-8000-000000000002",
}
PY
  then
    pass "mixed Event v1/v2をschema version別chunkへlosslessに分離する"
  else
    fail "mixed Event v1/v2をschema version別chunkへlosslessに分離する"
  fi
}

build_rich_fixture() {
  local base="$1"
  local state="$base/vault"
  local task_one="sha256:100000000000000000000001"
  local task_two="sha256:200000000000000000000002"
  local workspace="sha256:300000000000000000000003"
  local workspace_two="sha256:300000000000000000000004"
  local branch="sha256:400000000000000000000004"
  local file_one="sha256:500000000000000000000005"
  local file_two="sha256:500000000000000000000006"
  init_vault "$base" || return 1
  # A/B: strong cross-harness match. C is an unknown-task bridge. D has an
  # explicit contradictory task and must never join A/B through C.
  append_v2_event "$state" "10000000-0000-4000-8000-000000000001" \
    "2026-07-25T02:00:00Z" claude-code "$task_one" "$workspace" "$branch" \
    "$file_one,$file_two"
  append_v2_event "$state" "10000000-0000-4000-8000-000000000002" \
    "2026-07-25T02:01:00Z" codex "$task_one" "$workspace" "$branch" "$file_two"
  append_v2_event "$state" "10000000-0000-4000-8000-000000000003" \
    "2026-07-25T02:02:00Z" claude-code - "$workspace" "$branch" "$file_two"
  append_v2_event "$state" "10000000-0000-4000-8000-000000000004" \
    "2026-07-25T02:03:00Z" codex "$task_two" "$workspace" "$branch" "$file_two"
  # E/F deliberately share a workspace and close timestamps while all optional
  # relationship identifiers are missing. Missing must not mean "equal".
  append_v2_event "$state" "10000000-0000-4000-8000-000000000005" \
    "2026-07-25T03:00:00Z" claude-code - "$workspace_two" - - missing
  append_v2_event "$state" "10000000-0000-4000-8000-000000000006" \
    "2026-07-25T03:00:30Z" codex - "$workspace_two" - - missing
  # Exercise the actual recorder privacy boundary as part of the persisted
  # fixture. The raw input lives outside the Vault and must never enter chunks
  # or SQLite.
  python3 - "$base/privacy-input.json" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "hook_event_name": "Stop",
    "session_id": "privacy-session",
    "cwd": "/private/workspace",
    "task_id": "RAW_RELATIONSHIP_CANARY_79b7",
    "branch_or_worktree": "RAW_BRANCH_CANARY_80c8",
    "changed_files": ["private/second.py"],
}), encoding="utf-8")
PY
  FLIGHT_RECORDER_STATE_DIR="$state" \
    AGENT_FLIGHT_RECORDER_NOW="2026-07-25T04:00:00Z" \
    "$RECORDER" --harness claude-code <"$base/privacy-input.json" >/dev/null 2>&1
  run_cli "$state" sync >/dev/null 2>&1
}

ensure_rich_graph() {
  local base="$TEST_ROOT/rich"
  local state="$base/vault"
  if [[ ! -f "$state/index/vault.sqlite" ]]; then
    build_rich_fixture "$base" || return 1
    run_cli "$state" rebuild-index >/dev/null 2>&1 || return 1
  fi
}

test_index_v5_normalizes_canonical_six_feature_evidence() {
  echo "test_index_v5_normalizes_canonical_six_feature_evidence:"
  local state="$TEST_ROOT/rich/vault"
  local db="$state/index/vault.sqlite"
  ensure_rich_graph || {
    fail "relationship graph fixtureを構築できる"
    return
  }
  if python3 - "$db" <<'PY' 2>/dev/null
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute("PRAGMA user_version").fetchone()[0] == 5
tables = {
    row[0]
    for row in connection.execute(
        "SELECT name FROM sqlite_schema WHERE type='table'"
    )
}
assert {
    "relationship_policies",
    "relationship_evidence",
    "relationship_edges",
    "episodes",
    "episode_members",
    "session_atlas_facets",
} <= tables
metadata = dict(connection.execute("SELECT key, value FROM schema_metadata"))
assert metadata["event_schema_versions"] == "1,2,3"
assert metadata["schema_version"] == "5"

edge_columns = {
    row[1] for row in connection.execute("PRAGMA table_info(relationship_edges)")
}
assert "evidence_id" in edge_columns
assert "evidence_json" not in edge_columns
evidence_columns = {
    row[1] for row in connection.execute("PRAGMA table_info(relationship_evidence)")
}
assert evidence_columns == {"policy_version", "evidence_id", "evidence_json"}
edge_foreign_keys = {
    (row[3], row[2], row[4])
    for row in connection.execute("PRAGMA foreign_key_list(relationship_edges)")
}
assert ("evidence_id", "relationship_evidence", "evidence_id") in edge_foreign_keys

row = connection.execute(
    """
    SELECT re.score, re.decision, re.evidence_id, ev.evidence_json
    FROM relationship_edges AS re
    JOIN relationship_evidence AS ev
      ON ev.policy_version = re.policy_version
     AND ev.evidence_id = re.evidence_id
    WHERE re.left_event_id = ? AND re.right_event_id = ?
    """,
    (
        "10000000-0000-4000-8000-000000000001",
        "10000000-0000-4000-8000-000000000002",
    ),
).fetchone()
assert row is not None
score, decision, evidence_id, encoded = row
assert isinstance(score, int)
assert decision == "link"
assert evidence_id == "sha256:" + __import__("hashlib").sha256(
    encoded.encode("utf-8")
).hexdigest()
evidence = json.loads(encoded)
assert set(evidence) == {
    "explicit_task_id",
    "workspace_id",
    "branch_or_worktree_id",
    "time_distance",
    "changed_file_fingerprints",
    "contradictory_task_ids",
}
assert evidence["explicit_task_id"]["state"] == "match"
assert evidence["workspace_id"]["state"] == "match"
assert evidence["branch_or_worktree_id"]["state"] == "match"
assert evidence["time_distance"]["seconds"] == 60
assert evidence["changed_file_fingerprints"]["intersection_count"] == 1
assert evidence["contradictory_task_ids"]["state"] == "clear"
for feature in evidence.values():
    assert isinstance(feature["contribution"], int)
assert encoded == json.dumps(evidence, sort_keys=True, separators=(",", ":"))
PY
  then
    pass "SQLite v5はcanonicalな6特徴証憑を決定論的IDの辞書へ正規化する"
  else
    fail "SQLite v5はcanonicalな6特徴証憑を決定論的IDの辞書へ正規化する"
  fi
}

test_cross_harness_veto_bridge_missing_and_singletons() {
  echo "test_cross_harness_veto_bridge_missing_and_singletons:"
  local state="$TEST_ROOT/rich/vault"
  local db="$state/index/vault.sqlite"
  ensure_rich_graph || {
    fail "episode semantics fixtureを構築できる"
    return
  }
  if python3 - "$db" <<'PY' 2>/dev/null
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
a, b, c, d, e, f = [
    f"10000000-0000-4000-8000-{number:012d}" for number in range(1, 7)
]
members = {}
for episode_id, event_id in connection.execute(
    "SELECT episode_id, event_id FROM episode_members"
):
    members.setdefault(episode_id, set()).add(event_id)
assert any({a, b} <= group for group in members.values())  # cross-harness
assert not any({a, d} <= group or {b, d} <= group for group in members.values())
# The unknown-task C must not create a transitive bridge between contradictory
# explicit tasks, regardless of which side claims it.
assert not any({a, c, d} <= group or {b, c, d} <= group for group in members.values())
assert any(group == {e} for group in members.values())
assert any(group == {f} for group in members.values())

logical_edges = list(connection.execute(
    """
    SELECT re.decision, ev.evidence_json
    FROM relationship_edges AS re
    JOIN relationship_evidence AS ev
      ON ev.policy_version = re.policy_version
     AND ev.evidence_id = re.evidence_id
    WHERE re.policy_version = 'default-v1'
    """
))
assert len(logical_edges) == connection.execute(
    "SELECT COUNT(*) FROM relationship_edges WHERE policy_version='default-v1'"
).fetchone()[0]
assert {row[0] for row in logical_edges} == {
    "link", "no_link", "hard_veto", "component_conflict",
}
for _decision, encoded in logical_edges:
    assert encoded == json.dumps(
        json.loads(encoded), sort_keys=True, separators=(",", ":")
    )

veto = connection.execute(
    """
    SELECT re.decision, ev.evidence_json
    FROM relationship_edges AS re
    JOIN relationship_evidence AS ev
      ON ev.policy_version = re.policy_version
     AND ev.evidence_id = re.evidence_id
    WHERE re.left_event_id = ? AND re.right_event_id = ?
    """,
    (a, d),
).fetchone()
assert veto is not None and veto[0] == "hard_veto"
assert json.loads(veto[1])["contradictory_task_ids"]["state"] == "contradiction"

missing = connection.execute(
    """
    SELECT re.decision, ev.evidence_json
    FROM relationship_edges AS re
    JOIN relationship_evidence AS ev
      ON ev.policy_version = re.policy_version
     AND ev.evidence_id = re.evidence_id
    WHERE re.left_event_id = ? AND re.right_event_id = ?
    """,
    (e, f),
).fetchone()
assert missing is not None and missing[0] != "link"
evidence = json.loads(missing[1])
assert evidence["explicit_task_id"]["state"] == "missing"
assert evidence["branch_or_worktree_id"]["state"] == "missing"
assert evidence["changed_file_fingerprints"]["state"] == "missing"
PY
  then
    pass "cross-harness link・hard veto・bridge防止・missing・singletonを区別する"
  else
    fail "cross-harness link・hard veto・bridge防止・missing・singletonを区別する"
  fi
}

test_candidate_generation_and_full_persistence_are_bounded_streams() {
  echo "test_candidate_generation_and_full_persistence_are_bounded_streams:"
  local db="$TEST_ROOT/streaming-candidates.sqlite"
  local err="$TEST_ROOT/streaming-candidates.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$db" <<'PY' 2>"$err"
import builtins
import inspect
import pathlib
import sqlite3
import sys

import relationship_graph
from evidence_index import configure, create_schema
from relationship_graph import DEFAULT_POLICY, Event, _candidate_ids


def event(number, timestamp, task):
    return Event(
        f"40000000-0000-4000-8000-{number:012d}",
        timestamp,
        "sha256:" + "a" * 24,
        task,
        None,
        (),
        "missing",
    )


task_one = "sha256:" + "1" * 24
task_two = "sha256:" + "2" * 24
semantic_events = [
    event(1, "2026-07-25T00:00:00Z", task_one),
    event(2, "2026-07-25T00:00:10Z", task_one),
    event(3, "2026-07-25T00:00:20Z", task_two),
    event(4, "2026-07-25T02:00:00Z", task_one),
]

# The production candidate API is an iterator contract, not a returned
# O(n^2) set/list. It merges the window route and outside-window same-task
# route without emitting the overlap twice.
assert inspect.isgeneratorfunction(_candidate_ids)


class NoSliceList(list):
    def __getitem__(self, index):
        if isinstance(index, slice):
            raise AssertionError("candidate generation copied the chronological tail")
        return super().__getitem__(index)


original_candidate_sorted = builtins.sorted
relationship_graph.sorted = lambda values, *args, **kwargs: NoSliceList(
    original_candidate_sorted(values, *args, **kwargs)
)
candidate_iterator = _candidate_ids(semantic_events, DEFAULT_POLICY)
assert inspect.isgenerator(candidate_iterator)
try:
    pairs = list(candidate_iterator)
finally:
    relationship_graph.sorted = original_candidate_sorted
assert len(pairs) == len(set(pairs))
assert all(left < right for left, right in pairs)
a, b, c, d = [item.event_id for item in semantic_events]
assert set(pairs) == {
    (a, b),
    (a, c),
    (b, c),
    (a, d),
    (b, d),
}
assert (c, d) not in pairs


database = pathlib.Path(sys.argv[1])
inner = sqlite3.connect(database)
configure(inner)
create_schema(inner)
event_count = 160
inner.execute(
    "INSERT INTO source_chunks VALUES (?,?,?,?,?,?,?,?,?)",
    (
        "stream-chunk", "devices/stream", "blob", "vault", "device",
        "2026-07-25T00:00:00Z", 2, event_count, "digest",
    ),
)
source_rows = []
for number in range(event_count):
    source_rows.append((
        f"60000000-0000-4000-8000-{number:012d}",
        "stream-chunk", number, 2, "2026-07-25T00:00:00Z", "codex",
        "Stop", "turn.completed", "sha256:" + "a" * 24, None,
        "sha256:" + "b" * 24, None, None, None, None, None, None,
        None, None, None, "[]", "missing", "{}",
    ))
inner.executemany(
    "INSERT INTO source_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    source_rows,
)
inner.commit()


class CandidateStream:
    def __init__(self, events):
        self.ids = [item.event_id for item in events]
        self.left = 0
        self.right = 1
        self.consumed = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self.left >= len(self.ids) - 1:
            raise StopIteration
        value = (self.ids[self.left], self.ids[self.right])
        self.consumed += 1
        self.right += 1
        if self.right >= len(self.ids):
            self.left += 1
            self.right = self.left + 1
        return value


stream_holder = {}
candidate_calls = []


def instrumented_candidates(events, policy, new_event_ids=None):
    assert policy["policy_version"] == "default-v1"
    assert new_event_ids is None
    candidate_calls.append(len(events))
    stream = CandidateStream(events)
    stream_holder["value"] = stream
    return stream


original_sorted = sorted


def guarded_sorted(values, *args, **kwargs):
    if isinstance(values, CandidateStream):
        raise AssertionError("candidate stream was materialized with sorted()")
    return original_sorted(values, *args, **kwargs)


class TrackingConnection:
    def __init__(self, connection):
        self.connection = connection
        self.edge_batch_sizes = []
        self.edge_insert_consumed = []
        self.edge_rows = 0

    def __getattr__(self, name):
        return getattr(self.connection, name)

    def execute(self, sql, parameters=()):
        normalized = " ".join(sql.lower().split())
        if normalized.startswith("insert") and "relationship_edges" in normalized:
            raise AssertionError("relationship edges must use bounded batch insert")
        return self.connection.execute(sql, parameters)

    def executemany(self, sql, rows):
        normalized = " ".join(sql.lower().split())
        if not (
            normalized.startswith("insert")
            and "relationship_edges" in normalized
        ):
            return self.connection.executemany(sql, rows)
        stream = stream_holder["value"]
        self.edge_insert_consumed.append(stream.consumed)
        count = 0

        def bounded_rows():
            nonlocal count
            for row in rows:
                count += 1
                assert count <= 10_000
                yield row

        result = self.connection.executemany(sql, bounded_rows())
        self.edge_batch_sizes.append(count)
        self.edge_rows += count
        return result


relationship_graph._candidate_ids = instrumented_candidates
relationship_graph.sorted = guarded_sorted
tracked = TrackingConnection(inner)
edge_count, _episode_count = relationship_graph.rebuild_relationships(
    tracked, DEFAULT_POLICY
)
inner.commit()
expected_edges = event_count * (event_count - 1) // 2
assert candidate_calls == [event_count]
assert edge_count == expected_edges
assert tracked.edge_rows == expected_edges
assert len(tracked.edge_batch_sizes) >= 2
assert max(tracked.edge_batch_sizes) <= 10_000
assert tracked.edge_insert_consumed[0] < expected_edges
previous_consumed = 0
for consumed in tracked.edge_insert_consumed:
    assert 0 < consumed - previous_consumed <= 10_000
    previous_consumed = consumed
assert inner.execute(
    "SELECT COUNT(*) FROM relationship_edges"
).fetchone()[0] == expected_edges
assert inner.execute(
    "SELECT COUNT(*) FROM relationship_evidence"
).fetchone()[0] == 1
PY
  then
    pass "full candidateを重複なくstreamしedge insertを10k以下へ分割する"
  else
    cat "$err" >&2
    fail "full candidateを重複なくstreamしedge insertを10k以下へ分割する"
  fi
}

test_repeated_evidence_dictionary_has_no_orphans_and_bounded_bytes_per_edge() {
  echo "test_repeated_evidence_dictionary_has_no_orphans_and_bounded_bytes_per_edge:"
  local db="$TEST_ROOT/repeated-evidence.sqlite"
  local err="$TEST_ROOT/repeated-evidence.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$db" <<'PY' 2>"$err"
import hashlib
import json
import pathlib
import sqlite3
import sys

from evidence_index import configure, create_schema
from relationship_graph import DEFAULT_POLICY, rebuild_relationships


database = pathlib.Path(sys.argv[1])
connection = sqlite3.connect(database)
configure(connection)
create_schema(connection)
assert connection.execute("PRAGMA user_version").fetchone()[0] == 5

event_count = 128
connection.execute(
    "INSERT INTO source_chunks VALUES (?,?,?,?,?,?,?,?,?)",
    (
        "repeat-chunk", "devices/repeat", "blob", "vault", "device",
        "2026-07-25T00:00:00Z", 2, event_count, "digest",
    ),
)
events = []
for number in range(event_count):
    values = [
        f"50000000-0000-4000-8000-{number:012d}",
        "repeat-chunk",
        number,
        2,
        "2026-07-25T00:00:00Z",
        "codex",
        "Stop",
        "turn.completed",
        "sha256:" + "a" * 24,
        None,
        "sha256:" + "b" * 24,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        None,
        "[]",
        "missing",
        "{}",
    ]
    assert len(values) == 23
    events.append(tuple(values))
connection.executemany(
    "INSERT INTO source_events VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    events,
)
connection.commit()
page_size = connection.execute("PRAGMA page_size").fetchone()[0]
before_bytes = connection.execute("PRAGMA page_count").fetchone()[0] * page_size

edge_count, episode_count = rebuild_relationships(connection, DEFAULT_POLICY)
connection.commit()
after_bytes = connection.execute("PRAGMA page_count").fetchone()[0] * page_size
expected_edges = event_count * (event_count - 1) // 2
assert edge_count == expected_edges
assert episode_count == event_count
assert connection.execute(
    "SELECT COUNT(*) FROM relationship_edges"
).fetchone()[0] == expected_edges
assert connection.execute(
    "SELECT COUNT(*) FROM relationship_edges WHERE decision='no_link'"
).fetchone()[0] == expected_edges
assert connection.execute(
    "SELECT COUNT(*) FROM relationship_evidence"
).fetchone()[0] == 1
evidence_id, encoded = connection.execute(
    "SELECT evidence_id,evidence_json FROM relationship_evidence"
).fetchone()
assert encoded == json.dumps(json.loads(encoded), sort_keys=True, separators=(",", ":"))
assert evidence_id == "sha256:" + hashlib.sha256(encoded.encode("utf-8")).hexdigest()
connection.execute("SAVEPOINT duplicate_evidence")
try:
    connection.execute(
        "INSERT INTO relationship_evidence VALUES (?,?,?)",
        ("default-v1", "sha256:" + "f" * 64, encoded),
    )
except sqlite3.IntegrityError:
    pass
else:
    raise AssertionError("duplicate canonical evidence was accepted for one policy")
finally:
    connection.execute("ROLLBACK TO duplicate_evidence")
    connection.execute("RELEASE duplicate_evidence")
assert connection.execute(
    """
    SELECT COUNT(*)
    FROM relationship_edges AS re
    LEFT JOIN relationship_evidence AS ev
      ON ev.policy_version = re.policy_version
     AND ev.evidence_id = re.evidence_id
    WHERE ev.evidence_id IS NULL
    """
).fetchone()[0] == 0
assert connection.execute("PRAGMA foreign_key_check").fetchall() == []

# The fixture intentionally repeats one ~600-byte evidence document across
# every edge. Dictionary normalization must keep incremental relationship
# allocation below a realistic per-edge budget rather than copying the JSON.
allocated_bytes = after_bytes - before_bytes
assert allocated_bytes // expected_edges <= 384

before = (
    tuple(connection.execute(
        "SELECT * FROM relationship_evidence ORDER BY policy_version,evidence_id"
    )),
    tuple(connection.execute(
        "SELECT evidence_id FROM relationship_edges "
        "ORDER BY policy_version,left_event_id,right_event_id"
    )),
)
rebuild_relationships(connection, DEFAULT_POLICY)
connection.commit()
after = (
    tuple(connection.execute(
        "SELECT * FROM relationship_evidence ORDER BY policy_version,evidence_id"
    )),
    tuple(connection.execute(
        "SELECT evidence_id FROM relationship_edges "
        "ORDER BY policy_version,left_event_id,right_event_id"
    )),
)
assert before == after
PY
  then
    pass "repeat evidenceを1辞書行へ畳み孤児なし・384 bytes/edge以下で再現する"
  else
    cat "$err" >&2
    fail "repeat evidenceを1辞書行へ畳み孤児なし・384 bytes/edge以下で再現する"
  fi
}

test_relationship_rebuild_is_deterministic_idempotent_and_source_immutable() {
  echo "test_relationship_rebuild_is_deterministic_idempotent_and_source_immutable:"
  local state="$TEST_ROOT/rich/vault"
  local db="$state/index/vault.sqlite"
  local graph_before graph_after source_before source_after
  ensure_rich_graph || {
    fail "determinism fixtureを構築できる"
    return
  }
  graph_before="$(graph_snapshot "$db" 2>/dev/null)" || {
    fail "初回relationship graphを読み取れる"
    return
  }
  source_before="$(source_snapshot "$db" 2>/dev/null)"
  if ! run_cli "$state" rebuild-relationships >/dev/null 2>&1; then
    fail "bundled policyでrelationship graphを再計算できる"
    return
  fi
  graph_after="$(graph_snapshot "$db" 2>/dev/null)"
  source_after="$(source_snapshot "$db" 2>/dev/null)"
  if [[ "$graph_before" == "$graph_after" && "$source_before" == "$source_after" ]]; then
    pass "relationship再計算は決定論的・冪等でsource evidenceを変更しない"
  else
    fail "relationship再計算は決定論的・冪等でsource evidenceを変更しない"
    return
  fi

  chmod 0644 "$db"
  if ! run_cli "$state" rebuild-relationships >/dev/null 2>&1 \
    && python3 - "$db" <<'PY'
import pathlib
import stat
import sys

assert stat.S_IMODE(pathlib.Path(sys.argv[1]).stat().st_mode) == 0o644
PY
  then
    pass "unsafe modeのevidence indexをwriterが変更せず拒否する"
  else
    fail "unsafe modeのevidence indexをwriterが変更せず拒否する"
    return
  fi
  chmod 0600 "$db"

  python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "UPDATE source_events SET relationship_task_id_hash = ? "
    "WHERE event_id = ?",
    (
        "sha256:" + "9" * 24,
        "10000000-0000-4000-8000-000000000001",
    ),
)
connection.commit()
PY
  local tampered_before tampered_after
  tampered_before="$(graph_snapshot "$db" 2>/dev/null)"
  if run_cli "$state" rebuild-relationships >/dev/null 2>&1; then
    fail "認証済みsource projectionと異なるDBからのgraph再生成を拒否する"
    run_cli "$state" rebuild-index >/dev/null 2>&1
    return
  fi
  tampered_after="$(graph_snapshot "$db" 2>/dev/null)"
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "tampered derived DBをsource chunksから復旧できる"
    return
  }
  if [[ "$tampered_before" == "$tampered_after" ]]; then
    pass "standalone再計算は認証済みsource projectionとの差分をfail closedする"
  else
    fail "standalone再計算は認証済みsource projectionとの差分をfail closedする"
  fi
}

write_policy() {
  local path="$1" version="$2" threshold="$3"
  python3 - "$path" "$version" "$threshold" <<'PY'
import json
import pathlib
import sys

path, version, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3])
policy = {
    "schema_version": 1,
    "policy_version": version,
    "threshold": threshold,
    "weights": {
        "explicit_task_match": 600,
        "workspace_match": 100,
        "branch_or_worktree_match": 150,
        "changed_file_overlap": 150,
    },
    "time_buckets": [
        {"max_seconds": 300, "contribution": 100},
        {"max_seconds": 3600, "contribution": 25},
    ],
    "time_window_seconds": 3600,
    "hard_veto": {"contradictory_task_ids": True},
}
pathlib.Path(path).write_text(
    json.dumps(policy, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
}

test_policy_versions_coexist_and_invalid_policy_is_atomic() {
  echo "test_policy_versions_coexist_and_invalid_policy_is_atomic:"
  local state="$TEST_ROOT/rich/vault"
  local db="$state/index/vault.sqlite"
  local valid="$TEST_ROOT/relaxed-policy.json" invalid="$TEST_ROOT/invalid-policy.json"
  local before after
  ensure_rich_graph || {
    fail "policy fixtureを構築できる"
    return
  }
  write_policy "$valid" "relaxed-v2" 250
  if ! run_cli "$state" rebuild-relationships --policy "$valid" >/dev/null 2>&1; then
    fail "別versionのvalid policyを適用できる"
    return
  fi
  if python3 - "$db" <<'PY' 2>/dev/null
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
versions = {
    row[0] for row in connection.execute(
        "SELECT policy_version FROM relationship_policies"
    )
}
assert "default-v1" in versions
assert "relaxed-v2" in versions
evidence_versions = {
    row[0] for row in connection.execute(
        "SELECT DISTINCT policy_version FROM relationship_evidence"
    )
}
assert evidence_versions == versions
assert all(
    isinstance(row[0], int)
    for row in connection.execute(
        "SELECT score FROM relationship_edges WHERE policy_version='relaxed-v2'"
    )
)
PY
  then
    pass "複数policy versionのderived viewsが共存する"
  else
    fail "複数policy versionのderived viewsが共存する"
  fi

  append_v2_event "$state" "10000000-0000-4000-8000-000000000007" \
    "2026-07-25T05:00:00Z" codex \
    "sha256:100000000000000000000001" \
    "sha256:300000000000000000000003" \
    "sha256:400000000000000000000004" \
    "sha256:500000000000000000000005"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "custom policy incremental fixtureを同期できる"
    return
  }
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1 || {
    fail "custom policyを含むincremental index rebuildを実行できる"
    return
  }
  if python3 - "$db" <<'PY' 2>/dev/null
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
source_ids = {
    row[0] for row in connection.execute("SELECT event_id FROM source_events")
}
versions = [
    row[0]
    for row in connection.execute(
        "SELECT policy_version FROM relationship_policies ORDER BY policy_version"
    )
]
assert versions == ["default-v1", "relaxed-v2"]
for version in versions:
    member_ids = {
        row[0]
        for row in connection.execute(
            "SELECT event_id FROM episode_members WHERE policy_version = ?",
            (version,),
        )
    }
    assert member_ids == source_ids
    orphan_count = connection.execute(
        """
        SELECT COUNT(*)
        FROM relationship_edges AS re
        LEFT JOIN relationship_evidence AS ev
          ON ev.policy_version = re.policy_version
         AND ev.evidence_id = re.evidence_id
        WHERE re.policy_version = ? AND ev.evidence_id IS NULL
        """,
        (version,),
    ).fetchone()[0]
    assert orphan_count == 0
    for evidence_id, encoded in connection.execute(
        "SELECT evidence_id,evidence_json FROM relationship_evidence "
        "WHERE policy_version=?",
        (version,),
    ):
        import hashlib
        assert evidence_id == "sha256:" + hashlib.sha256(
            encoded.encode("utf-8")
        ).hexdigest()
PY
  then
    pass "incremental import後も登録済み全policy viewを同じsource horizonへ更新する"
  else
    fail "incremental import後も登録済み全policy viewを同じsource horizonへ更新する"
  fi

  before="$(graph_snapshot "$db" 2>/dev/null)"
  python3 - "$invalid" <<'PY'
import json
import pathlib
import sys

# A float threshold would make boundary decisions platform/config dependent.
pathlib.Path(sys.argv[1]).write_text(
    json.dumps({
        "schema_version": 1,
        "policy_version": "invalid-float",
        "threshold": 250.5,
        "weights": {},
        "time_buckets": [],
        "time_window_seconds": 3600,
        "hard_veto": {"contradictory_task_ids": True},
    }),
    encoding="utf-8",
)
PY
  if run_cli "$state" rebuild-relationships --policy "$invalid" >/dev/null 2>&1; then
    fail "non-integer thresholdのinvalid policyを拒否する"
    return
  fi
  after="$(graph_snapshot "$db" 2>/dev/null)"
  if [[ "$before" == "$after" ]]; then
    pass "invalid policyは既存graphを一切変更せずatomicに失敗する"
  else
    fail "invalid policyは既存graphを一切変更せずatomicに失敗する"
  fi
}

test_fractional_time_boundary_does_not_round_into_window() {
  echo "test_fractional_time_boundary_does_not_round_into_window:"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - <<'PY' 2>/dev/null
import json

from relationship_graph import DEFAULT_POLICY, Event, score_pair

left = Event(
    "20000000-0000-4000-8000-000000000001",
    "2026-07-25T00:00:00Z",
    None,
    "sha256:" + "1" * 24,
    None,
    (),
    "missing",
)
right = Event(
    "20000000-0000-4000-8000-000000000002",
    "2026-07-25T01:00:00.500000Z",
    None,
    "sha256:" + "1" * 24,
    None,
    (),
    "missing",
)
score, decision, encoded = score_pair(left, right, DEFAULT_POLICY)
evidence = json.loads(encoded)
assert decision == "link"  # explicit task match is valid outside the time window
assert evidence["time_distance"]["state"] == "outside_window"
assert evidence["time_distance"]["seconds"] == 3601
assert evidence["time_distance"]["contribution"] == 0
assert score == DEFAULT_POLICY["weights"]["explicit_task_match"]
PY
  then
    pass "fractional time distanceをwindow内へ切り捨てず決定論的に評価する"
  else
    fail "fractional time distanceをwindow内へ切り捨てず決定論的に評価する"
  fi
}

test_full_rebuild_restores_graph_without_privacy_leak() {
  echo "test_full_rebuild_restores_graph_without_privacy_leak:"
  local state="$TEST_ROOT/rich/vault"
  local db="$state/index/vault.sqlite"
  local before after
  ensure_rich_graph || {
    fail "full rebuild fixtureを構築できる"
    return
  }
  before="$(default_graph_snapshot "$db" 2>/dev/null)" || {
    fail "rebuild前graphを読み取れる"
    return
  }
  rm "$db"
  if ! run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "DB削除後にsource chunksからgraphをfull rebuildできる"
    return
  fi
  after="$(default_graph_snapshot "$db" 2>/dev/null)"
  if [[ "$before" == "$after" ]] \
    && ! grep -a -r -E -q \
      "RAW_RELATIONSHIP_CANARY_79b7|RAW_BRANCH_CANARY_80c8|/private/workspace|private/second.py" \
      "$state"; then
    pass "full rebuildは同じgraphを復元しraw task/branch/pathを保存しない"
  else
    fail "full rebuildは同じgraphを復元しraw task/branch/pathを保存しない"
  fi
}

test_recorder_emits_private_domain_separated_event_v2
test_mixed_v1_v2_inbox_is_lossless_and_versioned
test_index_v5_normalizes_canonical_six_feature_evidence
test_cross_harness_veto_bridge_missing_and_singletons
test_candidate_generation_and_full_persistence_are_bounded_streams
test_repeated_evidence_dictionary_has_no_orphans_and_bounded_bytes_per_edge
test_relationship_rebuild_is_deterministic_idempotent_and_source_immutable
test_policy_versions_coexist_and_invalid_policy_is_atomic
test_fractional_time_boundary_does_not_round_into_window
test_full_rebuild_restores_graph_without_privacy_leak

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
