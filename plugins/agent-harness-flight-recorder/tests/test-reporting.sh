#!/usr/bin/env bash
# status/report/inspect and Episode Evidence Card contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)"
STATE="$TEST_ROOT/vault"
SCHEDULER_CALL_LOG="$TEST_ROOT/scheduler-calls.log"
SCHEDULER_MANAGER_STATE="$TEST_ROOT/scheduler-manager-state"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$TEST_HOME"
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
  PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    FLIGHT_RECORDER_STATE_DIR="$STATE" \
    FLIGHT_RECORDER_SCHEDULER_CALL_LOG="$SCHEDULER_CALL_LOG" \
    FLIGHT_RECORDER_SCHEDULER_MANAGER_STATE="$SCHEDULER_MANAGER_STATE" \
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
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  make_identity "$recovery"
  run_cli init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" <<'PY'
import datetime as dt
import json
import pathlib
import sys

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
task_one = "sha256:" + "1" * 24
task_two = "sha256:" + "2" * 24
workspace = "sha256:" + "3" * 24


def timestamp(seconds):
    return (now - dt.timedelta(seconds=seconds)).isoformat().replace("+00:00", "Z")


def event(event_id, seconds, harness, task, model, metrics, outcome):
    return {
        "schema_version": 2,
        "event_id": event_id,
        "recorded_at": timestamp(seconds),
        "harness": harness,
        "source_event": "Stop",
        "event_kind": "turn.completed",
        "session_id_hash": "sha256:" + "a" * 24,
        "turn_id_hash": None,
        "workspace_id": workspace,
        "model": model,
        "permission_mode": None,
        "tool": None,
        "metrics": metrics,
        "outcome": outcome,
        "relationship_context": {
            "task_id_hash": task,
            "task_source": "payload",
            "branch_or_worktree_id": "sha256:" + "4" * 24,
            "changed_file_fingerprints": ["sha256:" + "5" * 24],
            "changed_files_state": "complete",
        },
    }


events = [
    event(
        "30000000-0000-4000-8000-000000000001",
        600,
        "claude-code",
        task_one,
        "claude-test",
        {"duration_ms": 1200, "total_cost_usd": 0.01},
        {"status": "success", "exit_code": 0},
    ),
    event(
        "30000000-0000-4000-8000-000000000002",
        300,
        "codex",
        task_one,
        "codex-test\nINJECTED",
        None,
        None,
    ),
    event(
        "30000000-0000-4000-8000-000000000003",
        60,
        "codex",
        task_two,
        None,
        None,
        None,
    ),
]
# Exercise chronological ordering independently of RFC 3339 text offsets.
events[0]["recorded_at"] = (
    now - dt.timedelta(seconds=600)
).astimezone(dt.timezone(dt.timedelta(hours=9))).isoformat()
path = pathlib.Path(sys.argv[1])
path.write_text(
    "".join(
        json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n"
        for item in events
    ),
    encoding="utf-8",
)
PY
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
}

episode_id_for() {
  python3 - "$STATE/index/vault.sqlite" "$1" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT episode_id FROM episode_members "
    "WHERE policy_version = 'default-v1' AND event_id = ?",
    (sys.argv[2],),
).fetchone()
assert row is not None
print(row[0])
PY
}

test_status_contract() {
  echo "test_status_contract:"
  local json_output="$TEST_ROOT/status.json" human_output="$TEST_ROOT/status.txt"
  if run_cli status --json >"$json_output" 2>"$TEST_ROOT/status.err" \
    && run_cli status >"$human_output" 2>"$TEST_ROOT/status-human.err" \
    && python3 - "$json_output" "$human_output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
human = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert value["schema_version"] == 3
assert value["command"] == "status"
assert set(value) == {
    "schema_version", "command", "overall", "vault", "sync", "index", "queue",
    "scheduler"
}
assert value["vault"]["state"] == "initialized"
assert value["sync"]["state"] == "idle"
assert value["sync"]["pending"] is False
assert value["sync"]["pending_chunk_count"] == 0
assert value["sync"]["failure_class"] is None
assert value["sync"]["diagnostic_code"] is None
assert value["sync"]["next_action_code"] is None
assert value["sync"]["next_retry_at"] is None
assert value["sync"]["consecutive_failure_count"] == 0
assert value["index"]["state"] == "ready"
assert value["index"]["source_event_count"] == 3
assert value["index"]["episode_count"] == 2
assert value["queue"]["pending_count"] == 0
assert value["scheduler"]["state"] == "unconfigured"
assert value["scheduler"]["configured"] is False
assert "status" in human.lower()
assert "ready" in human.lower()
assert "scheduler" in human.lower()
PY
  then
    pass "statusはsync/index/queue healthをJSONと人間表示で返す"
  else
    fail "statusはsync/index/queue healthをJSONと人間表示で返す"
  fi

  mkdir -p "$STATE/queue"
  python3 - "$STATE/queue/pending-sync.json" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1,
    "phase": "pull_pending",
    "attempt_count": 2,
    "artifact_paths": [
        "devices/00000000-0000-4000-8000-000000000001/"
        "2026/07/25/" + "a" * 64 + ".jsonl.age",
        "devices/00000000-0000-4000-8000-000000000001/"
        "2026/07/25/" + "b" * 64 + ".jsonl.age",
    ],
}), encoding="utf-8")
PY
  mkdir -m 700 -p "$STATE/scheduler"
  printf '%s\n' \
    '{"consecutive_failure_count":2,"diagnostic_code":"remote_unavailable","failure_class":"transient","last_attempt_at":"2026-07-25T00:00:00Z","last_error_category":"remote","last_success_at":null,"next_action_code":"retry_automatically","next_retry_at":"2026-07-25T00:10:00Z","schema_version":2}' \
    >"$STATE/scheduler/state.json"
  chmod 600 "$STATE/scheduler/state.json"
  if run_cli status --json >"$json_output" 2>"$TEST_ROOT/status-pending.err" \
    && python3 - "$json_output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["sync"]["state"] == "pending"
assert value["sync"]["pending"] is True
assert value["sync"]["pending_phase"] == "pull_pending"
assert value["sync"]["attempt_count"] == 2
assert value["sync"]["pending_chunk_count"] == 2
assert value["sync"]["last_success_at"] is None
assert value["sync"]["failure_class"] == "transient"
assert value["sync"]["diagnostic_code"] == "remote_unavailable"
assert value["sync"]["next_action_code"] == "retry_automatically"
assert value["sync"]["next_retry_at"] == "2026-07-25T00:10:00Z"
assert value["sync"]["consecutive_failure_count"] == 2
assert value["queue"]["pending_count"] == 1
assert value["overall"] == "attention"
PY
  then
    pass "statusはpending syncを成功済みと推測せずdegraded表示する"
  else
    fail "statusはpending syncを成功済みと推測せずdegraded表示する"
  fi
  rm "$STATE/queue/pending-sync.json"

  printf '%s\n' '{"detached":"fixture"}' \
    >"$STATE/queue/00000000-0000-4000-8000-000000000001.jsonl.pending"
  if run_cli status --json >"$json_output" 2>"$TEST_ROOT/status-rotation.err" \
    && python3 - "$json_output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["queue"]["state"] == "pending"
assert value["queue"]["pending_count"] == 1
assert value["queue"]["rotation_job_count"] == 1
assert value["overall"] == "attention"
PY
  then
    pass "statusはdetached rotation retry jobをpendingとして数える"
  else
    fail "statusはdetached rotation retry jobをpendingとして数える"
  fi
  rm "$STATE/queue/00000000-0000-4000-8000-000000000001.jsonl.pending"

  ln -s "$TEST_ROOT/missing-pending" "$STATE/queue/pending-sync.json"
  if run_cli status --json >"$json_output" 2>"$TEST_ROOT/status-symlink.err" \
    && python3 - "$json_output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["sync"]["state"] == "invalid"
assert set(value["sync"]) == {
    "state",
    "pending",
    "pending_phase",
    "attempt_count",
    "pending_chunk_count",
    "imported_chunk_count",
    "last_success_at",
    "failure_class",
    "diagnostic_code",
    "next_action_code",
    "next_retry_at",
    "consecutive_failure_count",
}
assert all(
    item is None
    for key, item in value["sync"].items()
    if key != "state"
)
assert value["queue"]["state"] == "invalid"
PY
  then
    pass "statusはbroken pending symlinkをidleと偽装しない"
  else
    fail "statusはbroken pending symlinkをidleと偽装しない"
  fi
  rm "$STATE/queue/pending-sync.json"
}

test_report_grounded_cards() {
  echo "test_report_grounded_cards:"
  local output="$TEST_ROOT/report.json" human="$TEST_ROOT/report.txt"
  if run_cli report --last 1h --json >"$output" 2>"$TEST_ROOT/report.err" \
    && run_cli report --last 1h >"$human" 2>"$TEST_ROOT/report-human.err" \
    && python3 - "$output" "$human" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
human = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert value["schema_version"] == 3
assert value["command"] == "report"
assert value["policy_version"] == "default-v1"
assert value["window"]["requested"] == "1h"
assert len(value["cards"]) == 2
assert value["cards"] == sorted(
    value["cards"],
    key=lambda card: (card["time"]["last_recorded_at"], card["episode_id"]),
    reverse=True,
)
linked = next(card for card in value["cards"] if card["event_count"] == 2)
singleton = next(card for card in value["cards"] if card["event_count"] == 1)
assert linked["harnesses"] == ["claude-code", "codex"]
assert linked["models"] == ["claude-test", "codex-test\nINJECTED"]
assert linked["model_coverage"] == {
    "state": "complete",
    "known_event_count": 2,
    "total_event_count": 2,
}
assert linked["task_type"] is None
assert linked["retry_count"] == {
    "value": None,
    "state": "missing",
    "aggregation": "sum_of_recorded_values",
    "known_event_count": 0,
    "total_event_count": 2,
}
assert len(linked["deterministic_evidence"]) == 3
assert linked["measured_duration_ms"] == {
    "value": 1200,
    "state": "partial",
    "aggregation": "sum_of_recorded_values",
    "known_event_count": 1,
    "total_event_count": 2,
}
assert linked["measured_cost_usd"] == {
    "value": 0.01,
    "state": "partial",
    "aggregation": "sum_of_recorded_values",
    "known_event_count": 1,
    "total_event_count": 2,
}
assert linked["deterministic_outcomes"]["success"] == 1
assert linked["deterministic_outcomes"]["not_recorded"] == 1
assert singleton["task_type"] is None
assert singleton["retry_count"]["state"] == "missing"
assert singleton["deterministic_evidence"] == []
assert singleton["model_coverage"]["state"] == "missing"
assert singleton["measured_duration_ms"]["value"] is None
assert singleton["measured_cost_usd"]["value"] is None
assert singleton["confidence"] is None
assert linked["episode_id"] in human
assert "codex-test\\nINJECTED" in human
assert "\nINJECTED" not in human
PY
  then
    pass "reportは期間内episodeをgrounded cardとしてstableに要約する"
  else
    fail "reportは期間内episodeをgrounded cardとしてstableに要約する"
  fi
}

test_inspect_supporting_evidence() {
  echo "test_inspect_supporting_evidence:"
  local episode output human
  episode="$(episode_id_for 30000000-0000-4000-8000-000000000001)"
  output="$TEST_ROOT/inspect.json"
  human="$TEST_ROOT/inspect.txt"
  if run_cli inspect "$episode" --json >"$output" 2>"$TEST_ROOT/inspect.err" \
    && run_cli inspect "$episode" >"$human" 2>"$TEST_ROOT/inspect-human.err" \
    && python3 - "$output" "$human" "$episode" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
human = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
episode = sys.argv[3]
assert value["schema_version"] == 5
assert value["command"] == "inspect"
assert value["policy_version"] == "default-v1"
assert value["semantic_receipts"] == []
assert value["card"]["episode_id"] == episode
assert value["card"]["source_event_ids"] == [
    "30000000-0000-4000-8000-000000000001",
    "30000000-0000-4000-8000-000000000002",
]
assert len(value["supporting_edges"]) == 1
edge = value["supporting_edges"][0]
assert edge["decision"] == "link"
assert set(edge["evidence"]) == {
    "explicit_task_id",
    "workspace_id",
    "branch_or_worktree_id",
    "time_distance",
    "changed_file_fingerprints",
    "contradictory_task_ids",
}
assert episode in human
assert "30000000-0000-4000-8000-000000000001" in human
assert "explicit_task_id" in human
assert "contradictory_task_ids" in human
assert "Model-derived semantic receipts:" in human
PY
  then
    pass "inspectはepisode形成根拠とsource evidence IDを示す"
  else
    fail "inspectはepisode形成根拠とsource evidence IDを示す"
  fi
}

test_on_demand_model_evaluation() {
  echo "test_on_demand_model_evaluation:"
  local episode output preview artifact capture evaluation_root before after
  local preview_token status=0
  episode="$(episode_id_for 30000000-0000-4000-8000-000000000001)"
  output="$TEST_ROOT/evaluate.json"
  preview="$TEST_ROOT/evaluate-preview.json"
  artifact="$TEST_ROOT/additional-artifact.txt"
  capture="$TEST_ROOT/evaluator-request.json"
  evaluation_root="$STATE/evaluations"
  printf '%s\n' "PRIVATE_ARTIFACT_BODY_iam116" >"$artifact"

  if FLIGHT_RECORDER_NOW="2026-07-25T12:00:00Z" \
    FLIGHT_RECORDER_TEST_EVALUATOR_CAPTURE="$capture" \
    run_cli evaluate "$episode" \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
      --json >"$output" 2>"$TEST_ROOT/evaluate.err" \
    && python3 - "$output" "$capture" "$evaluation_root" "$STATE" <<'PY'
import json
import pathlib
import subprocess
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
request = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[3])
state = pathlib.Path(sys.argv[4])
records = list(root.glob("*.json"))
assert value["schema_version"] == 1
assert value["command"] == "evaluate"
assert value["mode"] == "completed"
evaluation = value["evaluation"]
assert evaluation["rubric_version"] == "on-demand-v1"
assert evaluation["evaluator"] == "flight-recorder-evaluator"
assert evaluation["evaluator_sha256"].startswith("sha256:")
assert evaluation["model"] == "evaluator-test-model"
assert evaluation["conclusion"] == "successful"
assert evaluation["confidence"] == "high"
assert evaluation["artifact_hashes"] == []
assert evaluation["evidence_ids"]
assert evaluation["input_fingerprint"].startswith("sha256:")
assert len(records) == 1
stored = records[0].read_text(encoding="utf-8")
assert "PRIVATE_ARTIFACT_BODY_iam116" not in stored
assert request["metadata_only"] is True
assert request["artifacts"] == []
assert request["schema_version"] == 1
assert set(request) == {
    "schema_version", "rubric", "model", "metadata_only",
    "episode", "artifacts",
}
assert evaluation["schema_version"] == 1
assert evaluation["evaluator_protocol_version"] == 1
assert "trigger" not in evaluation
assert "measured_cost_microusd" not in evaluation
assert "source_event_ids" not in request["episode"]
assert "models" not in request["episode"]
assert "INJECTED" not in json.dumps(request)
assert evaluation["source_evidence_ids"]
assert set(evaluation["evidence_ids"]).issubset(
    set(evaluation["source_evidence_ids"])
)
assert "/evaluations/\n" in (state / ".gitignore").read_text(encoding="utf-8")
assert subprocess.check_output(
    ["git", "-C", str(state), "status", "--porcelain", "--", "evaluations"],
    text=True,
) == ""
PY
  then
    pass "metadata-only評価を既定にし有限値provenanceだけを保存する"
  else
    cat "$TEST_ROOT/evaluate.err" >&2
    fail "metadata-only評価を既定にし有限値provenanceだけを保存する"
    return
  fi

  before="$(python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value["evaluation"]["input_fingerprint"])
PY
)"
  if FLIGHT_RECORDER_NOW="2026-07-25T12:00:00Z" \
    run_cli evaluate "$episode" \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
      --json >"$output" 2>"$TEST_ROOT/evaluate-repeat.err" \
    && [[ "$before" == "$(python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value["evaluation"]["input_fingerprint"])
PY
)" ]] \
    && [[ "$(find "$evaluation_root" -type f -name '*.json' | wc -l | tr -d ' ')" == "1" ]]
  then
    pass "同じrubric・model・evidenceの再評価provenanceを安定化する"
  else
    fail "同じrubric・model・evidenceの再評価provenanceを安定化する"
  fi

  rm -f "$capture"
  if run_cli evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model \
    --artifact "$artifact" \
    --json >"$preview" 2>"$TEST_ROOT/evaluate-preview.err" \
    && [[ ! -e "$capture" ]] \
    && python3 - "$preview" "$artifact" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["command"] == "evaluate"
assert value["mode"] == "artifact_scope_preview"
assert value["requires_explicit_permission"] is True
assert value["artifact_scope"] == [{
    "path": str(pathlib.Path(sys.argv[2]).resolve()),
    "size_bytes": len("PRIVATE_ARTIFACT_BODY_iam116\n".encode()),
}]
assert value["artifact_preview_token"].startswith("hmac-sha256:")
PY
  then
    pass "追加artifactはmodel実行前にscope previewと明示許可を要求する"
  else
    fail "追加artifactはmodel実行前にscope previewと明示許可を要求する"
  fi

  preview_token="$(python3 - "$preview" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value["artifact_preview_token"])
PY
)"
  status=0
  run_cli evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model \
    --artifact "$artifact" \
    --allow-artifact-content \
    --json >"$TEST_ROOT/evaluate-bypass.out" \
    2>"$TEST_ROOT/evaluate-bypass.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/evaluate-bypass.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/evaluate-bypass.err"; then
    pass "artifact本文許可は直前preview receiptなしでは迂回できない"
  else
    fail "artifact本文許可は直前preview receiptなしでは迂回できない"
  fi

  python3 - "$artifact" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
original = path.read_bytes()
replacement = b"X" * (len(original) - 1) + b"\n"
assert len(replacement) == len(original)
path.write_bytes(replacement)
PY
  status=0
  run_cli evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model \
    --artifact "$artifact" \
    --allow-artifact-content \
    --artifact-preview-token "$preview_token" \
    --json >"$TEST_ROOT/evaluate-replaced.out" \
    2>"$TEST_ROOT/evaluate-replaced.err" || status=$?
  printf '%s\n' "PRIVATE_ARTIFACT_BODY_iam116" >"$artifact"
  run_cli evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model \
    --artifact "$artifact" \
    --json >"$preview" 2>"$TEST_ROOT/evaluate-preview-refresh.err"
  preview_token="$(python3 - "$preview" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text())["artifact_preview_token"])
PY
)"
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/evaluate-replaced.out" ]]; then
    pass "preview後の同サイズartifact差し替えをreceipt検証で拒否する"
  else
    fail "preview後の同サイズartifact差し替えをreceipt検証で拒否する"
  fi

  if FLIGHT_RECORDER_TEST_EVALUATOR_CAPTURE="$capture" \
    run_cli evaluate "$episode" \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
      --artifact "$artifact" \
      --allow-artifact-content \
      --artifact-preview-token "$preview_token" \
      --json >"$output" 2>"$TEST_ROOT/evaluate-artifact.err" \
    && python3 - "$output" "$capture" "$evaluation_root" "$artifact" <<'PY'
import hashlib
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
request_text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
request = json.loads(request_text)
records = list(pathlib.Path(sys.argv[3]).glob("*.json"))
artifact = pathlib.Path(sys.argv[4])
digest = "sha256:" + hashlib.sha256(artifact.read_bytes()).hexdigest()
assert request["metadata_only"] is False
assert request["artifacts"][0]["content"] == "PRIVATE_ARTIFACT_BODY_iam116\n"
assert value["evaluation"]["artifact_hashes"] == [{
    "sha256": digest,
    "size_bytes": artifact.stat().st_size,
}]
assert len(records) == 2
assert all(
    "PRIVATE_ARTIFACT_BODY_iam116" not in record.read_text(encoding="utf-8")
    and str(artifact) not in record.read_text(encoding="utf-8")
    for record in records
)
PY
  then
    pass "許可済みartifactは本文を永続化せずhashだけをprovenanceへ残す"
  else
    fail "許可済みartifactは本文を永続化せずhashだけをprovenanceへ残す"
  fi

  before="$(find "$evaluation_root" -type f -name '*.json' -print | sort | xargs shasum -a 256)"
  status=0
  FLIGHT_RECORDER_TEST_EVALUATOR_FAIL=1 \
    run_cli evaluate "$episode" \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
      --json >"$TEST_ROOT/evaluate-fail.out" \
      2>"$TEST_ROOT/evaluate-fail.err" || status=$?
  after="$(find "$evaluation_root" -type f -name '*.json' -print | sort | xargs shasum -a 256)"
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/evaluate-fail.out" \
    && "$before" == "$after" ]] \
    && run_cli inspect "$episode" --json >"$output" \
      2>"$TEST_ROOT/evaluate-inspect.err" \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

card = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["card"]
assert card["deterministic_evidence"]
assert len(card["model_evaluations"]) == 2
assert all(item["judgment_type"] == "model" for item in card["model_evaluations"])
PY
  then
    pass "model失敗を非破壊にしCardで決定論的事実と判断を分離する"
  else
    fail "model失敗を非破壊にしCardで決定論的事実と判断を分離する"
  fi

  status=0
  FLIGHT_RECORDER_TEST_EVALUATOR_OVERSIZE=1 \
    run_cli evaluate "$episode" \
      --evaluator flight-recorder-evaluator \
      --model evaluator-test-model \
      --json >"$TEST_ROOT/evaluate-oversize.out" \
      2>"$TEST_ROOT/evaluate-oversize.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/evaluate-oversize.out" ]] \
    && grep -Eq "size limit|execution failed" \
      "$TEST_ROOT/evaluate-oversize.err"; then
    pass "evaluator stdoutをOSレベルの有限上限で打ち切る"
  else
    fail "evaluator stdoutをOSレベルの有限上限で打ち切る"
  fi
}

test_explicit_policy_scope() {
  echo "test_explicit_policy_scope:"
  local policy="$TEST_ROOT/reporting-policy.json"
  local output="$TEST_ROOT/custom-report.json"
  python3 - "$policy" <<'PY'
import json
import pathlib
import sys

policy = {
    "schema_version": 1,
    "policy_version": "reporting-v1",
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
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(policy, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
  if run_cli rebuild-relationships --policy "$policy" >/dev/null 2>&1 \
    && run_cli report --last 1h --policy "$policy" --json \
      >"$output" 2>"$TEST_ROOT/custom-report.err" \
    && python3 - "$output" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert value["policy_version"] == "reporting-v1"
assert value["cards"]
assert {
    card["policy_version"] for card in value["cards"]
} == {"reporting-v1"}
PY
  then
    pass "reportは明示policyだけを選びversioned viewsを混在させない"
  else
    fail "reportは明示policyだけを選びversioned viewsを混在させない"
  fi

  if run_cli report --last 1h --policy-version reporting-v1 --json \
    >"$TEST_ROOT/untrusted-policy.out" \
    2>"$TEST_ROOT/untrusted-policy.err"; then
    fail "derived DBだけのcustom policyをauthenticity anchorにしない"
  elif [[ ! -s "$TEST_ROOT/untrusted-policy.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/untrusted-policy.err"; then
    pass "custom policyはowner-held fileなしではfail closedする"
  else
    fail "custom policyはowner-held fileなしではfail closedする"
  fi
}

test_missing_receipt_cannot_hide_tracked_evidence() {
  echo "test_missing_receipt_cannot_hide_tracked_evidence:"
  python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
receipt = root / "index/imported-chunks.json"
value = json.loads(receipt.read_text(encoding="utf-8"))
value["chunks"] = {}
receipt.write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
for path in (root / "cache/imported").rglob("*.jsonl"):
    path.unlink()
PY
  run_cli rebuild-index >/dev/null 2>&1 || {
    fail "欠落receiptからempty derived DBを再現できる"
    return
  }
  local status=0
  run_cli report --last 1h --json \
    >"$TEST_ROOT/omission.out" 2>"$TEST_ROOT/omission.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/omission.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/omission.err"; then
    pass "tracked artifactをreceipt/cache/DBから同時削除しても隠せない"
  else
    fail "tracked artifactをreceipt/cache/DBから同時削除しても隠せない"
  fi
  run_cli sync >/dev/null 2>&1 \
    && run_cli rebuild-index >/dev/null 2>&1 || {
      fail "receipt omission fixtureから正規syncで復旧できる"
      return
    }
}

test_invalid_queries_fail_cleanly() {
  echo "test_invalid_queries_fail_cleanly:"
  local duration status=0 duration_failures=0
  for duration in 0d 1.5d 7D 999999999999w; do
    status=0
    : >"$TEST_ROOT/error.out"
    : >"$TEST_ROOT/error.err"
    run_cli report --last "$duration" --json \
      >"$TEST_ROOT/error.out" 2>"$TEST_ROOT/error.err" || status=$?
    if [[ "$status" -eq 0 || -s "$TEST_ROOT/error.out" ]] \
      || grep -q "Traceback" "$TEST_ROOT/error.err"; then
      duration_failures=$((duration_failures + 1))
    fi
  done
  if [[ "$duration_failures" -eq 0 ]]; then
    pass "invalid durationはstdoutやtracebackを出さずstrictに拒否する"
  else
    fail "invalid durationはstdoutやtracebackを出さずstrictに拒否する"
  fi

  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - <<'PY' 2>/dev/null
from reporting import _measurement
from vault import VaultError

for invalid in (True, "12", None, {}):
    try:
        _measurement([{"metrics": {"duration_ms": invalid}}], "duration_ms")
    except VaultError:
        continue
    raise AssertionError(f"accepted invalid metric: {invalid!r}")
PY
  then
    pass "non-numeric metric aggregateはVaultErrorへ閉じ込める"
  else
    fail "non-numeric metric aggregateはVaultErrorへ閉じ込める"
  fi

  status=0
  : >"$TEST_ROOT/error.out"
  : >"$TEST_ROOT/error.err"
  run_cli inspect "sha256:$(printf 'f%.0s' {1..64})" --json \
    >"$TEST_ROOT/error.out" 2>"$TEST_ROOT/error.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/error.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/error.err"; then
    pass "unknown episodeはpolicy scope内でcleanに拒否する"
  else
    fail "unknown episodeはpolicy scope内でcleanに拒否する"
  fi
}

test_tampered_projection_is_rejected() {
  echo "test_tampered_projection_is_rejected:"
  local episode status=0
  episode="$(episode_id_for 30000000-0000-4000-8000-000000000001)"
  python3 - "$STATE/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "UPDATE source_events SET model = 'forged-model' WHERE event_id = ?",
    ("30000000-0000-4000-8000-000000000001",),
)
connection.commit()
PY
  run_cli inspect "$episode" --json \
    >"$TEST_ROOT/tamper.out" 2>"$TEST_ROOT/tamper.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/tamper.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/tamper.err"; then
    pass "inspectはSQLite整合性を保つsource projection改竄も拒否する"
  else
    fail "inspectはSQLite整合性を保つsource projection改竄も拒否する"
  fi

  run_cli rebuild-index >/dev/null 2>&1 || {
    fail "source chunksからtampered indexを復旧できる"
    return
  }
  episode="$(episode_id_for 30000000-0000-4000-8000-000000000001)"
  python3 - "$STATE/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "UPDATE relationship_edges SET score = score + 1 "
    "WHERE policy_version = 'default-v1' AND decision = 'link'"
)
connection.commit()
PY
  status=0
  run_cli inspect "$episode" --json \
    >"$TEST_ROOT/graph-tamper.out" 2>"$TEST_ROOT/graph-tamper.err" || status=$?
  if [[ "$status" -ne 0 && ! -s "$TEST_ROOT/graph-tamper.out" ]] \
    && ! grep -q "Traceback" "$TEST_ROOT/graph-tamper.err"; then
    pass "inspectは内部整合性を保つrelationship graph改竄も拒否する"
  else
    fail "inspectは内部整合性を保つrelationship graph改竄も拒否する"
  fi
}

echo "=== Flight Recorder Reporting Tests ==="
if ! build_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_status_contract
test_report_grounded_cards
test_inspect_supporting_evidence
test_on_demand_model_evaluation
test_explicit_policy_scope
test_missing_receipt_cannot_hide_tracked_evidence
test_invalid_queries_fail_cleanly
test_tampered_projection_is_rejected

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
