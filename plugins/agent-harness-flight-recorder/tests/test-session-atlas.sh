#!/usr/bin/env bash
# Deterministic Session Atlas projection and cohort query contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
readonly TEST_ROOT
STATE="$TEST_ROOT/vault"
REPORT_STATE="$TEST_ROOT/report-vault"
TEST_HOME="$TEST_ROOT/home"
PASS=0
FAIL=0
FIXTURE_READY=0
QUERY_FIXTURE_READY=0

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
  run_cli_at "$STATE" "$@"
}

run_cli_at() {
  local state="$1"
  shift
  PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    FLIGHT_RECORDER_STATE_DIR="$state" \
    "$CLI" "$@"
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

build_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  mkdir -p "$TEST_HOME"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  make_identity "$recovery"
  run_cli init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1 || return
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" <<'PY'
import json
import pathlib
import sys


def event(event_id, recorded_at, *, task, workspace, event_kind,
          operation_kind, files, files_state, model, outcome,
          source_event=None):
    return {
        "schema_version": 3,
        "event_id": event_id,
        "recorded_at": recorded_at,
        "harness": "codex",
        "source_event": source_event or (
            "PostToolUse" if event_kind == "tool.completed" else "Stop"
        ),
        "event_kind": event_kind,
        "session_id_hash": "sha256:" + "a" * 24 if workspace else None,
        "turn_id_hash": None,
        "workspace_id": workspace,
        "model": model,
        "permission_mode": "full-access",
        "tool": "shell",
        "metrics": {"duration_ms": 100},
        "outcome": outcome,
        "operation_kind": operation_kind,
        "relationship_context": {
            "task_id_hash": task,
            "task_source": "payload" if task else None,
            "branch_or_worktree_id": None,
            "changed_file_fingerprints": files,
            "changed_files_state": files_state,
        },
    }


task = "sha256:" + "1" * 24
workspace = "sha256:" + "2" * 24
events = [
    event(
        "51000000-0000-4000-8000-000000000001",
        "2026-08-15T00:00:00Z",
        task=task,
        workspace=workspace,
        event_kind="tool.completed",
        operation_kind="test",
        files=["sha256:" + "3" * 24],
        files_state="complete",
        model="must-not-be-a-facet",
        outcome={"status": "success", "exit_code": 0},
    ),
    event(
        "51000000-0000-4000-8000-000000000002",
        "2026-08-15T00:00:10Z",
        task=task,
        workspace=workspace,
        event_kind="tool.completed",
        operation_kind="build",
        files=["sha256:" + "4" * 24],
        files_state="complete",
        model="a-different-model",
        outcome={"status": "failure", "exit_code": 1},
    ),
    event(
        "51000000-0000-4000-8000-000000000003",
        "2026-08-15T02:00:00Z",
        task=None,
        workspace=None,
        event_kind="hook.observed",
        operation_kind=None,
        files=[],
        files_state="missing",
        model=None,
        outcome=None,
    ),
]

# Operation coverage fixtures. Only tool.completed events are eligible:
# missing classification on a non-tool event must not dilute coverage.
events.extend([
    event(
        "51000000-0000-4000-8000-000000000101",
        "2026-08-15T03:00:00Z",
        task="sha256:" + "6" * 24,
        workspace="sha256:" + "7" * 24,
        event_kind="tool.completed",
        operation_kind="test",
        files=[],
        files_state="missing",
        model=None,
        outcome={"status": "success", "exit_code": 0},
        source_event="PostToolUse",
    ),
    event(
        "51000000-0000-4000-8000-000000000102",
        "2026-08-15T03:00:01Z",
        task="sha256:" + "6" * 24,
        workspace="sha256:" + "7" * 24,
        event_kind="tool.completed",
        operation_kind=None,
        files=[],
        files_state="missing",
        model=None,
        outcome={"status": "success", "exit_code": 0},
        source_event="PostToolUse",
    ),
    event(
        "51000000-0000-4000-8000-000000000103",
        "2026-08-15T03:00:02Z",
        task="sha256:" + "6" * 24,
        workspace="sha256:" + "7" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=[],
        files_state="missing",
        model=None,
        outcome=None,
    ),
    event(
        "51000000-0000-4000-8000-000000000104",
        "2026-08-15T03:10:00Z",
        task="sha256:" + "e" * 24,
        workspace="sha256:" + "e" * 24,
        event_kind="tool.completed",
        operation_kind="test",
        files=[],
        files_state="missing",
        model=None,
        outcome={"status": "success", "exit_code": 0},
        source_event="PostToolUse",
    ),
    event(
        "51000000-0000-4000-8000-000000000105",
        "2026-08-15T03:10:01Z",
        task="sha256:" + "e" * 24,
        workspace="sha256:" + "e" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=[],
        files_state="missing",
        model=None,
        outcome=None,
    ),
    event(
        "51000000-0000-4000-8000-000000000106",
        "2026-08-15T03:20:00Z",
        task="sha256:" + "0" * 24,
        workspace="sha256:" + "0" * 24,
        event_kind="tool.completed",
        operation_kind="build",
        files=[],
        files_state="missing",
        model=None,
        outcome={"status": "success", "exit_code": 0},
        source_event="PostToolUse",
    ),
    event(
        "51000000-0000-4000-8000-000000000107",
        "2026-08-15T03:20:01Z",
        task="sha256:" + "0" * 24,
        workspace="sha256:" + "0" * 24,
        event_kind="tool.completed",
        operation_kind="test",
        files=[],
        files_state="missing",
        model=None,
        outcome={"status": "success", "exit_code": 0},
        source_event="PostToolUse",
    ),
])

# Artifact/change fixtures cover each finite shape without retaining paths or
# fingerprints in the Atlas projection.
artifact_cases = [
    (201, "8", [], "complete"),
    (202, "9", ["sha256:" + "1" * 24], "complete"),
    (203, "a", ["sha256:" + "2" * 24, "sha256:" + "3" * 24], "complete"),
    (204, "b", ["sha256:" + format(item, "024x") for item in range(9)], "truncated"),
    (205, "c", [], "missing"),
]
for number, token, files, files_state in artifact_cases:
    events.append(event(
        f"51000000-0000-4000-8000-{number:012d}",
        f"2026-08-15T04:{number - 200:02d}:00Z",
        task="sha256:" + token * 24,
        workspace="sha256:" + token * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=files,
        files_state=files_state,
        model=None,
        outcome=None,
    ))
events.extend([
    event(
        "51000000-0000-4000-8000-000000000206",
        "2026-08-15T04:06:00Z",
        task="sha256:" + "d" * 24,
        workspace="sha256:" + "d" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=["sha256:" + "5" * 24],
        files_state="complete",
        model=None,
        outcome=None,
    ),
    event(
        "51000000-0000-4000-8000-000000000207",
        "2026-08-15T04:06:01Z",
        task="sha256:" + "d" * 24,
        workspace="sha256:" + "d" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=[],
        files_state="missing",
        model=None,
        outcome=None,
    ),
    # Shape is computed across the Episode's unique changed-file union, not
    # from the largest individual event. Two one-file observations are `few`.
    event(
        "51000000-0000-4000-8000-000000000208",
        "2026-08-15T04:08:00Z",
        task="sha256:" + "4" * 24,
        workspace="sha256:" + "4" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=["sha256:" + "8" * 24],
        files_state="complete",
        model=None,
        outcome=None,
    ),
    event(
        "51000000-0000-4000-8000-000000000209",
        "2026-08-15T04:08:01Z",
        task="sha256:" + "4" * 24,
        workspace="sha256:" + "4" * 24,
        event_kind="turn.completed",
        operation_kind=None,
        files=["sha256:" + "9" * 24],
        files_state="complete",
        model=None,
        outcome=None,
    ),
    # A distinct Episode with the same four facets as events 001/002. Its
    # contradictory explicit task ID prevents a relationship merge and makes
    # it a real cohort peer for forget/candidate tests.
    event(
        "51000000-0000-4000-8000-000000000301",
        "2026-08-15T00:20:00Z",
        task="sha256:" + "f" * 24,
        workspace=workspace,
        event_kind="tool.completed",
        operation_kind="test",
        files=["sha256:" + "6" * 24],
        files_state="complete",
        model=None,
        outcome={"status": "success", "exit_code": 0},
    ),
    event(
        "51000000-0000-4000-8000-000000000302",
        "2026-08-15T00:20:10Z",
        task="sha256:" + "f" * 24,
        workspace=workspace,
        event_kind="tool.completed",
        operation_kind="build",
        files=["sha256:" + "7" * 24],
        files_state="complete",
        model=None,
        outcome={"status": "failure", "exit_code": 1},
    ),
])
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n"
        for item in events
    ),
    encoding="utf-8",
)
PY
  run_cli sync >/dev/null 2>&1 || return
  run_cli rebuild-index >/dev/null 2>&1 || return
  FIXTURE_READY=1
}

episode_id() {
  printf 'sha256:%064x' "$1"
}

episode_id_for_event() {
  episode_id_for_event_at "$STATE" "$1"
}

episode_id_for_event_at() {
  local state="$1" event_id="$2"
  python3 - "$state/index/vault.sqlite" "$event_id" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT episode_id FROM episode_members "
    "WHERE policy_version='default-v1' AND event_id=?",
    (sys.argv[2],),
).fetchone()
assert row is not None
print(row[0])
PY
}

episode_id_for_policy_event_at() {
  local state="$1" policy_version="$2" event_id="$3"
  python3 - "$state/index/vault.sqlite" "$policy_version" "$event_id" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT episode_id FROM episode_members "
    "WHERE policy_version=? AND event_id=?",
    (sys.argv[2], sys.argv[3]),
).fetchone()
assert row is not None
print(row[0])
PY
}

write_policy() {
  local path="$1" version="$2"
  python3 - "$path" "$version" <<'PY'
import json
import pathlib
import sys

path, version = sys.argv[1:]
policy = {
    "schema_version": 1,
    "policy_version": version,
    "threshold": 500,
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

# Seed only derived SQLite rows. This avoids creating 24k encrypted artifacts;
# the ordinary rebuild above remains responsible for testing real projection.
seed_query_fixture() {
  [[ "$FIXTURE_READY" -eq 1 ]] || return 1
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
    "$STATE" "$(episode_id 1)" <<'PY' || return 1
import json
import pathlib
import sqlite3
import sys

from evidence_index import issue_index_seal
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
database = root / "index" / "vault.sqlite"
connection = sqlite3.connect(database)
connection.execute("PRAGMA foreign_keys = ON")

expected_columns = {
    "policy_version", "episode_id",
    "context_identity_state", "context_identity_value_json",
    "event_lifecycle_state", "event_lifecycle_value_json",
    "operation_state", "operation_value_json",
    "artifact_change_state", "artifact_change_value_json",
}
columns = {
    row[1]
    for row in connection.execute("PRAGMA table_info(session_atlas_facets)")
}
assert columns == expected_columns, columns


def encoded(value):
    if value is None:
        return None
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def identifier(number):
    return "sha256:" + format(number, "064x")


def opaque(number):
    return "sha256:" + format(number, "024x")


def add(number, identity, lifecycle, operation, artifact):
    episode = identifier(number)
    connection.execute(
        "INSERT OR IGNORE INTO episodes(policy_version,episode_id,member_count) "
        "VALUES ('default-v1',?,1)",
        (episode,),
    )
    fields = []
    for state, value in (identity, lifecycle, operation, artifact):
        fields.extend((state, encoded(value)))
    connection.execute(
        "INSERT OR REPLACE INTO session_atlas_facets VALUES "
        "('default-v1',?,?,?,?,?,?,?,?,?)",
        (episode, *fields),
    )


present = "present"
unknown = "unknown"
mixed = "mixed"
base_lifecycle = (present, "turn.completed")
base_operation = (present, {"coverage": "complete", "kinds": ["test"]})
base_artifact = (present, {"coverage": "complete", "shape": "single"})

# Exact peers, structural peers, a partial peer, and unknown evidence.
add(1, (present, opaque(1)), base_lifecycle, base_operation, base_artifact)
add(2, (present, opaque(1)), base_lifecycle, base_operation, base_artifact)
add(3, (present, opaque(1)), base_lifecycle, base_operation, base_artifact)
add(4, (present, opaque(2)), base_lifecycle, base_operation, base_artifact)
add(5, (present, opaque(3)), (present, "hook.observed"),
    base_operation, (present, {"coverage": "complete", "shape": "none"}))
add(6, (unknown, None), base_lifecycle, base_operation, base_artifact)
add(7, (unknown, None), (unknown, None), (unknown, None), (unknown, None))

# A mixed facet only matches the same canonical finite value, never "mixed" alone.
add(10, (present, opaque(10)), base_lifecycle,
    (mixed, {"coverage": "complete", "kinds": ["test", "build"]}),
    base_artifact)
add(11, (present, opaque(10)), base_lifecycle,
    (mixed, {"coverage": "complete", "kinds": ["test", "build"]}),
    base_artifact)
add(12, (present, opaque(10)), base_lifecycle,
    (mixed, {"coverage": "complete", "kinds": ["test", "lint"]}),
    base_artifact)
# Deliberately signed malformed projection: operation carries artifact shape.
add(13, (present, opaque(13)), base_lifecycle,
    (present, {"coverage": "complete", "shape": "single"}), base_artifact)

# Scale rows use no encrypted artifact fan-out and do not join the target's
# exact cohort. Their opaque identity is unique.
for number in range(20, 24010):
    add(
        number,
        (present, opaque(number)),
        (present, "hook.observed"),
        (present, {"coverage": "complete", "kinds": ["build"]}),
        (present, {"coverage": "complete", "shape": "none"}),
    )

connection.commit()
connection.close()
with vault_lock(root):
    issue_index_seal(root)
assert target == identifier(1)
PY
  QUERY_FIXTURE_READY=1
}

prepare_report_fixture() {
  cp -R "$STATE" "$REPORT_STATE" || return 1
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$REPORT_STATE" <<'PY'
import pathlib
import sys

from evidence_index import issue_index_seal
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
with vault_lock(root):
    issue_index_seal(root)
PY
}

call_api() {
  call_api_at "$STATE" "$@"
}

call_api_at() {
  local state="$1" episode="$2" tier="$3" facets_json="$4" limit="$5" cursor="$6"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
    "$state" "$episode" "$tier" "$facets_json" "$limit" "$cursor" <<'PY'
import json
import pathlib
import sys

from session_atlas import query_cohort

root, episode, tier, facets_json, limit, cursor = sys.argv[1:]
value = query_cohort(
    pathlib.Path(root),
    "default-v1",
    episode,
    tier,
    json.loads(facets_json),
    int(limit),
    cursor or None,
)
print(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
}

assert_common_contract() {
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert set(value) == {
    "schema_version", "command", "policy_version", "generation", "query",
    "items", "next_cursor",
}
assert value["schema_version"] == 1
assert value["command"] == "atlas.cohort"
assert value["policy_version"] == "default-v1"
assert value["generation"].startswith("sha256:")
assert isinstance(value["items"], list)
assert value["items"] == sorted(value["items"], key=lambda item: item["episode_id"])
for item in value["items"]:
    assert set(item) == {"episode_id", "facets", "match_mask"}
    assert set(item["match_mask"]) == {
        "context_identity", "event_lifecycle", "operation", "artifact_change",
    }
    assert all(isinstance(flag, bool) for flag in item["match_mask"].values())
    assert set(item["facets"]) == set(item["match_mask"])
    for facet in item["facets"].values():
        assert set(facet) == {"state", "value"}
        assert facet["state"] in {"present", "mixed", "unknown"}
        assert (facet["value"] is None) == (facet["state"] == "unknown")
encoded = json.dumps(value, sort_keys=True)
for forbidden in ("score", "rank", "winner", "model", "harness", "outcome",
                  "duration", "cost", "retry", "value_primitive"):
    assert f'"{forbidden}"' not in encoded
PY
}

test_projection_is_one_row_per_episode_without_treatment_leakage() {
  echo "test_projection_is_one_row_per_episode_without_treatment_leakage:"
  if [[ "$FIXTURE_READY" -ne 1 ]]; then
    fail "fixtureを構築できる"
    return
  fi
  if python3 - "$STATE/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
columns = [
    row[1]
    for row in connection.execute("PRAGMA table_info(session_atlas_facets)")
]
assert set(columns) == {
    "policy_version", "episode_id",
    "context_identity_state", "context_identity_value_json",
    "event_lifecycle_state", "event_lifecycle_value_json",
    "operation_state", "operation_value_json",
    "artifact_change_state", "artifact_change_value_json",
}
assert not any(
    forbidden in column
    for column in columns
    for forbidden in (
        "model", "harness", "outcome", "duration", "cost", "retry", "value",
    )
    if not column.endswith("_value_json")
)
episodes = connection.execute(
    "SELECT policy_version,COUNT(*) FROM episodes GROUP BY policy_version"
).fetchall()
atlas = connection.execute(
    "SELECT policy_version,COUNT(*) FROM session_atlas_facets "
    "GROUP BY policy_version"
).fetchall()
assert episodes == atlas
assert connection.execute(
    "SELECT COUNT(*) FROM session_atlas_facets"
).fetchone()[0] > 0
PY
  then
    pass "trusted rebuildはpolicyごとに1 Episode 1 rowの4 facetだけを投影する"
  else
    fail "trusted rebuildはpolicyごとに1 Episode 1 rowの4 facetだけを投影する"
  fi
}

test_projection_preserves_present_mixed_and_unknown() {
  echo "test_projection_preserves_present_mixed_and_unknown:"
  if [[ "$FIXTURE_READY" -ne 1 ]]; then
    fail "fixtureを構築できる"
    return
  fi
  if python3 - "$STATE/index/vault.sqlite" <<'PY'
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = connection.execute(
    "SELECT context_identity_state,context_identity_value_json,"
    "event_lifecycle_state,event_lifecycle_value_json,"
    "operation_state,operation_value_json,"
    "artifact_change_state,artifact_change_value_json "
    "FROM session_atlas_facets ORDER BY episode_id"
).fetchall()
states = set()
for row in rows:
    for offset in range(0, 8, 2):
        state, encoded = row[offset:offset + 2]
        states.add(state)
        assert state in {"present", "mixed", "unknown"}
        assert (encoded is None) == (state == "unknown")
        if encoded is not None:
            decoded = json.loads(encoded)
            assert json.dumps(decoded, sort_keys=True, separators=(",", ":")) == encoded
            if state == "mixed" and isinstance(decoded, list):
                assert len(decoded) > 1
assert states == {"present", "mixed", "unknown"}
PY
  then
    pass "facetはpresent/mixed/unknownを保ちunknownを値へ捏造しない"
  else
    fail "facetはpresent/mixed/unknownを保ちunknownを値へ捏造しない"
  fi
}

test_materialize_replaces_existing_rows_idempotently() {
  echo "test_materialize_replaces_existing_rows_idempotently:"
  local database="$TEST_ROOT/materialize-replace.sqlite"
  if [[ "$FIXTURE_READY" -ne 1 ]]; then
    fail "fixtureを構築できる"
    return
  fi
  cp "$STATE/index/vault.sqlite" "$database"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$database" <<'PY'
import sqlite3
import sys

from session_atlas import materialize_session_atlas

connection = sqlite3.connect(sys.argv[1])
target = connection.execute(
    "SELECT episode_id FROM session_atlas_facets "
    "WHERE policy_version='default-v1' AND context_identity_state='present' "
    "ORDER BY episode_id LIMIT 1"
).fetchone()[0]
connection.execute(
    "UPDATE session_atlas_facets "
    "SET context_identity_state='unknown',context_identity_value_json=NULL "
    "WHERE policy_version='default-v1' AND episode_id=?",
    (target,),
)

# The materializer owns replace semantics. Callers must not pre-delete rows.
materialize_session_atlas(connection, "default-v1")
first = connection.execute(
    "SELECT * FROM session_atlas_facets WHERE policy_version='default-v1' "
    "ORDER BY episode_id"
).fetchall()
assert first
restored = connection.execute(
    "SELECT context_identity_state FROM session_atlas_facets "
    "WHERE policy_version='default-v1' AND episode_id=?",
    (target,),
).fetchone()
assert restored == ("present",), restored

materialize_session_atlas(connection, "default-v1")
second = connection.execute(
    "SELECT * FROM session_atlas_facets WHERE policy_version='default-v1' "
    "ORDER BY episode_id"
).fetchall()
assert second == first
assert len(second) == connection.execute(
    "SELECT COUNT(*) FROM episodes WHERE policy_version='default-v1'"
).fetchone()[0]
connection.close()
PY
  then
    pass "materialize単体が既存rowを置換し反復実行も冪等になる"
  else
    fail "materialize単体が既存rowを置換し反復実行も冪等になる"
  fi
}

test_scalar_mixed_values_are_sorted_and_unique() {
  echo "test_scalar_mixed_values_are_sorted_and_unique:"
  local database="$TEST_ROOT/scalar-order.sqlite"
  cp "$STATE/index/vault.sqlite" "$database"
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$database" <<'PY'
import json
import sqlite3
import sys

from session_atlas import materialize_session_atlas

connection = sqlite3.connect(sys.argv[1])
columns = [row[1] for row in connection.execute("PRAGMA table_info(source_events)")]
template = dict(zip(columns, connection.execute(
    "SELECT * FROM source_events ORDER BY event_id LIMIT 1"
).fetchone()))


def add_event(event_id, ordinal, workspace, event_kind, source_event, operation):
    value = dict(template)
    value.update({
        "event_id": event_id,
        "ordinal": ordinal,
        "workspace_id": workspace,
        "event_kind": event_kind,
        "source_event": source_event,
        "operation_kind": operation,
    })
    connection.execute(
        f"INSERT INTO source_events({','.join(columns)}) "
        f"VALUES ({','.join('?' for _ in columns)})",
        [value[column] for column in columns],
    )


first = "52000000-0000-4000-8000-000000000001"
second = "52000000-0000-4000-8000-000000000002"
episode = "sha256:" + "f" * 64
next_ordinal = connection.execute(
    "SELECT MAX(ordinal)+1 FROM source_events WHERE chunk_id=?",
    (template["chunk_id"],),
).fetchone()[0]
add_event(first, next_ordinal, "sha256:" + "b" * 24,
          "turn.completed", "Stop", None)
add_event(second, next_ordinal + 1, "sha256:" + "a" * 24,
          "tool.completed", "PostToolUse", "test")
connection.execute(
    "INSERT INTO episodes VALUES ('default-v1',?,2)", (episode,)
)
connection.executemany(
    "INSERT INTO episode_members VALUES ('default-v1',?,?,?)",
    ((episode, first, 0), (episode, second, 1)),
)
connection.execute(
    "DELETE FROM session_atlas_facets WHERE policy_version='default-v1'"
)
materialize_session_atlas(connection, "default-v1")
row = connection.execute(
    "SELECT context_identity_state,context_identity_value_json,"
    "event_lifecycle_state,event_lifecycle_value_json "
    "FROM session_atlas_facets WHERE policy_version='default-v1' "
    "AND episode_id=?",
    (episode,),
).fetchone()
expected = (
    "mixed",
    json.dumps(["sha256:" + "a" * 24, "sha256:" + "b" * 24], separators=(",", ":")),
    "mixed",
    json.dumps(["tool.completed", "turn.completed"], separators=(",", ":")),
)
assert row == expected, (row, expected)
connection.close()
PY
  then
    pass "scalar mixed facetはrebuildごとにsorted unique canonical配列になる"
  else
    fail "scalar mixed facetはrebuildごとにsorted unique canonical配列になる"
  fi
}

test_operation_coverage_uses_only_tool_completed_denominator() {
  echo "test_operation_coverage_uses_only_tool_completed_denominator:"
  local partial complete unknown multiple
  partial="$(episode_id_for_event 51000000-0000-4000-8000-000000000101)"
  complete="$(episode_id_for_event 51000000-0000-4000-8000-000000000104)"
  unknown="$(episode_id_for_event 51000000-0000-4000-8000-000000000003)"
  multiple="$(episode_id_for_event 51000000-0000-4000-8000-000000000106)"
  if python3 - "$PLUGIN_DIR/scripts" "$STATE/index/vault.sqlite" "$partial" \
    "$complete" "$unknown" "$multiple" <<'PY'
import json
import sqlite3
import sys

sys.path.insert(0, sys.argv[1])
from session_atlas import materialize_session_atlas

connection = sqlite3.connect(sys.argv[2])
connection.execute("BEGIN")

# Relationship construction may place the non-tool event in another Episode.
# Force it into the classified tool's Episode inside a rolled-back transaction
# so the materializer contract itself proves that the label is ignored.
event_id = "51000000-0000-4000-8000-000000000105"
connection.execute(
    "UPDATE source_events SET operation_kind='build' WHERE event_id=?",
    (event_id,),
)
connection.execute(
    "DELETE FROM episode_members WHERE policy_version='default-v1' "
    "AND event_id=?", (event_id,),
)
next_ordinal = connection.execute(
    "SELECT COALESCE(MAX(ordinal),-1)+1 FROM episode_members "
    "WHERE policy_version='default-v1' AND episode_id=?", (sys.argv[4],),
).fetchone()[0]
connection.execute(
    "INSERT INTO episode_members VALUES ('default-v1',?,?,?)",
    (sys.argv[4], event_id, next_ordinal),
)
assert connection.execute(
    "SELECT operation_kind,event_kind FROM source_events WHERE event_id=?",
    (event_id,),
).fetchone() == ("build", "turn.completed")
assert connection.execute(
    "SELECT COUNT(*) FROM episode_members WHERE policy_version='default-v1' "
    "AND episode_id=?", (sys.argv[4],),
).fetchone()[0] >= 2
materialize_session_atlas(connection, "default-v1")


def operation(episode_id):
    row = connection.execute(
        "SELECT operation_state,operation_value_json "
        "FROM session_atlas_facets "
        "WHERE policy_version='default-v1' AND episode_id=?",
        (episode_id,),
    ).fetchone()
    assert row is not None
    state, encoded = row
    value = None if encoded is None else json.loads(encoded)
    if encoded is not None:
        assert json.dumps(value, sort_keys=True, separators=(",", ":")) == encoded
    return state, value


# One of two tool.completed events is unclassified. The non-tool event is not
# a third denominator item.
assert operation(sys.argv[3]) == (
    "mixed", {"coverage": "partial", "kinds": ["test"]},
)
# A classified tool plus a non-tool operation label remains complete coverage;
# the non-tool label must not enter the operation-kind set.
assert operation(sys.argv[4]) == (
    "present", {"coverage": "complete", "kinds": ["test"]},
)
# No eligible tool.completed event is unknown, not zero-percent "partial".
assert operation(sys.argv[5]) == ("unknown", None)
# Multiple classified kinds are mixed even at complete coverage; their order
# is the finite operation allowlist order, not observation order.
assert operation(sys.argv[6]) == (
    "mixed", {"coverage": "complete", "kinds": ["test", "build"]},
)
PY
  then
    pass "operation coverageはtool.completedだけを分母にし未分類toolをmixedにする"
  else
    fail "operation coverageはtool.completedだけを分母にし未分類toolをmixedにする"
  fi
}

test_artifact_change_uses_bounded_finite_shapes_without_raw_identifiers() {
  echo "test_artifact_change_uses_bounded_finite_shapes_without_raw_identifiers:"
  local ids=()
  local event
  for event in 201 202 203 204 205 206 208; do
    ids+=("$(episode_id_for_event "$(printf '51000000-0000-4000-8000-%012d' "$event")")")
  done
  if python3 - "$STATE/index/vault.sqlite" "${ids[@]}" <<'PY'
import json
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)


def artifact(episode_id):
    row = connection.execute(
        "SELECT artifact_change_state,artifact_change_value_json "
        "FROM session_atlas_facets "
        "WHERE policy_version='default-v1' AND episode_id=?",
        (episode_id,),
    ).fetchone()
    assert row is not None
    state, encoded = row
    assert encoded is None or "sha256:" not in encoded
    assert encoded is None or "/" not in encoded
    return state, None if encoded is None else json.loads(encoded)


assert artifact(sys.argv[2]) == (
    "present", {"coverage": "complete", "shape": "none"},
)
assert artifact(sys.argv[3]) == (
    "present", {"coverage": "complete", "shape": "single"},
)
assert artifact(sys.argv[4]) == (
    "present", {"coverage": "complete", "shape": "few"},
)
assert artifact(sys.argv[5]) == (
    "mixed", {"coverage": "partial", "shape": "many"},
)
assert artifact(sys.argv[6]) == ("unknown", None)
assert artifact(sys.argv[7]) == (
    "mixed", {"coverage": "partial", "shape": "single"},
)
assert artifact(sys.argv[8]) == (
    "present", {"coverage": "complete", "shape": "few"},
)
PY
  then
    pass "artifact changeはcoverage×none/single/few/manyだけを保持しraw識別子を出さない"
  else
    fail "artifact changeはcoverage×none/single/few/manyだけを保持しraw識別子を出さない"
  fi
}

test_exact_structural_and_partial_tiers() {
  echo "test_exact_structural_and_partial_tiers:"
  local target exact structural partial
  local exact_file="$TEST_ROOT/exact.json"
  local structural_file="$TEST_ROOT/structural.json"
  local partial_file="$TEST_ROOT/partial.json"
  target="$(episode_id 1)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && exact="$(call_api "$target" exact '[]' 20 '' 2>/dev/null)" \
    && structural="$(call_api "$target" structural '[]' 20 '' 2>/dev/null)" \
    && partial="$(call_api "$target" partial '["operation"]' 20 '' 2>/dev/null)"; then
    printf '%s\n' "$exact" >"$exact_file"
    printf '%s\n' "$structural" >"$structural_file"
    printf '%s\n' "$partial" >"$partial_file"
    if assert_common_contract "$exact_file" \
      && assert_common_contract "$structural_file" \
      && assert_common_contract "$partial_file" \
      && python3 - "$exact_file" "$structural_file" "$partial_file" <<'PY'
import json
import pathlib
import sys

exact, structural, partial = [
    json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]
]
eid = lambda number: "sha256:" + format(number, "064x")
assert [item["episode_id"] for item in exact["items"]] == [eid(1), eid(2), eid(3)]
assert [item["episode_id"] for item in structural["items"]] == [
    eid(1), eid(2), eid(3), eid(4), eid(6),
]
assert eid(5) in [item["episode_id"] for item in partial["items"]]
assert exact["query"]["tier"] == "exact" and exact["query"]["facets"] == [
    "context_identity", "event_lifecycle", "operation", "artifact_change",
]
assert structural["query"]["tier"] == "structural"
assert structural["query"]["facets"] == [
    "event_lifecycle", "operation", "artifact_change",
]
assert partial["query"]["tier"] == "partial"
assert partial["query"]["facets"] == ["operation"]
PY
    then
      pass "exact=4 facet、structural=identity以外3 facet、partial=明示facetで照合する"
      return
    fi
  fi
  fail "exact=4 facet、structural=identity以外3 facet、partial=明示facetで照合する"
}

test_custom_policy_requires_owner_held_policy_for_cli_and_api() {
  echo "test_custom_policy_requires_owner_held_policy_for_cli_and_api:"
  local policy="$TEST_ROOT/atlas-custom-policy.json"
  local target trusted_cli="$TEST_ROOT/custom-policy-cli.json"
  write_policy "$policy" "atlas-custom-v1"
  if ! run_cli rebuild-relationships --policy "$policy" >/dev/null 2>&1; then
    fail "custom policy projectionを準備できる"
    return
  fi
  target="$(episode_id_for_policy_event_at \
    "$STATE" "atlas-custom-v1" \
    51000000-0000-4000-8000-000000000001)"

  local cli_contract=0 api_contract=0
  if ! run_cli atlas cohort "$target" --tier exact --limit 10 \
      --policy-version atlas-custom-v1 --json >/dev/null 2>&1 \
    && run_cli atlas cohort "$target" --tier exact --limit 10 \
      --policy "$policy" --json >"$trusted_cli" 2>/dev/null \
    && python3 - "$trusted_cli" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["policy_version"] == "atlas-custom-v1"
PY
  then
    cli_contract=1
  fi
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
      "$STATE" "$target" "$policy" <<'PY'
import pathlib
import sys

from session_atlas import query_cohort
from vault import VaultError

root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
policy_path = pathlib.Path(sys.argv[3])
try:
    query_cohort(
        root, "atlas-custom-v1", target, "exact", [], 10, None
    )
except VaultError as error:
    assert "requires --policy" in str(error)
else:
    raise AssertionError("custom policy version was accepted without policy file")

value = query_cohort(
    root, None, target, "exact", [], 10, None, policy_path=policy_path
)
assert value["policy_version"] == "atlas-custom-v1"
PY
  then
    api_contract=1
  fi
  if [[ "$cli_contract" -eq 1 && "$api_contract" -eq 1 ]]; then
    pass "Atlas CLI/APIはcustom policyにowner-held validated fileを必須化する"
  else
    fail "Atlas CLI/APIはcustom policyにowner-held validated fileを必須化する"
  fi
}

test_unknown_never_matches_and_partial_requires_nonempty_facets() {
  echo "test_unknown_never_matches_and_partial_requires_nonempty_facets:"
  local unknown value
  unknown="$(episode_id 7)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && value="$(call_api "$unknown" exact '[]' 10 '' 2>/dev/null)" \
    && python3 - "$value" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
assert value["items"] == []
PY
  then
    if ! call_api "$(episode_id 1)" partial '[]' 10 '' \
        >"$TEST_ROOT/empty-partial.out" 2>"$TEST_ROOT/empty-partial.err" \
      && ! call_api "$(episode_id 1)" partial '["model"]' 10 '' \
        >"$TEST_ROOT/bad-partial.out" 2>"$TEST_ROOT/bad-partial.err"; then
      pass "unknown同士を一致扱いせずpartialの非空allowlist facet集合を要求する"
      return
    fi
  fi
  fail "unknown同士を一致扱いせずpartialの非空allowlist facet集合を要求する"
}

test_large_forgotten_set_does_not_expand_sql_variables() {
  echo "test_large_forgotten_set_does_not_expand_sql_variables:"
  local target
  target="$(episode_id 1)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" python3 - \
      "$STATE" "$target" <<'PY'
import pathlib
import sys

import session_atlas

root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
forgotten = {
    ("default-v1", "sha256:" + format(number + 100000, "064x"))
    for number in range(40000)
}
session_atlas.load_forgotten = lambda _root: forgotten
value = session_atlas.query_cohort(
    root, "default-v1", target, "exact", [], 20, None
)
assert value["items"]
PY
  then
    pass "大量forgetをSQL変数へ展開せずbounded cohort queryを維持する"
  else
    fail "大量forgetをSQL変数へ展開せずbounded cohort queryを維持する"
  fi
}

test_mixed_requires_equal_canonical_finite_value() {
  echo "test_mixed_requires_equal_canonical_finite_value:"
  local value
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && value="$(call_api "$(episode_id 10)" exact '[]' 10 '' 2>/dev/null)" \
    && python3 - "$value" <<'PY'
import json
import sys

value = json.loads(sys.argv[1])
eid = lambda number: "sha256:" + format(number, "064x")
assert [item["episode_id"] for item in value["items"]] == [eid(10), eid(11)]
assert all(item["facets"]["operation"]["state"] == "mixed" for item in value["items"])
assert all(item["facets"]["operation"]["value"] == {
    "coverage": "complete", "kinds": ["test", "build"],
} for item in value["items"])
PY
  then
    pass "mixedは状態名だけでなくcanonical finite valueが等しい時だけ一致する"
  else
    fail "mixedは状態名だけでなくcanonical finite valueが等しい時だけ一致する"
  fi
}

test_facet_reader_rejects_wrong_finite_shape() {
  echo "test_facet_reader_rejects_wrong_finite_shape:"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && ! call_api "$(episode_id 13)" exact '[]' 10 '' \
      >"$TEST_ROOT/wrong-shape.out" 2>"$TEST_ROOT/wrong-shape.err"; then
    pass "sealed Atlas readerはfacetごとのfinite shapeを厳密に検証する"
  else
    fail "sealed Atlas readerはfacetごとのfinite shapeを厳密に検証する"
  fi
}

test_cli_matches_api_and_uses_fixed_match_mask() {
  echo "test_cli_matches_api_and_uses_fixed_match_mask:"
  local target api_file="$TEST_ROOT/api.json" cli_file="$TEST_ROOT/cli.json"
  target="$(episode_id 1)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && call_api "$target" structural '[]' 3 '' >"$api_file" 2>/dev/null \
    && run_cli atlas cohort "$target" --tier structural --limit 3 \
      --policy-version default-v1 --json >"$cli_file" 2>/dev/null \
    && python3 - "$api_file" "$cli_file" <<'PY'
import json
import pathlib
import sys

api, cli = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
assert api == cli
assert len(cli["items"]) == 3
for item in cli["items"]:
    assert tuple(item["match_mask"]) == (
        "context_identity", "event_lifecycle", "operation", "artifact_change",
    )
PY
  then
    pass "atlas cohort CLI/APIは同じ監査可能な固定4-key match_maskを返す"
  else
    fail "atlas cohort CLI/APIは同じ監査可能な固定4-key match_maskを返す"
  fi
}

test_pagination_is_stable_and_cursor_binds_query_and_limit() {
  echo "test_pagination_is_stable_and_cursor_binds_query_and_limit:"
  local target first_file="$TEST_ROOT/page1.json" second_file="$TEST_ROOT/page2.json"
  local cursor
  target="$(episode_id 1)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && call_api "$target" structural '[]' 2 '' >"$first_file" 2>/dev/null \
    && cursor="$(python3 - "$first_file" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["next_cursor"])
PY
)" \
    && [[ -n "$cursor" && "$cursor" != "None" ]] \
    && call_api "$target" structural '[]' 2 "$cursor" >"$second_file" 2>/dev/null \
    && ! call_api "$target" structural '[]' 3 "$cursor" >/dev/null 2>&1 \
    && ! call_api "$target" partial '["operation"]' 2 "$cursor" >/dev/null 2>&1 \
    && python3 - "$first_file" "$second_file" <<'PY'
import json
import pathlib
import sys

first, second = [json.loads(pathlib.Path(path).read_text()) for path in sys.argv[1:]]
first_ids = [item["episode_id"] for item in first["items"]]
second_ids = [item["episode_id"] for item in second["items"]]
assert len(first_ids) == len(second_ids) == 2
assert first_ids == sorted(first_ids) and second_ids == sorted(second_ids)
assert first_ids[-1] < second_ids[0]
assert first["query"]["limit"] == second["query"]["limit"] == 2
PY
  then
    pass "episode_id昇順paginationのcursorをquery specとlimitへbindingする"
  else
    fail "episode_id昇順paginationのcursorをquery specとlimitへbindingする"
  fi
}

test_24k_query_is_bounded_and_cursor_binds_generation() {
  echo "test_24k_query_is_bounded_and_cursor_binds_generation:"
  local target first_file="$TEST_ROOT/scale-page.json" cursor
  target="$(episode_id 20)"
  if [[ "$QUERY_FIXTURE_READY" -eq 1 ]] \
    && call_api "$target" partial '["event_lifecycle"]' 5 '' >"$first_file" 2>/dev/null \
    && cursor="$(python3 - "$first_file" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert len(value["items"]) == 5
assert value["next_cursor"]
print(value["next_cursor"])
PY
)"
  then
    if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" <<'PY'
import json
import pathlib
import sqlite3
import sys

from evidence_index import issue_index_seal
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
database = root / "index" / "vault.sqlite"
connection = sqlite3.connect(database)
generation = "sha256:" + "f" * 64
connection.execute(
    "UPDATE derived_state SET value_json=? "
    "WHERE namespace='authenticated_index_seal' "
    "AND key='projection_generation' AND policy_version='_global'",
    (json.dumps(generation),),
)
connection.commit()
connection.close()
with vault_lock(root):
    issue_index_seal(root)
PY
    then
      if ! call_api "$target" partial '["event_lifecycle"]' 5 "$cursor" \
          >/dev/null 2>&1; then
        pass "24k Episodeでもlimit内だけ返しcursorをsealed projection generationへbindingする"
        return
      fi
    fi
  fi
  fail "24k Episodeでもlimit内だけ返しcursorをsealed projection generationへbindingする"
}

test_inspect_exposes_session_atlas_as_independent_json_and_human_section() {
  echo "test_inspect_exposes_session_atlas_as_independent_json_and_human_section:"
  local episode json_file="$TEST_ROOT/atlas-inspect.json"
  local human_file="$TEST_ROOT/atlas-inspect.txt"
  episode="$(episode_id_for_event_at "$REPORT_STATE" 51000000-0000-4000-8000-000000000001)"
  if run_cli_at "$REPORT_STATE" inspect "$episode" --json \
      >"$json_file" 2>"$TEST_ROOT/atlas-inspect.err" \
    && run_cli_at "$REPORT_STATE" inspect "$episode" \
      >"$human_file" 2>"$TEST_ROOT/atlas-inspect-human.err" \
    && python3 - "$json_file" "$human_file" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
human = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert value["schema_version"] == 6
facets = value["session_atlas_facets"]
assert set(facets) == {
    "context_identity", "event_lifecycle", "operation", "artifact_change",
}
for facet in facets.values():
    assert set(facet) == {"state", "value"}
    assert facet["state"] in {"present", "mixed", "unknown"}
    assert (facet["value"] is None) == (facet["state"] == "unknown")
assert "session_atlas_facets" not in value["card"]
assert all("session_atlas_facets" not in item for item in value["semantic_receipts"])
assert all("session_atlas_facets" not in item for item in value["value_primitive_cards"])
assert "Session Atlas facets:" in human
for name in facets:
    assert name in human
PY
  then
    pass "inspectはAtlasをMeaning/Receipt/Valueと独立したJSON/human sectionで表示する"
  else
    fail "inspectはAtlasをMeaning/Receipt/Valueと独立したJSON/human sectionで表示する"
  fi
}

test_report_exposes_session_atlas_as_independent_json_and_human_section() {
  echo "test_report_exposes_session_atlas_as_independent_json_and_human_section:"
  local episode json_file="$TEST_ROOT/atlas-report.json"
  local human_file="$TEST_ROOT/atlas-report.txt"
  episode="$(episode_id_for_event_at "$REPORT_STATE" 51000000-0000-4000-8000-000000000001)"
  if run_cli_at "$REPORT_STATE" report --last 365d --json \
      >"$json_file" 2>"$TEST_ROOT/atlas-report.err" \
    && run_cli_at "$REPORT_STATE" report --last 365d \
      >"$human_file" 2>"$TEST_ROOT/atlas-report-human.err" \
    && python3 - "$json_file" "$human_file" "$episode" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
human = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert value["schema_version"] == 4
card = next(item for item in value["cards"] if item["episode_id"] == sys.argv[3])
assert card["schema_version"] == 3
assert "session_atlas_facets" not in card
assert set(value["session_atlas_facets"]) == {
    item["episode_id"] for item in value["cards"]
}
facets = value["session_atlas_facets"][sys.argv[3]]
assert set(facets) == {
    "context_identity", "event_lifecycle", "operation", "artifact_change",
}
for facet in facets.values():
    assert set(facet) == {"state", "value"}
assert all("session_atlas_facets" not in item for item in card["deterministic_evidence"])
assert all("session_atlas_facets" not in item for item in card["model_evaluations"])
assert "Session Atlas facets:" in human
for name in facets:
    assert name in human
PY
  then
    pass "reportは各EpisodeのAtlasを独立したJSON/human sectionで表示する"
  else
    fail "reportは各EpisodeのAtlasを独立したJSON/human sectionで表示する"
  fi
}

test_forget_hides_atlas_everywhere_and_tamper_fails_sealed_query() {
  echo "test_forget_hides_atlas_everywhere_and_tamper_fails_sealed_query:"
  local forgotten peer before after report_file="$TEST_ROOT/forgotten-report.json"
  forgotten="$(episode_id_for_event_at "$REPORT_STATE" 51000000-0000-4000-8000-000000000001)"
  peer="$(episode_id_for_event_at "$REPORT_STATE" 51000000-0000-4000-8000-000000000301)"
  if before="$(call_api_at "$REPORT_STATE" "$peer" exact '[]' 100 '' 2>/dev/null)" \
    && python3 - "$before" "$forgotten" <<'PY'
import json
import sys
assert sys.argv[2] in [item["episode_id"] for item in json.loads(sys.argv[1])["items"]]
PY
  then
    if run_cli_at "$REPORT_STATE" forget "$forgotten" --json \
        >/dev/null 2>"$TEST_ROOT/forget.err" \
      && ! call_api_at "$REPORT_STATE" "$forgotten" exact '[]' 10 '' \
        >/dev/null 2>&1 \
      && after="$(call_api_at "$REPORT_STATE" "$peer" exact '[]' 100 '' 2>/dev/null)" \
      && ! run_cli_at "$REPORT_STATE" inspect "$forgotten" --json >/dev/null 2>&1 \
      && run_cli_at "$REPORT_STATE" report --last 365d --json \
        >"$report_file" 2>/dev/null \
      && python3 - "$REPORT_STATE/index/vault.sqlite" "$after" "$report_file" \
        "$forgotten" <<'PY'
import json
import pathlib
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute(
    "SELECT COUNT(*) FROM session_atlas_facets "
    "WHERE policy_version='default-v1' AND episode_id=?",
    (sys.argv[4],),
).fetchone()[0] == 1
after = json.loads(sys.argv[2])
assert sys.argv[4] not in [item["episode_id"] for item in after["items"]]
report = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
assert sys.argv[4] not in [card["episode_id"] for card in report["cards"]]
PY
    then
      python3 - "$REPORT_STATE/index/vault.sqlite" "$peer" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "UPDATE session_atlas_facets SET operation_value_json='\"tampered\"' "
    "WHERE policy_version='default-v1' AND episode_id=?",
    (sys.argv[2],),
)
connection.commit()
PY
      if ! call_api_at "$REPORT_STATE" "$peer" exact '[]' 10 '' \
          >/dev/null 2>&1; then
        pass "forgetはAtlas rowを保持して全readから隠しAtlas改竄をsealで拒否する"
        return
      fi
    fi
  fi
  fail "forgetはAtlas rowを保持して全readから隠しAtlas改竄をsealで拒否する"
}

echo "=== Flight Recorder Session Atlas Tests ==="
build_fixture || true
TESTS=(
  test_projection_is_one_row_per_episode_without_treatment_leakage
  test_projection_preserves_present_mixed_and_unknown
  test_materialize_replaces_existing_rows_idempotently
  test_scalar_mixed_values_are_sorted_and_unique
  test_operation_coverage_uses_only_tool_completed_denominator
  test_artifact_change_uses_bounded_finite_shapes_without_raw_identifiers
)
for test_name in "${TESTS[@]}"; do
  "$test_name"
done
prepare_report_fixture
seed_query_fixture >/dev/null 2>&1 || true
QUERY_TESTS=(
  test_exact_structural_and_partial_tiers
  test_custom_policy_requires_owner_held_policy_for_cli_and_api
  test_unknown_never_matches_and_partial_requires_nonempty_facets
  test_large_forgotten_set_does_not_expand_sql_variables
  test_mixed_requires_equal_canonical_finite_value
  test_facet_reader_rejects_wrong_finite_shape
  test_cli_matches_api_and_uses_fixed_match_mask
  test_pagination_is_stable_and_cursor_binds_query_and_limit
  test_24k_query_is_bounded_and_cursor_binds_generation
  test_inspect_exposes_session_atlas_as_independent_json_and_human_section
  test_report_exposes_session_atlas_as_independent_json_and_human_section
  test_forget_hides_atlas_everywhere_and_tamper_fails_sealed_query
)
for test_name in "${QUERY_TESTS[@]}"; do
  "$test_name"
done
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
