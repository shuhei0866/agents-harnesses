#!/usr/bin/env bash
# Forget and best-effort purge contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)"
PASS=0
FAIL=0
TARGET_EVENT="40000000-0000-4000-8000-000000000001"
UNRELATED_EVENT="40000000-0000-4000-8000-000000000002"

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

append_event() {
  local state="$1" event_id="$2" seconds_ago="$3" task_digit="$4"
  mkdir -p "$state/inbox"
  python3 - \
    "$state/inbox/events.jsonl" "$event_id" "$seconds_ago" "$task_digit" <<'PY'
import datetime as dt
import json
import pathlib
import sys

path, event_id, seconds_ago, task_digit = sys.argv[1:]
recorded_at = (
    dt.datetime.now(dt.timezone.utc)
    - dt.timedelta(seconds=int(seconds_ago))
).replace(microsecond=0).isoformat().replace("+00:00", "Z")
event = {
    "schema_version": 2,
    "event_id": event_id,
    "recorded_at": recorded_at,
    "harness": "codex",
    "source_event": "turn.complete",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + "a" * 24,
    "turn_id_hash": None,
    "workspace_id": "sha256:" + "b" * 24,
    "model": "fixture-model",
    "permission_mode": None,
    "tool": None,
    "metrics": None,
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": "sha256:" + task_digit * 24,
        "task_source": "payload",
        "branch_or_worktree_id": "sha256:" + "c" * 24,
        "changed_file_fingerprints": ["sha256:" + task_digit * 24],
        "changed_files_state": "complete",
    },
}
with pathlib.Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

init_fixture() {
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
  append_event "$state" "$TARGET_EVENT" 120 1
  run_cli "$state" sync >/dev/null 2>&1
  append_event "$state" "$UNRELATED_EVENT" 60 2
  run_cli "$state" sync >/dev/null 2>&1
  run_cli "$state" rebuild-index >/dev/null 2>&1
}

db_value_for_event() {
  local db="$1" event_id="$2" column="$3"
  python3 - "$db" "$event_id" "$column" <<'PY'
import sqlite3
import sys

db, event_id, column = sys.argv[1:]
allowed = {
    "episode_id": (
        "SELECT episode_id FROM episode_members "
        "WHERE policy_version = 'default-v1' AND event_id = ?"
    ),
    "source_path": (
        "SELECT c.source_path FROM source_events e "
        "JOIN source_chunks c ON c.chunk_id = e.chunk_id WHERE e.event_id = ?"
    ),
    "cache_path": (
        "SELECT p.cache_path FROM source_events e "
        "JOIN import_provenance p ON p.chunk_id = e.chunk_id WHERE e.event_id = ?"
    ),
}
row = sqlite3.connect(f"file:{db}?mode=ro", uri=True).execute(
    allowed[column], (event_id,)
).fetchone()
assert row is not None
print(row[0])
PY
}

source_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for table in ("source_chunks", "source_events", "import_provenance"):
    rows = connection.execute(f"SELECT * FROM {table} ORDER BY 1").fetchall()
    print(table, hashlib.sha256(repr(rows).encode()).hexdigest())
PY
}

evidence_file_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = sorted((root / "devices").rglob("*.jsonl.age"))
paths += sorted((root / "cache" / "imported").rglob("*.jsonl"))
paths += sorted((root / "evaluations").glob("*.json"))
paths.append(root / "index" / "imported-chunks.json")
for path in paths:
    print(path.relative_to(root), hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

evaluation_count() {
  if [[ ! -d "$1/evaluations" ]]; then
    echo 0
    return
  fi
  find "$1/evaluations" -type f -name '*.json' | wc -l | tr -d ' '
}

test_forget_preserves_source_and_survives_rebuild() {
  echo "test_forget_preserves_source_and_survives_rebuild:"
  local base="$TEST_ROOT/forget"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local episode unrelated before_source before_files report
  init_fixture "$base" || {
    fail "forget fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  unrelated="$(db_value_for_event "$db" "$UNRELATED_EVENT" episode_id)"
  before_source="$(source_snapshot "$db")"
  before_files="$(evidence_file_snapshot "$state")"

  if ! run_cli "$state" forget "$episode" >/dev/null 2>&1; then
    fail "episodeをforgetできる"
    return
  fi
  if ! run_cli "$state" rebuild-index >/dev/null 2>&1 \
    || ! run_cli "$state" rebuild-relationships >/dev/null 2>&1; then
    fail "forget後にindexとrelationshipを再評価できる"
    return
  fi
  report="$base/report.json"
  if run_cli "$state" report --last 365d --json >"$report" 2>/dev/null \
    && [[ "$before_source" == "$(source_snapshot "$db")" \
      && "$before_files" == "$(evidence_file_snapshot "$state")" ]] \
    && python3 - "$report" "$episode" "$unrelated" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
episode_ids = {card["episode_id"] for card in value["cards"]}
assert sys.argv[2] not in episode_ids
assert sys.argv[3] in episode_ids
PY
  then
    pass "forgetはsource evidenceを保持しfull rebuild後も再評価から除外する"
  else
    fail "forgetはsource evidenceを保持しfull rebuild後も再評価から除外する"
  fi
}

test_dangling_forget_marker_fails_closed() {
  echo "test_dangling_forget_marker_fails_closed:"
  local base="$TEST_ROOT/dangling-forget"
  local state="$base/vault"
  init_fixture "$base" || {
    fail "dangling forget fixtureを作成できる"
    return
  }
  ln -s "$base/missing-marker.json" \
    "$state/index/forgotten-episodes.json"
  if run_cli "$state" report --last 365d --json \
    >"$base/report.json" 2>"$base/report.err"; then
    fail "dangling forget markerを未設定として扱わない"
  elif [[ ! -s "$base/report.json" ]] \
    && grep -Fq "forgotten episode state is unsafe" "$base/report.err"; then
    pass "dangling forget markerはepisodeを再露出せずfail closedする"
  else
    fail "dangling forget markerはepisodeを再露出せずfail closedする"
  fi
}

test_purge_dry_run_previews_scope_without_rewriting_history() {
  echo "test_purge_dry_run_previews_scope_without_rewriting_history:"
  local base="$TEST_ROOT/purge-preview"
  local state="$base/vault"
  local remote="$base/remote.git" db="$state/index/vault.sqlite"
  local episode target_path unrelated_path local_head remote_head output
  init_fixture "$base" || {
    fail "purge preview fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  run_cli "$state" evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model --json >/dev/null 2>&1 || {
      fail "purge対象episodeのevaluationを作成できる"
      return
    }
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  unrelated_path="$(db_value_for_event "$db" "$UNRELATED_EVENT" source_path)"
  local_head="$(git -C "$state" rev-parse HEAD)"
  remote_head="$(git --git-dir="$remote" rev-parse main)"
  output="$base/preview.txt"

  if run_cli "$state" purge "$episode" >"$output" 2>"$base/preview.err" \
    && grep -Fq "$target_path" "$output" \
    && ! grep -Fq "$unrelated_path" "$output" \
    && grep -Eiq 'best[- ]effort' "$output" \
    && grep -Eiq '(independent|remote|uncontrolled)[ -]?clone' "$output" \
    && grep -Eiq 'provider.*cache|cache.*provider' "$output" \
    && [[ "$local_head" == "$(git -C "$state" rev-parse HEAD)" \
      && "$remote_head" == "$(git --git-dir="$remote" rev-parse main)" ]] \
    && git -C "$state" cat-file -e "HEAD:$target_path" \
    && git --git-dir="$remote" cat-file -e "main:$target_path"; then
    pass "purge dry-runは対象scopeと限界を表示し--applyなしで履歴を書き換えない"
  else
    fail "purge dry-runは対象scopeと限界を表示し--applyなしで履歴を書き換えない"
  fi
}

test_purge_apply_removes_target_history_and_keeps_unrelated_chunk() {
  echo "test_purge_apply_removes_target_history_and_keeps_unrelated_chunk:"
  local base="$TEST_ROOT/purge-apply"
  local state="$base/vault"
  local remote="$base/remote.git" db="$state/index/vault.sqlite"
  local episode target_path unrelated_path target_cache unrelated_cache
  local history_objects="$base/remote-history-objects.txt"
  init_fixture "$base" || {
    fail "purge apply fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  unrelated_path="$(db_value_for_event "$db" "$UNRELATED_EVENT" source_path)"
  target_cache="$(db_value_for_event "$db" "$TARGET_EVENT" cache_path)"
  unrelated_cache="$(db_value_for_event "$db" "$UNRELATED_EVENT" cache_path)"

  if ! run_cli "$state" purge "$episode" --apply \
    >"$base/apply.txt" 2>"$base/apply.err"; then
    fail "明示的な--applyでpurgeできる"
    return
  fi
  git --git-dir="$remote" rev-list --objects --all >"$history_objects"
  if [[ ! -e "$state/$target_path" \
    && -f "$state/$unrelated_path" \
    && ! -e "$state/$target_cache" \
    && -f "$state/$unrelated_cache" \
    && "$(evaluation_count "$state")" == "0" ]] \
    && ! grep -Fq " $target_path" "$history_objects" \
    && grep -Fq " $unrelated_path" "$history_objects" \
    && python3 - "$db" "$TARGET_EVENT" "$UNRELATED_EVENT" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
target = connection.execute(
    "SELECT COUNT(*) FROM source_events WHERE event_id = ?", (sys.argv[2],)
).fetchone()[0]
unrelated = connection.execute(
    "SELECT COUNT(*) FROM source_events WHERE event_id = ?", (sys.argv[3],)
).fetchone()[0]
assert target == 0
assert unrelated == 1
PY
  then
    pass "purgeは対象chunk・local evaluationを除去しunrelated chunkを保持する"
  else
    fail "purgeは対象chunk・local evaluationを除去しunrelated chunkを保持する"
  fi
}

test_purge_push_rejection_restores_retryable_local_state() {
  echo "test_purge_push_rejection_restores_retryable_local_state:"
  local base="$TEST_ROOT/purge-push-rejection"
  local state="$base/vault"
  local remote="$base/remote.git" db="$state/index/vault.sqlite"
  local episode target_path target_cache
  local before_head before_remote before_source before_files
  init_fixture "$base" || {
    fail "push rejection fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  run_cli "$state" evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model --json >/dev/null 2>&1 || {
      fail "push rejection対象episodeのevaluationを作成できる"
      return
    }
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  target_cache="$(db_value_for_event "$db" "$TARGET_EVENT" cache_path)"
  before_head="$(git -C "$state" rev-parse HEAD)"
  before_remote="$(git --git-dir="$remote" rev-parse main)"
  before_source="$(source_snapshot "$db")"
  before_files="$(evidence_file_snapshot "$state")"

  git --git-dir="$remote" config receive.denyNonFastForwards true
  if run_cli "$state" purge "$episode" --apply \
    >"$base/rejected.txt" 2>"$base/rejected.err"; then
    fail "force-push拒否時はpurgeを失敗として返す"
    return
  fi

  if [[ "$before_head" != "$(git -C "$state" rev-parse HEAD)" \
    || "$before_remote" != "$(git --git-dir="$remote" rev-parse main)" \
    || "$before_source" != "$(source_snapshot "$db")" \
    || "$before_files" != "$(evidence_file_snapshot "$state")" \
    || ! -f "$state/$target_path" \
    || ! -f "$state/$target_cache" ]] \
    || grep -q "Traceback" "$base/rejected.err" \
    || ! run_cli "$state" purge "$episode" \
      >"$base/retry-preview.txt" 2>"$base/retry-preview.err"; then
    fail "push拒否時はlocal evidenceを復元しpurgeを再試行可能に保つ"
    return
  fi

  git --git-dir="$remote" config receive.denyNonFastForwards false
  if run_cli "$state" purge "$episode" --apply \
    >"$base/retry.txt" 2>"$base/retry.err" \
    && [[ ! -e "$state/$target_path" \
      && ! -e "$state/$target_cache" \
      && "$(evaluation_count "$state")" == "0" ]] \
    && ! git --git-dir="$remote" cat-file -e \
      "main:$target_path" 2>/dev/null; then
    pass "push拒否後はlocal stateを復元し同じpurgeを安全に再試行できる"
  else
    fail "push拒否後はlocal stateを復元し同じpurgeを安全に再試行できる"
  fi
}

echo "=== Flight Recorder Retention Tests ==="
test_forget_preserves_source_and_survives_rebuild
test_dangling_forget_marker_fails_closed
test_purge_dry_run_previews_scope_without_rewriting_history
test_purge_apply_removes_target_history_and_keeps_unrelated_chunk
test_purge_push_rejection_restores_retryable_local_state
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
