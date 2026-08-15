#!/usr/bin/env bash
# Value Compiler v0 local derived-layer contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
STATE="$TEST_ROOT/vault"
PASS=0
FAIL=0

cleanup() {
  [[ -n "${TEST_ROOT:-}" && -d "$TEST_ROOT" ]] && rm -rf -- "$TEST_ROOT"
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
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$STATE" "$CLI" "$@"
}

append_event() {
  local event_id="$1" task_digit="$2" timestamp="$3"
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" "$event_id" "$task_digit" "$timestamp" <<'PY'
import json
import pathlib
import sys

path, event_id, task_digit, timestamp = sys.argv[1:]
task_token = (task_digit * ((24 + len(task_digit) - 1) // len(task_digit)))[:24]
event = {
    "schema_version": 3,
    "event_id": event_id,
    "recorded_at": timestamp,
    "harness": "codex",
    "source_event": "PostToolUse",
    "event_kind": "tool.completed",
    "session_id_hash": "sha256:" + task_token,
    "turn_id_hash": "sha256:" + task_token,
    "workspace_id": "sha256:" + "a" * 24,
    "model": "fixture-worker-model",
    "permission_mode": None,
    "tool": "Bash",
    "metrics": {"duration_ms": 1000 + int(task_digit, 16), "retry_count": 0},
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": "sha256:" + task_token,
        "task_source": "payload",
        "branch_or_worktree_id": "sha256:" + "b" * 24,
        "changed_file_fingerprints": ["sha256:" + task_token],
        "changed_files_state": "complete",
    },
    "operation_kind": "test",
}
with pathlib.Path(path).open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")
PY
}

episode_for_event() {
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

generate_meaning_card() {
  local episode="$1" label="$2"
  local generated_at="${3:-2026-08-09T01:02:03Z}"
  local source="$TEST_ROOT/$label-session.jsonl"
  local register="$TEST_ROOT/$label-register.json"
  local source_ref
  python3 - "$source" "$label" <<'PY'
import json
import pathlib
import sys

path, label = sys.argv[1:]
rows = [
    {"type": "event_msg", "payload": {"turn_id": label, "type": "task_started"}},
    {
        "type": "response_item",
        "payload": {
            "role": "user",
            "type": "message",
            "content": [{"type": "input_text", "text": f"RAW_VALUE_CANARY {label}"}],
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "assistant",
            "type": "message",
            "content": [{"type": "output_text", "text": f"Completed {label}."}],
        },
    },
    {"type": "event_msg", "payload": {"turn_id": label, "type": "task_complete"}},
]
pathlib.Path(path).write_text(
    "".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in rows),
    encoding="utf-8",
)
PY
  run_cli source register --adapter codex --path "$source" --json \
    >"$register" 2>/dev/null || return 1
  source_ref="$(python3 - "$register" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
)"
  FLIGHT_RECORDER_NOW="$generated_at" \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" --span-start-line 1 --span-end-line 4 \
      --evaluator flight-recorder-meaning-evaluator \
      --model "meaning-$label" --max-cost-microusd 50000 --timeout 240 \
      --json >/dev/null 2>&1
}

build_fixture() {
  local fixture_name
  fixture_name="$(basename "$STATE")"
  local remote="$TEST_ROOT/$fixture_name-remote.git"
  local recovery="$TEST_ROOT/$fixture_name-recovery.agekey"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  run_cli init --remote "$remote" --recovery-recipient \
    "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" >/dev/null 2>&1
  append_event "75000000-0000-4000-8000-000000000001" 1 "2026-08-09T00:00:01Z"
  run_cli sync >/dev/null 2>&1
  append_event "75000000-0000-4000-8000-000000000002" 2 "2026-08-09T00:00:02Z"
  run_cli sync >/dev/null 2>&1
  append_event "75000000-0000-4000-8000-000000000003" 3 "2026-08-09T00:00:03Z"
  run_cli sync >/dev/null 2>&1
  # This authenticated Episode deliberately has no Meaning Card or Receipt.
  append_event "75000000-0000-4000-8000-000000000004" 4 "2026-08-09T00:00:04Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  generate_meaning_card \
    "$(episode_for_event 75000000-0000-4000-8000-000000000001)" one
  generate_meaning_card \
    "$(episode_for_event 75000000-0000-4000-8000-000000000002)" two
  generate_meaning_card \
    "$(episode_for_event 75000000-0000-4000-8000-000000000003)" three
}

fresh_blocker_fixture() {
  STATE="$TEST_ROOT/blocker-$1-vault"
  build_fixture
}

test_versioned_cards_are_grounded_bounded_and_idempotent() {
  echo "test_versioned_cards_are_grounded_bounded_and_idempotent:"
  local first="$TEST_ROOT/value-first.json"
  local second="$TEST_ROOT/value-second.json"
  local third="$TEST_ROOT/value-third.json"
  local inspect_json="$TEST_ROOT/value-inspect.json"
  local inspect_human="$TEST_ROOT/value-inspect.txt"
  local capture="$TEST_ROOT/value-requests.jsonl"
  local counter="$TEST_ROOT/value-evaluator-count"
  local err="$TEST_ROOT/value.err"
  local episode
  episode="$(episode_for_event 75000000-0000-4000-8000-000000000001)"

  if ! run_cli value --help >/dev/null 2>"$err"; then
    cat "$err" >&2
    fail "value compile CLIが利用できる"
    return
  fi
  if run_cli value compile --max-episodes 1 --max-cost-microusd 6000 \
      --json >/dev/null 2>"$err"; then
    fail "明示evaluator/modelなしのprovider実行を拒否する"
    return
  fi
  if FLIGHT_RECORDER_TEST_VALUE_CAPTURE="$capture" \
      FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      FLIGHT_RECORDER_TEST_VALUE_COST=6000 \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-a \
        --max-episodes 2 --max-cost-microusd 12000 --json \
        >"$first" 2>"$err" \
    && FLIGHT_RECORDER_TEST_VALUE_CAPTURE="$capture" \
      FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      FLIGHT_RECORDER_TEST_VALUE_COST=6000 \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-a \
        --max-episodes 2 --max-cost-microusd 12000 --json \
        >"$second" 2>>"$err" \
    && FLIGHT_RECORDER_TEST_VALUE_CAPTURE="$capture" \
      FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      FLIGHT_RECORDER_TEST_VALUE_COST=6000 \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-a \
        --max-episodes 2 --max-cost-microusd 12000 --json \
        >"$third" 2>>"$err" \
    && run_cli inspect "$episode" --json >"$inspect_json" 2>>"$err" \
    && run_cli inspect "$episode" >"$inspect_human" 2>>"$err" \
    && python3 - \
      "$first" "$second" "$third" "$capture" "$counter" \
      "$inspect_json" "$inspect_human" "$STATE" "$episode" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

(
    first_path, second_path, third_path, capture_path, counter_path,
    inspect_path, human_path, state_path, episode_id,
) = sys.argv[1:]
first = json.loads(pathlib.Path(first_path).read_text())
second = json.loads(pathlib.Path(second_path).read_text())
third = json.loads(pathlib.Path(third_path).read_text())
requests = [json.loads(line) for line in pathlib.Path(capture_path).read_text().splitlines() if line]
assert first["schema_version"] == 1 and first["command"] == "value compile"
assert first["candidate_count"] == 3
assert first["compiled_count"] == 2
assert first["deferred_count"] == 1
assert first["measured_cost_microusd"] == 12000
assert second["compiled_count"] == 1
assert third["compiled_count"] == 0
assert third["reused_count"] == 3
assert int(pathlib.Path(counter_path).read_text()) == 3
assert len(requests) == 3
for request in requests:
    assert request["schema_version"] == 1
    assert request["model"] == "value-model-a"
    assert request["packet"]["contract_version"] == "value-compiler-packet-v1"
    evidence = request["packet"]["evidence"]
    assert evidence and all(
        set(item) >= {"evidence_id", "source", "field"} for item in evidence
    )
    fields = {item["field"] for item in evidence}
    assert "meaning.outcome" in fields
    assert "meaning.verification" in fields
    assert "meaning.reusable_learning" in fields
    serialized = json.dumps(request, sort_keys=True)
    assert "RAW_VALUE_CANARY" not in serialized
    assert "session.jsonl" not in serialized
    assert "/Users/" not in serialized

directory = pathlib.Path(state_path) / "value-primitive-cards"
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
paths = sorted(directory.glob("*.json"))
assert len(paths) == 3
assert int(pathlib.Path(counter_path).read_text()) == len(paths)
axes = {
    "goal_achievement", "deliverable_quality", "risk_reduction", "learning",
    "reuse_potential", "decision_leverage", "attention_saved", "rework",
}
selected = None
for path in paths:
    assert re.fullmatch(r"[0-9a-f]{64}\.json", path.name)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    card = json.loads(path.read_text())
    assert card["schema_version"] == 1
    assert card["contract_version"] == "value-primitive-card-v1"
    assert path.stem == card["value_primitive_card_id"].removeprefix("sha256:")
    without_id = {key: value for key, value in card.items() if key != "value_primitive_card_id"}
    canonical = json.dumps(without_id, sort_keys=True, separators=(",", ":")).encode()
    assert card["value_primitive_card_id"] == "sha256:" + hashlib.sha256(canonical).hexdigest()
    assert set(card["primitives"]) == axes
    assert isinstance(card["observations"], dict)
    assert "score" not in card and "personal_value" not in card
    input_ids = set(card["provenance"]["input_evidence_ids"])
    assert input_ids
    for name, primitive in card["primitives"].items():
        assert primitive["state"] in {"positive", "negative", "mixed", "unknown"}
        assert primitive["basis"] in {"observed", "inferred", "unknown"}
        assert primitive["confidence"] in {"low", "medium", "high"}
        assert 0 < len(primitive["summary"]) <= 512
        assert set(primitive["evidence_references"]) <= input_ids
        if primitive["state"] == "unknown":
            assert primitive["basis"] == "unknown"
            assert primitive["evidence_references"] == []
        else:
            assert primitive["basis"] == "inferred"
            assert primitive["evidence_references"]
    assert card["primitives"]["learning"]["evidence_references"]
    assert card["primitives"]["goal_achievement"]["evidence_references"]
    assert card["primitives"]["deliverable_quality"]["evidence_references"]
    for name in {"risk_reduction", "reuse_potential", "decision_leverage", "attention_saved", "rework"}:
        assert card["primitives"][name]["state"] == "unknown"
    assert "RAW_VALUE_CANARY" not in path.read_text()
    if card["episode_id"] == episode_id:
        selected = card
assert selected is not None
assert "/value-primitive-cards/\n" in (pathlib.Path(state_path) / ".gitignore").read_text()

inspection = json.loads(pathlib.Path(inspect_path).read_text())
human = pathlib.Path(human_path).read_text()
assert inspection["schema_version"] == 5
cards = inspection["value_primitive_cards"]
assert len(cards) == 1 and cards[0] == selected
assert "goal_achievement" in human
assert "unknown" in human
assert "microusd" in human.lower() or "cost" in human.lower()
assert inspection["card"]["measured_duration_ms"]["value"] >= 0
assert "measured_cost_usd" in inspection["card"]
PY
  then
    pass "8軸を根拠付き・content-addressed・bounded batchで保存し再利用する"
  else
    cat "$err" >&2
    fail "8軸を根拠付き・content-addressed・bounded batchで保存し再利用する"
  fi
}

test_wrong_axis_reference_fails_closed_without_storing_a_card() {
  echo "test_wrong_axis_reference_fails_closed_without_storing_a_card:"
  local event="75000000-0000-4000-8000-000000000005"
  local episode before after err="$TEST_ROOT/value-outside.err"
  append_event "$event" 5 "2026-08-09T00:00:05Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" outside || {
    fail "根拠外参照fixtureを作成できる"
    return
  }
  before="$(find "$STATE/value-primitive-cards" -type f -name '*.json' | wc -l | tr -d ' ')"
  if FLIGHT_RECORDER_TEST_VALUE_WRONG_AXIS_REFERENCE=1 \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-a \
        --max-episodes 1 --max-cost-microusd 6000 --json \
        >/dev/null 2>"$err"; then
    fail "別軸のevidence referenceを拒否する"
    return
  fi
  after="$(find "$STATE/value-primitive-cards" -type f -name '*.json' | wc -l | tr -d ' ')"
  if [[ "$before" == "$after" ]] && grep -qi "evidence" "$err"; then
    pass "軸ごとの許容根拠違反はfail closedでカードを残さない"
  else
    cat "$err" >&2
    fail "軸ごとの許容根拠違反はfail closedでカードを残さない"
  fi
}

test_forget_and_purge_cover_value_primitive_cards() {
  echo "test_forget_and_purge_cover_value_primitive_cards:"
  local forgotten purged unrelated preview="$TEST_ROOT/value-purge-preview.json"
  local err="$TEST_ROOT/value-retention.err"
  forgotten="$(episode_for_event 75000000-0000-4000-8000-000000000001)"
  purged="$(episode_for_event 75000000-0000-4000-8000-000000000003)"
  unrelated="$(episode_for_event 75000000-0000-4000-8000-000000000002)"
  local before_forget="$TEST_ROOT/value-before-forget.txt"
  local after_forget="$TEST_ROOT/value-after-forget.txt"
  find "$STATE/value-primitive-cards" -type f -name '*.json' -print | sort >"$before_forget"
  if run_cli purge "$purged" --json >"$preview" 2>"$err" \
    && run_cli forget "$forgotten" --json >/dev/null 2>>"$err" \
    && find "$STATE/value-primitive-cards" -type f -name '*.json' -print | sort >"$after_forget" \
    && cmp "$before_forget" "$after_forget" \
    && ! run_cli inspect "$forgotten" --json >/dev/null 2>>"$err" \
    && run_cli purge "$purged" --apply --json >/dev/null 2>>"$err" \
    && python3 - "$preview" "$STATE" "$forgotten" "$purged" "$unrelated" <<'PY'
import json
import pathlib
import sys

preview_path, state_path, forgotten, purged, unrelated = sys.argv[1:]
preview = json.loads(pathlib.Path(preview_path).read_text())
assert preview["value_primitive_card_record_count"] == 1
cards = []
directory = pathlib.Path(state_path) / "value-primitive-cards"
if directory.is_dir():
    cards = [json.loads(path.read_text()) for path in directory.glob("*.json")]
episode_ids = {card["episode_id"] for card in cards}
# forget is a visibility marker; physical deletion is purge-only.
assert forgotten in episode_ids
assert purged not in episode_ids
assert unrelated in episode_ids
PY
  then
    pass "forgetは非表示に留め、purgeだけが対象カードを物理削除する"
  else
    cat "$err" >&2
    fail "forgetは非表示に留め、purgeだけが対象カードを物理削除する"
  fi
}

test_concurrent_compile_reuses_reservation_without_blocking_inspect() {
  echo "test_concurrent_compile_reuses_reservation_without_blocking_inspect:"
  local event="75000000-0000-4000-8000-000000000006"
  local episode started="$TEST_ROOT/value-concurrent-started"
  local release="$TEST_ROOT/value-concurrent-release"
  local counter="$TEST_ROOT/value-concurrent-count"
  local first="$TEST_ROOT/value-concurrent-first.json"
  local second="$TEST_ROOT/value-concurrent-second.json"
  local inspected="$TEST_ROOT/value-concurrent-inspect.json"
  local first_err="$TEST_ROOT/value-concurrent-first.err"
  local second_err="$TEST_ROOT/value-concurrent-second.err"
  local inspect_err="$TEST_ROOT/value-concurrent-inspect.err"
  local first_pid second_pid inspect_pid index inspect_finished=0

  # Prewarm every current candidate for this model, then add exactly one new
  # fingerprint so both concurrent runs contend for the same provider work.
  if ! run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-concurrent \
      --max-episodes 100 --max-cost-microusd 600000 --json \
      >/dev/null 2>"$first_err"; then
    cat "$first_err" >&2
    fail "concurrency fixtureをprewarmできる"
    return
  fi
  append_event "$event" 6 "2026-08-09T00:00:06Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  if ! generate_meaning_card "$episode" concurrent; then
    fail "concurrency候補を作成できる"
    return
  fi

  FLIGHT_RECORDER_TEST_VALUE_STARTED="$started" \
    FLIGHT_RECORDER_TEST_VALUE_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-concurrent \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >"$first" 2>"$first_err" &
  first_pid=$!
  for index in $(seq 1 50); do
    [[ -e "$started" ]] && break
    sleep 0.05
  done
  if [[ ! -e "$started" ]]; then
    touch "$release"
    wait "$first_pid" 2>/dev/null
    fail "blocking providerが開始した"
    return
  fi

  FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-concurrent \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >"$second" 2>"$second_err" &
  second_pid=$!
  run_cli inspect "$episode" --json >"$inspected" 2>"$inspect_err" &
  inspect_pid=$!
  for index in $(seq 1 60); do
    if ! kill -0 "$inspect_pid" 2>/dev/null; then
      wait "$inspect_pid"
      inspect_finished=1
      break
    fi
    sleep 0.05
  done

  # Always release the fake provider before assertions so Red cannot strand
  # either compile process.
  touch "$release"
  wait "$first_pid"
  local first_status=$?
  wait "$second_pid"
  local second_status=$?
  if [[ "$inspect_finished" -eq 0 ]]; then
    wait "$inspect_pid"
  fi
  if [[ "$first_status" -eq 0 && "$second_status" -eq 0 \
      && "$inspect_finished" -eq 1 ]] \
    && python3 - "$first" "$second" "$inspected" "$counter" "$episode" <<'PY'
import json
import pathlib
import sys

first, second, inspected, counter, episode = sys.argv[1:]
outputs = [json.loads(pathlib.Path(path).read_text()) for path in (first, second)]
inspection = json.loads(pathlib.Path(inspected).read_text())
assert int(pathlib.Path(counter).read_text()) == 1
assert sum(item["compiled_count"] for item in outputs) == 1
assert sum(item["reused_count"] for item in outputs) >= 1
assert inspection["schema_version"] == 5
assert inspection["card"]["episode_id"] == episode
PY
  then
    pass "同一fingerprintはprovider 1回でreuseし、provider待機中もinspectできる"
  else
    cat "$first_err" "$second_err" "$inspect_err" >&2
    fail "同一fingerprintはprovider 1回でreuseし、provider待機中もinspectできる"
  fi
}

test_orphaned_valid_response_is_prepared_and_finalized() {
  echo "test_orphaned_valid_response_is_prepared_and_finalized:"
  local event="75000000-0000-4000-8000-000000000007"
  local episode started="$TEST_ROOT/value-pending-started"
  local release="$TEST_ROOT/value-pending-release"
  local counter="$TEST_ROOT/value-pending-count"
  local retry="$TEST_ROOT/value-pending-retry.json"
  local first_err="$TEST_ROOT/value-pending-first.err"
  local retry_err="$TEST_ROOT/value-pending-retry.err"
  local process index

  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-pending \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$first_err" || {
      fail "pending fixtureをprewarmできる"
      return
    }
  append_event "$event" 7 "2026-08-09T00:00:07Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" pending || {
    fail "pending candidateを作成できる"
    return
  }

  FLIGHT_RECORDER_TEST_VALUE_STARTED="$started" \
    FLIGHT_RECORDER_TEST_VALUE_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-pending \
      --max-episodes 1 --max-cost-microusd 6000 --timeout 60 --json \
      >/dev/null 2>"$first_err" &
  process=$!
  for index in $(seq 1 80); do
    [[ -e "$started" && -s "$counter" ]] && break
    sleep 0.05
  done
  kill -TERM "$process" 2>/dev/null
  touch "$release"
  wait "$process" 2>/dev/null
  for index in $(seq 1 80); do
    if find "$STATE/value-compiler/prepared" -type f -name '*.json' \
        -print -quit 2>/dev/null | grep -q .; then
      break
    fi
    sleep 0.05
  done

  if FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-pending \
        --max-episodes 1 --max-cost-microusd 6000 --json \
        >"$retry" 2>"$retry_err" \
    && python3 - "$counter" "$retry" "$STATE" "$episode" "value-model-pending" <<'PY'
import json
import pathlib
import stat
import sys

counter, output, state, episode, model = sys.argv[1:]
assert int(pathlib.Path(counter).read_text()) == 1
result = json.loads(pathlib.Path(output).read_text())
assert result["compiled_count"] == 1
root = pathlib.Path(state)
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert any(
    card["episode_id"] == episode
    and card["provenance"]["evaluator_model"] == model
    for card in cards
)
directory = root / "value-compiler"
attempts_path = directory / "attempts.json"
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert stat.S_IMODE(attempts_path.stat().st_mode) == 0o600
ledger = json.loads(attempts_path.read_text())
assert set(ledger) == {"schema_version", "attempts"}
assert ledger["schema_version"] == 1
assert isinstance(ledger["attempts"], list) and len(ledger["attempts"]) <= 1000
assert not any(item.get("episode_id") == episode for item in ledger["attempts"])
prepared = root / "value-compiler" / "prepared"
assert not list(prepared.glob("*.json"))
PY
  then
    pass "orphaned valid responseをprepared回収し再課金なしでfinalizeする"
  else
    cat "$first_err" "$retry_err" >&2
    fail "orphaned valid responseをprepared回収し再課金なしでfinalizeする"
  fi
}

test_oversized_response_leaves_durable_failure_without_recharge() {
  echo "test_oversized_response_leaves_durable_failure_without_recharge:"
  local event="75000000-0000-4000-8000-000000000008"
  local episode counter="$TEST_ROOT/value-oversized-count"
  local retry="$TEST_ROOT/value-oversized-retry.json"
  local first_err="$TEST_ROOT/value-oversized-first.err"
  local retry_err="$TEST_ROOT/value-oversized-retry.err"

  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-oversized \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$first_err" || {
      fail "oversized fixtureをprewarmできる"
      return
    }
  append_event "$event" 8 "2026-08-09T00:00:08Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" oversized || {
    fail "oversized candidateを作成できる"
    return
  }

  if FLIGHT_RECORDER_TEST_VALUE_OVERSIZED=1 \
      FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-oversized \
        --max-episodes 1 --max-cost-microusd 6000 --json \
        >/dev/null 2>"$first_err"; then
    fail "oversized provider responseを拒否する"
    return
  fi
  if FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-oversized \
        --max-episodes 1 --max-cost-microusd 6000 --json \
        >"$retry" 2>"$retry_err" \
    && python3 - "$counter" "$retry" "$STATE" "$episode" "value-model-oversized" <<'PY'
import json
import pathlib
import sys

counter, output, state, episode, model = sys.argv[1:]
assert int(pathlib.Path(counter).read_text()) == 1
result = json.loads(pathlib.Path(output).read_text())
assert result.get("attempt_skip_count") == 1 or result["deferred_count"] >= 1
root = pathlib.Path(state)
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert not any(
    card["episode_id"] == episode
    and card["provenance"]["evaluator_model"] == model
    for card in cards
)
ledger = json.loads((root / "value-compiler" / "attempts.json").read_text())
assert any(
    item.get("episode_id") == episode and item.get("state") == "failed"
    for item in ledger["attempts"]
)
PY
  then
    pass "oversized失敗予約は同一fingerprintの自動再課金を防ぐ"
  else
    cat "$first_err" "$retry_err" >&2
    fail "oversized失敗予約は同一fingerprintの自動再課金を防ぐ"
  fi
}

test_directional_grounding_rejects_positive_from_unknown_outcome() {
  echo "test_directional_grounding_rejects_positive_from_unknown_outcome:"
  local event="75000000-0000-4000-8000-00000000000a"
  local episode err="$TEST_ROOT/value-directional.err"
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-directional \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "directional fixtureをprewarmできる"
      return
    }
  append_event "$event" a "2026-08-09T00:00:10Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  FLIGHT_RECORDER_TEST_MEANING_OUTCOME=unknown \
    generate_meaning_card "$episode" directional || {
      fail "unknown outcome candidateを作成できる"
      return
    }
  if FLIGHT_RECORDER_TEST_VALUE_FORCE_UNKNOWN_GOAL_POSITIVE=1 \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-directional \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >/dev/null 2>"$err"; then
    fail "unknown outcomeからpositive/high goalを導出しない"
    return
  fi
  if python3 - "$STATE" "$episode" "value-model-directional" <<'PY'
import json
import pathlib
import sys

state, episode, model = sys.argv[1:]
root = pathlib.Path(state)
cards = [json.loads(path.read_text()) for path in (root / "value-primitive-cards").glob("*.json")]
assert not any(
    item["episode_id"] == episode
    and item["provenance"]["evaluator_model"] == model
    for item in cards
)
ledger = json.loads((root / "value-compiler" / "attempts.json").read_text())
assert any(
    item["episode_id"] == episode and item["state"] == "failed"
    for item in ledger["attempts"]
)
PY
  then
    pass "unknown outcomeはpositive goalの方向根拠にならない"
  else
    cat "$err" >&2
    fail "unknown outcomeはpositive goalの方向根拠にならない"
  fi
}

test_malformed_evaluator_fails_cleanly_and_closes_attempt() {
  echo "test_malformed_evaluator_fails_cleanly_and_closes_attempt:"
  local event="75000000-0000-4000-8000-00000000000b"
  local episode err="$TEST_ROOT/value-malformed.err"
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-malformed \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "malformed fixtureをprewarmできる"
      return
    }
  append_event "$event" b "2026-08-09T00:00:11Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" malformed || {
    fail "malformed candidateを作成できる"
    return
  }
  if FLIGHT_RECORDER_TEST_VALUE_MALFORMED_STATE=1 \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator --model value-model-malformed \
        --max-episodes 1 --max-cost-microusd 6000 --json \
        >/dev/null 2>"$err"; then
    fail "unhashable stateを拒否する"
    return
  fi
  if ! grep -Eq "Traceback|TypeError" "$err" \
    && grep -qi "value evaluator\|invalid" "$err" \
    && python3 - "$STATE" "$episode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
ledger = json.loads((root / "value-compiler" / "attempts.json").read_text())
matches = [item for item in ledger["attempts"] if item["episode_id"] == episode]
assert matches and all(item["state"] == "failed" for item in matches)
PY
  then
    pass "malformed responseはVaultError化しpendingをfailedへ閉じる"
  else
    cat "$err" >&2
    fail "malformed responseはVaultError化しpendingをfailedへ閉じる"
  fi
}

test_rehashed_observation_tamper_fails_current_binding() {
  echo "test_rehashed_observation_tamper_fails_current_binding:"
  local episode err="$TEST_ROOT/value-tamper.err"
  episode="$(episode_for_event 75000000-0000-4000-8000-000000000002)"
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-tamper \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "tamper fixtureをprewarmできる"
      return
    }
  if ! python3 - "$STATE" "$episode" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
directory = root / "value-primitive-cards"
selected = None
for path in directory.glob("*.json"):
    card = json.loads(path.read_text())
    if (
        card["episode_id"] == episode
        and card["provenance"]["evaluator_model"] == "value-model-tamper"
    ):
        selected = (path, card)
        break
assert selected is not None
path, card = selected
card["observations"]["measured_duration_ms"]["value"] = -1
without_id = {
    key: value for key, value in card.items()
    if key != "value_primitive_card_id"
}
canonical = json.dumps(without_id, sort_keys=True, separators=(",", ":")).encode()
card["value_primitive_card_id"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
target = directory / f"{card['value_primitive_card_id'].removeprefix('sha256:')}.json"
target.write_text(json.dumps(card, sort_keys=True, separators=(",", ":")) + "\n")
target.chmod(0o600)
path.unlink()
PY
  then
    fail "tamper対象カードを改変できる"
    return
  fi
  if run_cli inspect "$episode" --json >/dev/null 2>"$err"; then
    fail "再hash済みobservation改変をcurrent dataとして受理しない"
  elif grep -q "Traceback" "$err"; then
    cat "$err" >&2
    fail "tamper拒否を有限エラーで返す"
  else
    pass "再hash済みobservation改変もcurrent bindingで拒否する"
  fi
}

test_anchor_first_materializes_only_semantic_candidates() {
  echo "test_anchor_first_materializes_only_semantic_candidates:"
  local digit suffix
  fresh_blocker_fixture anchor-first || {
    fail "anchor-first fixtureを構築できる"
    return
  }
  for suffix in 1 2 3 4 5; do
    digit="e$suffix"
    append_event \
      "75000000-0000-4000-8000-00000000010$suffix" \
      "$digit" "2026-08-09T00:01:0${suffix}Z"
  done
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" <<'PY'
import pathlib
import sys

import value_compiler
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
original = value_compiler._episode_card
calls = 0


def counted(*args, **kwargs):
    global calls
    calls += 1
    return original(*args, **kwargs)


value_compiler._episode_card = counted
with vault_lock(root):
    packets = value_compiler._authenticated_packets(
        root, "default-v1", None
    )
assert len(packets) >= 3
assert calls == len(packets), (calls, len(packets))
PY
  then
    pass "Episode card materializationはanchor候補数に比例する"
  else
    fail "Episode card materializationはanchor候補数に比例する"
  fi
}

test_completed_attempts_are_cleaned_before_capacity_check() {
  echo "test_completed_attempts_are_cleaned_before_capacity_check:"
  local event="75000000-0000-4000-8000-00000000000c"
  local episode err="$TEST_ROOT/value-cleanup.err"
  fresh_blocker_fixture cleanup || {
    fail "completed cleanup fixtureを構築できる"
    return
  }
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-cleanup \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "completed cleanup fixtureをprewarmできる"
      return
    }
  append_event "$event" c "2026-08-09T00:00:12Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" cleanup || {
    fail "completed cleanup candidateを作成できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" "$episode" <<'PY'
import json
import pathlib
import sys

import value_compiler

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
value_compiler.MAX_ATTEMPTS = 2
result = value_compiler.compile_values(
    root,
    "flight-recorder-value-evaluator",
    "value-model-cleanup",
    1,
    6000,
    60,
)
assert result["compiled_count"] == 1
ledger = json.loads((root / "value-compiler" / "attempts.json").read_text())
assert len(ledger["attempts"]) <= 2
assert all(item["state"] != "completed" for item in ledger["attempts"])
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert any(
    item["episode_id"] == episode
    and item["provenance"]["evaluator_model"] == "value-model-cleanup"
    for item in cards
)
PY
  then
    pass "completed attemptsを掃除し容量を新規candidateへ返す"
  else
    cat "$err" >&2
    fail "completed attemptsを掃除し容量を新規candidateへ返す"
  fi
}

test_card_storage_ignores_only_strict_atomic_temps() {
  echo "test_card_storage_ignores_only_strict_atomic_temps:"
  local episode err="$TEST_ROOT/value-temp.err"
  fresh_blocker_fixture temp || {
    fail "atomic temp fixtureを構築できる"
    return
  }
  episode="$(episode_for_event 75000000-0000-4000-8000-000000000002)"
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-temp \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "atomic temp fixtureをprewarmできる"
      return
    }
  if python3 - "$STATE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "value-primitive-cards" / ("." + "a" * 64 + ".json.fixture")
path.write_text("incomplete atomic replacement\n")
path.chmod(0o600)
PY
    run_cli inspect "$episode" --json >/dev/null 2>"$err"
  then
    pass "owner-only regular strict tempだけを無視する"
  else
    cat "$err" >&2
    fail "owner-only regular strict tempだけを無視する"
    return
  fi

  if python3 - "$STATE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
directory = root / "value-primitive-cards"
for path in directory.glob(".*.json.fixture"):
    path.unlink()
(directory / ".arbitrary-hidden").write_text("unsafe\n")
PY
    run_cli inspect "$episode" --json >/dev/null 2>"$err"
  then
    fail "任意hidden entryを無視しない"
  else
    pass "任意hidden entryはfail closedする"
  fi

  if python3 - "$STATE" "$TEST_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
outside = pathlib.Path(sys.argv[2]) / "outside-temp"
outside.write_text("outside\n")
directory = root / "value-primitive-cards"
(directory / ".arbitrary-hidden").unlink()
temp = directory / ("." + "b" * 64 + ".json.fixture")
temp.symlink_to(outside)
PY
    run_cli inspect "$episode" --json >/dev/null 2>"$err"
  then
    fail "strict名でもsymlink tempを無視しない"
  else
    pass "symlink tempはfail closedする"
  fi

  if python3 - "$STATE" <<'PY'
import os
import pathlib
import sys

directory = pathlib.Path(sys.argv[1]) / "value-primitive-cards"
for path in directory.glob(".*.json.fixture"):
    path.unlink()
card = next(directory.glob("[0-9a-f]*.json"))
temp = directory / ("." + "c" * 64 + ".json.fixture")
os.link(card, temp)
PY
    run_cli inspect "$episode" --json >/dev/null 2>"$err"
  then
    fail "strict名でもhardlink tempを無視しない"
  else
    pass "hardlink tempはfail closedする"
  fi

  if python3 - "$STATE" <<'PY'
import pathlib
import sys

directory = pathlib.Path(sys.argv[1]) / "value-primitive-cards"
for path in directory.glob(".*.json.fixture"):
    path.unlink()
temp = directory / ("." + "d" * 64 + ".json.fixture")
temp.write_text("unsafe mode\n")
temp.chmod(0o644)
PY
    run_cli inspect "$episode" --json >/dev/null 2>"$err"
  then
    fail "strict名でもunsafe mode tempを無視しない"
  else
    pass "unsafe mode tempはfail closedする"
  fi
}

test_valid_provider_result_is_prepared_before_final_auth() {
  echo "test_valid_provider_result_is_prepared_before_final_auth:"
  local event="75000000-0000-4000-8000-00000000000d"
  local episode err="$TEST_ROOT/value-prepared.err"
  fresh_blocker_fixture prepared || {
    fail "prepared fixtureを構築できる"
    return
  }
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-prepared \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "prepared fixtureをprewarmできる"
      return
    }
  append_event "$event" d "2026-08-09T00:00:13Z"
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  episode="$(episode_for_event "$event")"
  generate_meaning_card "$episode" prepared || {
    fail "prepared candidateを作成できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$TEST_ROOT/value-prepared-count" \
    python3 - "$STATE" "$episode" "$TEST_ROOT/value-prepared-count" <<'PY'
import json
import pathlib
import stat
import sys

import value_compiler
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
counter = pathlib.Path(sys.argv[3])
original = value_compiler._authenticated_packets
injected = False


def conflict_after_provider(*args, **kwargs):
    global injected
    if counter.exists() and int(counter.read_text()) >= 1 and not injected:
        injected = True
        raise VaultError("fixture final authentication conflict")
    return original(*args, **kwargs)


value_compiler._authenticated_packets = conflict_after_provider
try:
    value_compiler.compile_values(
        root,
        "flight-recorder-value-evaluator",
        "value-model-prepared",
        1,
        6000,
        60,
    )
except VaultError:
    pass
else:
    raise AssertionError("final authentication conflict was not injected")
finally:
    value_compiler._authenticated_packets = original

prepared = root / "value-compiler" / "prepared"
assert stat.S_IMODE(prepared.stat().st_mode) == 0o700
paths = list(prepared.glob("*.json"))
assert len(paths) == 1
assert stat.S_IMODE(paths[0].stat().st_mode) == 0o600
assert paths[0].stat().st_size <= 64 * 1024
record = json.loads(paths[0].read_text())
assert record["episode_id"] == episode
assert record["evaluator_model"] == "value-model-prepared"

result = value_compiler.compile_values(
    root,
    "flight-recorder-value-evaluator",
    "value-model-prepared",
    1,
    6000,
    60,
)
assert int(counter.read_text()) == 1
assert result["compiled_count"] == 1
assert not list(prepared.glob("*.json"))
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert any(
    item["episode_id"] == episode
    and item["provenance"]["evaluator_model"] == "value-model-prepared"
    for item in cards
)
PY
  then
    pass "valid responseをprepared保存し再課金なしでfinalizeする"
  else
    cat "$err" >&2
    fail "valid responseをprepared保存し再課金なしでfinalizeする"
  fi
}

test_reauthentication_scans_anchors_once_per_batch() {
  echo "test_reauthentication_scans_anchors_once_per_batch:"
  fresh_blocker_fixture cycle6-performance || {
    fail "cycle6 performance fixtureを構築できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" <<'PY'
import pathlib
import sys

import value_compiler

root = pathlib.Path(sys.argv[1])
counts = {"meaning": 0, "receipt": 0, "episode": 0, "edges": 0}
original_meaning = value_compiler.stored_meaning_cards
original_receipts = value_compiler._stored_receipts
original_episode = value_compiler._episode_card
original_edges = value_compiler._target_episode_edges


def meanings(*args, **kwargs):
    counts["meaning"] += 1
    return original_meaning(*args, **kwargs)


def receipts(*args, **kwargs):
    counts["receipt"] += 1
    return original_receipts(*args, **kwargs)


def episode(*args, **kwargs):
    counts["episode"] += 1
    return original_episode(*args, **kwargs)


def edges(*args, **kwargs):
    counts["edges"] += 1
    return original_edges(*args, **kwargs)


value_compiler.stored_meaning_cards = meanings
value_compiler._stored_receipts = receipts
value_compiler._episode_card = episode
value_compiler._target_episode_edges = edges
result = value_compiler.compile_values(
    root,
    "flight-recorder-value-evaluator",
    "value-model-cycle6-performance",
    3,
    18000,
    60,
)
assert result["candidate_count"] == 3
assert result["compiled_count"] == 3
assert counts["meaning"] == 1, counts
assert counts["receipt"] == 1, counts
assert counts["episode"] <= 2 * result["candidate_count"], counts
assert counts["edges"] <= 2 * result["candidate_count"], counts
PY
  then
    pass "再認証はanchor全scanを繰返さず対象candidateだけ読む"
  else
    fail "再認証はanchor全scanを繰返さず対象candidateだけ読む"
  fi
}

test_ten_candidate_batch_authenticates_graph_constant_times() {
  echo "test_ten_candidate_batch_authenticates_graph_constant_times:"
  local metrics="$TEST_ROOT/value-pilot-auth-metrics.json"
  local event digit label second
  fresh_blocker_fixture pilot-graph-auth || {
    fail "pilot graph auth fixtureを構築できる"
    return
  }
  generate_meaning_card \
    "$(episode_for_event 75000000-0000-4000-8000-000000000004)" \
    pilot-four || {
      fail "pilot 4番目candidateを作成できる"
      return
    }
  for digit in 5 6 7 8 9 a; do
    case "$digit" in
      a) second=10 ;;
      *) second="0$digit" ;;
    esac
    event="75000000-0000-4000-8000-00000000000$digit"
    append_event "$event" "$digit" "2026-08-09T00:00:${second}Z"
  done
  run_cli sync >/dev/null 2>&1
  run_cli rebuild-index >/dev/null 2>&1
  for digit in 5 6 7 8 9 a; do
    event="75000000-0000-4000-8000-00000000000$digit"
    label="pilot-$digit"
    generate_meaning_card "$(episode_for_event "$event")" "$label" || {
      fail "pilot $digit candidateを作成できる"
      return
    }
  done

  if ! PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" "$metrics" <<'PY'
import fcntl
import json
import os
import pathlib
import subprocess
import sys

import reporting
import value_compiler
from vault import VaultError

root = pathlib.Path(sys.argv[1])
metrics_path = pathlib.Path(sys.argv[2])
original_auth = value_compiler._authenticated_query_locked
original_reporting_auth = reporting._authenticated_query_locked
original_invoke = value_compiler._invoke
auth_calls = 0
provider_calls = 0
lock_failures = 0


def counted_auth(*args, **kwargs):
    global auth_calls
    auth_calls += 1
    return original_auth(*args, **kwargs)


lock_probe = """
import fcntl
import os
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
path = root.parent / f'.{root.name}.lock'
descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
finally:
    os.close(descriptor)
"""


def unlocked_invoke(*args, **kwargs):
    global provider_calls, lock_failures
    provider_calls += 1
    probe = subprocess.run(
        [sys.executable, "-c", lock_probe, str(root)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=3,
        check=False,
    )
    if probe.returncode != 0:
        lock_failures += 1
    return original_invoke(*args, **kwargs)


value_compiler._authenticated_query_locked = counted_auth
reporting._authenticated_query_locked = counted_auth
value_compiler._invoke = unlocked_invoke
try:
    success = value_compiler.compile_values(
        root,
        "flight-recorder-value-evaluator",
        "value-model-pilot-success",
        10,
        60000,
        60,
    )
finally:
    value_compiler._authenticated_query_locked = original_auth
    reporting._authenticated_query_locked = original_reporting_auth
success_auth_calls = auth_calls
success_provider_calls = provider_calls
success_lock_failures = lock_failures


auth_calls = 0


def reject_final_auth(*args, **kwargs):
    global auth_calls
    auth_calls += 1
    if auth_calls >= 2:
        raise VaultError("fixture graph changed before final authentication")
    return original_auth(*args, **kwargs)


value_compiler._authenticated_query_locked = reject_final_auth
reporting._authenticated_query_locked = reject_final_auth
try:
    value_compiler.compile_values(
        root,
        "flight-recorder-value-evaluator",
        "value-model-pilot-prepared",
        10,
        60000,
        60,
    )
except VaultError:
    final_auth_failed = True
else:
    final_auth_failed = False
finally:
    value_compiler._authenticated_query_locked = original_auth
    reporting._authenticated_query_locked = original_reporting_auth
failure_auth_calls = auth_calls
failure_provider_calls = provider_calls - success_provider_calls
prepared_directory = root / "value-compiler" / "prepared"
prepared_after_failure = len(list(prepared_directory.glob("*.json")))
cards_after_failure = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
    if json.loads(path.read_text())["provenance"]["evaluator_model"]
    == "value-model-pilot-prepared"
]


auth_calls = 0
provider_before_retry = provider_calls
value_compiler._authenticated_query_locked = counted_auth
reporting._authenticated_query_locked = counted_auth
try:
    retry = value_compiler.compile_values(
        root,
        "flight-recorder-value-evaluator",
        "value-model-pilot-prepared",
        10,
        60000,
        60,
    )
finally:
    value_compiler._authenticated_query_locked = original_auth
    reporting._authenticated_query_locked = original_reporting_auth
    value_compiler._invoke = original_invoke

metrics = {
    "success": {
        "candidate_count": success["candidate_count"],
        "compiled_count": success["compiled_count"],
        "auth_calls": success_auth_calls,
        "provider_calls": success_provider_calls,
        "lock_failures": success_lock_failures,
    },
    "failed_final_auth": {
        "raised": final_auth_failed,
        "auth_calls": failure_auth_calls,
        "provider_calls": failure_provider_calls,
        "prepared_count": prepared_after_failure,
        "published_count": len(cards_after_failure),
    },
    "prepared_retry": {
        "auth_calls": auth_calls,
        "provider_calls": provider_calls - provider_before_retry,
        "compiled_count": retry["compiled_count"],
        "prepared_count": len(list(prepared_directory.glob("*.json"))),
    },
}
metrics_path.write_text(
    json.dumps(metrics, sort_keys=True, separators=(",", ":")),
    encoding="utf-8",
)
PY
  then
    fail "pilot graph auth計測を完走する"
    return
  fi

  if python3 - "$metrics" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
item = value["success"]
assert item["candidate_count"] == 10
assert item["compiled_count"] == 10
assert item["provider_calls"] == 10
assert item["lock_failures"] == 0
assert item["auth_calls"] <= 2, item
PY
  then
    pass "10 candidate成功batchのfull graph authを最大2回にしprovider中lockを解放する"
  else
    fail "10 candidate成功batchのfull graph authを最大2回にしprovider中lockを解放する"
  fi

  if python3 - "$metrics" <<'PY'
import json
import pathlib
import sys

item = json.loads(pathlib.Path(sys.argv[1]).read_text())["failed_final_auth"]
assert item["raised"] is True
assert item["provider_calls"] == 10
assert item["auth_calls"] <= 2, item
assert item["prepared_count"] == 10
assert item["published_count"] == 0
PY
  then
    pass "anchor/index/forget相当の最終auth競合でpublishせず全provider結果をprepared保持する"
  else
    fail "anchor/index/forget相当の最終auth競合でpublishせず全provider結果をprepared保持する"
  fi

  if python3 - "$metrics" <<'PY'
import json
import pathlib
import sys

item = json.loads(pathlib.Path(sys.argv[1]).read_text())["prepared_retry"]
assert item["provider_calls"] == 0
assert item["auth_calls"] <= 2, item
assert item["compiled_count"] == 10
assert item["prepared_count"] == 0
PY
  then
    pass "prepared再開もfull graph auth最大2回で再課金せずfinalizeする"
  else
    fail "prepared再開もfull graph auth最大2回で再課金せずfinalizeする"
  fi
}

test_rehashed_semantic_tamper_rebuilds_current_packet() {
  echo "test_rehashed_semantic_tamper_rebuilds_current_packet:"
  local episode err="$TEST_ROOT/value-cycle6-tamper.err"
  fresh_blocker_fixture cycle6-tamper || {
    fail "cycle6 tamper fixtureを構築できる"
    return
  }
  episode="$(episode_for_event 75000000-0000-4000-8000-000000000002)"
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator --model value-model-cycle6-tamper \
    --max-episodes 100 --max-cost-microusd 600000 --json \
    >/dev/null 2>"$err" || {
      fail "cycle6 tamper fixtureをprewarmできる"
      return
    }
  if ! python3 - "$STATE" "$episode" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
directory = root / "value-primitive-cards"
for path in directory.glob("*.json"):
    card = json.loads(path.read_text())
    if (
        card["episode_id"] == episode
        and card["provenance"]["evaluator_model"] == "value-model-cycle6-tamper"
    ):
        break
else:
    raise AssertionError("target card not found")
goal = card["primitives"]["goal_achievement"]
goal["state"] = "negative"
reference = goal["evidence_references"][0]
card["provenance"]["input_evidence_fields"][reference] = (
    "receipt.result.outcome"
)
card["provenance"]["packet_sha256"] = "sha256:" + "f" * 64
without_id = {
    key: value for key, value in card.items()
    if key != "value_primitive_card_id"
}
canonical = json.dumps(without_id, sort_keys=True, separators=(",", ":")).encode()
card["value_primitive_card_id"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
target = directory / f"{card['value_primitive_card_id'].removeprefix('sha256:')}.json"
target.write_text(json.dumps(card, sort_keys=True, separators=(",", ":")) + "\n")
target.chmod(0o600)
path.unlink()
PY
  then
    fail "cycle6 semantic tamper setupが失敗した"
    return
  fi
  if run_cli inspect "$episode" --json >/dev/null 2>"$err"; then
    fail "再hash済みprimitive/evidence/packet改変を拒否する"
  elif grep -q "Traceback" "$err"; then
    fail "semantic tamperを有限エラーで拒否する"
  else
    pass "current anchorsからpacketを再構成し意味論改変を拒否する"
  fi
}

test_unhashable_attempt_diagnostic_is_vault_error() {
  echo "test_unhashable_attempt_diagnostic_is_vault_error:"
  local episode err="$TEST_ROOT/value-cycle6-attempt.err"
  fresh_blocker_fixture cycle6-attempt || {
    fail "cycle6 attempt fixtureを構築できる"
    return
  }
  episode="$(episode_for_event 75000000-0000-4000-8000-000000000001)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" "$episode" <<'PY'
import json
import pathlib
import sys

import value_compiler

root = pathlib.Path(sys.argv[1])
attempt = value_compiler._new_attempt(
    sys.argv[2],
    "sha256:" + "a" * 64,
    "value-model-cycle6-attempt",
    "sha256:" + "b" * 64,
    "default-v1",
)
attempt["state"] = "failed"
attempt["diagnostic_code"] = []
directory = root / "value-compiler"
directory.mkdir(mode=0o700, exist_ok=True)
path = directory / "attempts.json"
path.write_text(json.dumps({"schema_version": 1, "attempts": [attempt]}))
path.chmod(0o600)
PY
  if run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-cycle6-attempt \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >/dev/null 2>"$err"; then
    fail "unhashable diagnosticを拒否する"
  elif grep -Eq "Traceback|TypeError" "$err"; then
    cat "$err" >&2
    fail "unhashable diagnosticをVaultError化する"
  else
    pass "unhashable diagnosticをtracebackなしで拒否する"
  fi
}

test_batch_failures_continue_and_return_nonzero() {
  echo "test_batch_failures_continue_and_return_nonzero:"
  local all_count="$TEST_ROOT/value-cycle6-all-count"
  local one_count="$TEST_ROOT/value-cycle6-one-count"
  local partial_count="$TEST_ROOT/value-cycle6-partial-count"
  local all_err="$TEST_ROOT/value-cycle6-all.err"
  local partial_err="$TEST_ROOT/value-cycle6-partial.err"
  local all_status one_status partial_status
  fresh_blocker_fixture cycle6-batch || {
    fail "cycle6 batch fixtureを構築できる"
    return
  }
  FLIGHT_RECORDER_TEST_VALUE_FAIL_ALL=1 \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$all_count" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-cycle6-all \
      --max-episodes 2 --max-cost-microusd 12000 --json \
      >"$TEST_ROOT/value-cycle6-all.json" 2>"$all_err"
  all_status=$?
  FLIGHT_RECORDER_TEST_VALUE_FAIL_ALL=1 \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$one_count" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-cycle6-one \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >"$TEST_ROOT/value-cycle6-one.json" 2>>"$all_err"
  one_status=$?
  FLIGHT_RECORDER_TEST_VALUE_FAIL_CALL=1 \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$partial_count" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator --model value-model-cycle6-partial \
      --max-episodes 2 --max-cost-microusd 12000 --json \
      >"$TEST_ROOT/value-cycle6-partial.json" 2>"$partial_err"
  partial_status=$?
  if python3 - \
      "$STATE" "$all_count" "$one_count" "$partial_count" \
      "$all_status" "$one_status" "$partial_status" <<'PY'
import json
import pathlib
import sys

(
    state, all_count, one_count, partial_count,
    all_status, one_status, partial_status,
) = sys.argv[1:]
assert int(all_status) != 0
assert int(one_status) != 0
assert int(partial_status) != 0
assert int(pathlib.Path(all_count).read_text()) == 2
assert int(pathlib.Path(one_count).read_text()) == 1
assert int(pathlib.Path(partial_count).read_text()) == 2
root = pathlib.Path(state)
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert not any(
    item["provenance"]["evaluator_model"] == "value-model-cycle6-all"
    for item in cards
)
assert not any(
    item["provenance"]["evaluator_model"] == "value-model-cycle6-one"
    for item in cards
)
assert sum(
    item["provenance"]["evaluator_model"] == "value-model-cycle6-partial"
    for item in cards
) == 1
ledger = json.loads((root / "value-compiler" / "attempts.json").read_text())
assert sum(
    item["evaluator_model"] == "value-model-cycle6-all"
    and item["state"] == "failed"
    for item in ledger["attempts"]
) == 2
assert sum(
    item["evaluator_model"] == "value-model-cycle6-partial"
    and item["state"] == "failed"
    for item in ledger["attempts"]
) == 1
PY
  then
    pass "batchは失敗後も継続しpartial card保持とnonzeroを両立する"
  else
    cat "$all_err" "$partial_err" >&2
    fail "batchは失敗後も継続しpartial card保持とnonzeroを両立する"
  fi
}

test_complete_prepared_atomic_temp_recovers_pending_attempt() {
  echo "test_complete_prepared_atomic_temp_recovers_pending_attempt:"
  local counter="$TEST_ROOT/value-cycle6-prepared-temp-count"
  fresh_blocker_fixture cycle6-prepared-temp || {
    fail "cycle6 prepared temp fixtureを構築できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    python3 - "$STATE" "$counter" <<'PY'
import json
import pathlib
import time
import sys

import value_compiler
from evaluation import _executable_identity, _invoke
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
counter = pathlib.Path(sys.argv[2])
model = "value-model-cycle6-prepared-temp"
evaluator_path, evaluator_sha256 = _executable_identity(
    "flight-recorder-value-evaluator"
)
with vault_lock(root):
    episode, packet = value_compiler._authenticated_packets(
        root, "default-v1", None
    )[0]
request = {
    "schema_version": 1,
    "model": model,
    "packet": packet,
    "remaining_cost_microusd": 6000,
}
started = time.monotonic_ns()
raw = _invoke(evaluator_path, evaluator_sha256, request, 60)
latency = max(0, (time.monotonic_ns() - started) // 1_000_000)
primitives, cost = value_compiler._validate_response(raw, packet, 6000)
card = value_compiler._build_card(
    episode,
    packet,
    primitives,
    model,
    evaluator_path,
    evaluator_sha256,
    "default-v1",
    cost,
    latency,
)
fingerprint = value_compiler._attempt_fingerprint(
    packet["packet_sha256"], model, evaluator_sha256, "default-v1"
)
prepared = {
    "schema_version": 1,
    "contract_version": value_compiler.PREPARED_CONTRACT,
    "fingerprint": fingerprint,
    "episode_id": episode["episode_id"],
    "packet_sha256": packet["packet_sha256"],
    "evaluator_model": model,
    "evaluator_adapter_sha256": evaluator_sha256,
    "policy_version": "default-v1",
    "card": card,
}
attempt = value_compiler._new_attempt(
    episode["episode_id"],
    packet["packet_sha256"],
    model,
    evaluator_sha256,
    "default-v1",
)
with vault_lock(root):
    path = value_compiler._store_prepared(root, prepared)
    value_compiler._store_attempts(
        root, {"schema_version": 1, "attempts": [attempt]}
    )
    temporary = path.with_name(f".{path.name}.fixture")
    path.rename(temporary)

result = value_compiler.compile_values(
    root,
    "flight-recorder-value-evaluator",
    model,
    1,
    6000,
    60,
)
assert int(counter.read_text()) == 1
assert result["compiled_count"] == 1
assert not temporary.exists()
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert any(
    item["episode_id"] == episode["episode_id"]
    and item["provenance"]["evaluator_model"] == model
    for item in cards
)
PY
  then
    pass "完全prepared tempとpending attemptをproviderなしでfinalizeする"
  else
    fail "完全prepared tempとpending attemptをproviderなしでfinalizeする"
  fi
}

setup_invalid_prepared_temp() {
  local kind="$1"
  fresh_blocker_fixture "cycle6-prepared-$kind" || return 1
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" "$kind" <<'PY'
import pathlib
import sys

import value_compiler
from evaluation import _executable_identity
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
model = f"value-model-cycle6-prepared-{kind}"
_path, evaluator_sha256 = _executable_identity(
    "flight-recorder-value-evaluator"
)
with vault_lock(root):
    episode, packet = value_compiler._authenticated_packets(
        root, "default-v1", None
    )[0]
    attempt = value_compiler._new_attempt(
        episode["episode_id"],
        packet["packet_sha256"],
        model,
        evaluator_sha256,
        "default-v1",
    )
    value_compiler._store_attempts(
        root, {"schema_version": 1, "attempts": [attempt]}
    )
directory = root / "value-compiler" / "prepared"
directory.mkdir(mode=0o700, exist_ok=True)
temp = directory / f".{attempt['fingerprint'].removeprefix('sha256:')}.json.fixture"
if kind == "oversize":
    temp.write_bytes(b"x" * (value_compiler.MAX_PREPARED_BYTES + 1))
else:
    temp.write_text("{}\n")
temp.chmod(0o644 if kind == "unsafe" else 0o600)
PY
}

test_invalid_prepared_temps_never_leave_silent_pending() {
  echo "test_invalid_prepared_temps_never_leave_silent_pending:"
  local kind status pending temp_count failures=0
  for kind in incomplete oversize unsafe; do
    setup_invalid_prepared_temp "$kind" || {
      fail "invalid prepared $kind fixtureを構築できる"
      return
    }
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model "value-model-cycle6-prepared-$kind" \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >/dev/null 2>"$TEST_ROOT/value-cycle6-prepared-$kind.err"
    status=$?
    pending="$(python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "value-compiler" / "attempts.json"
value = json.loads(path.read_text())
print(sum(item["state"] == "pending" for item in value["attempts"]))
PY
)"
    temp_count="$(find "$STATE/value-compiler/prepared" -type f \
      -name '.*.json.*' | wc -l | tr -d ' ')"
    if [[ "$status" -eq 0 && "$pending" -gt 0 && "$temp_count" -gt 0 ]]; then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "不完全・oversize・unsafe prepared tempを黙って永久pendingにしない"
  else
    fail "不完全・oversize・unsafe prepared tempを黙って永久pendingにしない"
  fi
}

test_one_changed_candidate_does_not_abort_batch() {
  echo "test_one_changed_candidate_does_not_abort_batch:"
  local started="$TEST_ROOT/value-cycle7-changed-started"
  local release="$TEST_ROOT/value-cycle7-changed-release"
  local counter="$TEST_ROOT/value-cycle7-changed-count"
  local output="$TEST_ROOT/value-cycle7-changed.json"
  local err="$TEST_ROOT/value-cycle7-changed.err"
  local target_episode other_episode anchor_path process index status
  fresh_blocker_fixture cycle7-changed || {
    fail "cycle7 changed-input fixtureを構築できる"
    return
  }
  IFS=$'\t' read -r target_episode other_episode anchor_path < <(
    PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" <<'PY'
import pathlib
import sys

import value_compiler
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
with vault_lock(root):
    index = value_compiler._build_anchor_index(root, "default-v1")
    candidates = value_compiler._authenticated_packets(
        root, "default-v1", None, anchor_index=index
    )
assert len(candidates) >= 2
target, other = candidates[:2]
anchor_id = target[1]["anchor_ids"][0]
print(
    target[0]["episode_id"],
    other[0]["episode_id"],
    index["records"][anchor_id]["path"],
    sep="\t",
)
PY
  )
  if [[ -z "$target_episode" || -z "$other_episode" || ! -f "$anchor_path" ]]; then
    fail "変更対象candidateを特定できる"
    return
  fi

  FLIGHT_RECORDER_TEST_VALUE_STARTED="$started" \
    FLIGHT_RECORDER_TEST_VALUE_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-model-cycle7-changed \
      --max-episodes 2 --max-cost-microusd 12000 --timeout 60 --json \
      >"$output" 2>"$err" &
  process=$!
  for index in $(seq 1 100); do
    [[ -e "$started" && -s "$counter" ]] && break
    sleep 0.05
  done
  if [[ ! -e "$started" || ! -s "$counter" ]]; then
    touch "$release"
    wait "$process" 2>/dev/null
    fail "変更競合前にproviderが開始する"
    return
  fi
  python3 - "$anchor_path" "$release" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).unlink()
pathlib.Path(sys.argv[2]).touch()
PY
  wait "$process"
  status=$?

  if [[ "$status" -ne 0 ]] && python3 - \
      "$STATE" "$counter" "$target_episode" "$other_episode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
assert int(pathlib.Path(sys.argv[2]).read_text()) == 2
target, other = sys.argv[3:5]
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
selected = [
    card for card in cards
    if card["provenance"]["evaluator_model"] == "value-model-cycle7-changed"
]
assert not any(card["episode_id"] == target for card in selected)
assert sum(card["episode_id"] == other for card in selected) == 1
attempts = json.loads(
    (root / "value-compiler" / "attempts.json").read_text()
)["attempts"]
failed = [item for item in attempts if item["episode_id"] == target]
assert len(failed) == 1
assert failed[0]["state"] == "failed"
assert failed[0]["diagnostic_code"] == "input_changed"
PY
  then
    pass "1 candidateのinput変更だけを失敗にし他candidateを保存する"
  else
    cat "$err" >&2
    fail "1 candidateのinput変更だけを失敗にし他candidateを保存する"
  fi
}

test_human_inspect_exposes_value_card_evidence() {
  echo "test_human_inspect_exposes_value_card_evidence:"
  local human="$TEST_ROOT/value-cycle7-inspect.txt"
  local err="$TEST_ROOT/value-cycle7-inspect.err"
  local episode
  fresh_blocker_fixture cycle7-inspect || {
    fail "cycle7 inspect fixtureを構築できる"
    return
  }
  if ! run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-model-cycle7-inspect \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >/dev/null 2>"$err"; then
    fail "human inspect用Value Cardを作成できる"
    return
  fi
  episode="$(python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

for path in (pathlib.Path(sys.argv[1]) / "value-primitive-cards").glob("*.json"):
    card = json.loads(path.read_text())
    if card["provenance"]["evaluator_model"] == "value-model-cycle7-inspect":
        print(card["episode_id"])
        break
else:
    raise AssertionError("inspect card not found")
PY
)"
  if run_cli inspect "$episode" >"$human" 2>"$err" \
    && run_cli inspect "$episode" --json >"$TEST_ROOT/value-cycle7-inspect.json" 2>>"$err" \
    && python3 - \
      "$STATE" "$episode" "$human" "$TEST_ROOT/value-cycle7-inspect.json" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
human = pathlib.Path(sys.argv[3]).read_text()
inspection = json.loads(pathlib.Path(sys.argv[4]).read_text())
assert inspection["schema_version"] == 5
cards = inspection["value_primitive_cards"]
assert len(cards) == 1
card = cards[0]
assert card["episode_id"] == episode
provenance = card["provenance"]
for required in (
    provenance["evaluator_model"],
    provenance["generated_at"],
    str(provenance["generation_cost_microusd"]),
    *provenance["input_anchor_ids"],
):
    assert required in human, required
for axis, primitive in card["primitives"].items():
    assert axis in human
    for required in (
        primitive["state"],
        primitive["basis"],
        primitive["confidence"],
        primitive["summary"],
        *primitive["evidence_references"],
    ):
        assert required in human, (axis, required)
episode_card = inspection["card"]
assert str(episode_card["measured_duration_ms"]["value"]) in human
assert str(episode_card["measured_cost_usd"]["value"]) in human
PY
  then
    pass "human inspectでValue Cardの由来・8軸根拠・元task実測値を読める"
  else
    cat "$err" >&2
    fail "human inspectでValue Cardの由来・8軸根拠・元task実測値を読める"
  fi
}

test_new_anchor_during_provider_invalidates_old_packet() {
  echo "test_new_anchor_during_provider_invalidates_old_packet:"
  local started="$TEST_ROOT/value-cycle8-anchor-started"
  local release="$TEST_ROOT/value-cycle8-anchor-release"
  local counter="$TEST_ROOT/value-cycle8-anchor-count"
  local err="$TEST_ROOT/value-cycle8-anchor.err"
  local episode process index status
  fresh_blocker_fixture cycle8-anchor-delta || {
    fail "cycle8 anchor-delta fixtureを構築できる"
    return
  }
  episode="$(PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" <<'PY'
import pathlib
import sys

import value_compiler
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
with vault_lock(root):
    episode, _packet = value_compiler._authenticated_packets(
        root, "default-v1", None
    )[0]
print(episode["episode_id"])
PY
)"
  FLIGHT_RECORDER_TEST_VALUE_STARTED="$started" \
    FLIGHT_RECORDER_TEST_VALUE_RELEASE="$release" \
    FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
    run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-model-cycle8-anchor-delta \
      --max-episodes 1 --max-cost-microusd 6000 --timeout 60 --json \
      >"$TEST_ROOT/value-cycle8-anchor.json" 2>"$err" &
  process=$!
  for index in $(seq 1 100); do
    [[ -e "$started" && -s "$counter" ]] && break
    sleep 0.05
  done
  if [[ ! -e "$started" || ! -s "$counter" ]]; then
    touch "$release"
    wait "$process" 2>/dev/null
    fail "anchor追加前にproviderが開始する"
    return
  fi
  if ! generate_meaning_card \
      "$episode" cycle8-anchor-v2 "2026-08-09T03:02:03Z"; then
    touch "$release"
    wait "$process" 2>/dev/null
    fail "provider待機中に新anchorを追加できる"
    return
  fi
  touch "$release"
  wait "$process"
  status=$?
  if [[ "$status" -ne 0 ]] && python3 - \
      "$STATE" "$episode" "$counter" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
assert int(pathlib.Path(sys.argv[3]).read_text()) == 1
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert not any(
    card["episode_id"] == episode
    and card["provenance"]["evaluator_model"]
        == "value-model-cycle8-anchor-delta"
    for card in cards
)
attempts = json.loads(
    (root / "value-compiler" / "attempts.json").read_text()
)["attempts"]
selected = [item for item in attempts if item["episode_id"] == episode]
assert len(selected) == 1
assert selected[0]["state"] == "failed"
assert selected[0]["diagnostic_code"] == "input_changed"
PY
  then
    pass "provider中のanchor集合deltaを検知し旧packet Cardを公開しない"
  else
    cat "$err" >&2
    fail "provider中のanchor集合deltaを検知し旧packet Cardを公開しない"
  fi
}

test_historical_anchor_cards_coexist_and_stale_is_finite() {
  echo "test_historical_anchor_cards_coexist_and_stale_is_finite:"
  local err="$TEST_ROOT/value-cycle8-coexist.err"
  local first="$TEST_ROOT/value-cycle8-coexist-first.json"
  local second="$TEST_ROOT/value-cycle8-coexist-second.json"
  local inspection="$TEST_ROOT/value-cycle8-coexist-inspect.json"
  local stale="$TEST_ROOT/value-cycle8-coexist-stale.json"
  local episode old_anchor new_anchor
  fresh_blocker_fixture cycle8-coexist || {
    fail "cycle8 coexist fixtureを構築できる"
    return
  }
  if ! run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-model-cycle8-coexist \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >"$first" 2>"$err"; then
    fail "anchor v1のValue Cardを作成できる"
    return
  fi
  IFS=$'\t' read -r episode old_anchor < <(python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

cards = [
    json.loads(path.read_text())
    for path in (pathlib.Path(sys.argv[1]) / "value-primitive-cards").glob("*.json")
]
selected = [
    card for card in cards
    if card["provenance"]["evaluator_model"] == "value-model-cycle8-coexist"
]
assert len(selected) == 1
card = selected[0]
assert len(card["provenance"]["input_anchor_ids"]) == 1
print(card["episode_id"], card["provenance"]["input_anchor_ids"][0], sep="\t")
PY
  )
  generate_meaning_card \
    "$episode" cycle8-coexist-v2 "2026-08-09T04:02:03Z" || {
      fail "anchor v2を追加できる"
      return
    }
  if ! run_cli value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-model-cycle8-coexist \
      --max-episodes 1 --max-cost-microusd 6000 --json \
      >"$second" 2>>"$err"; then
    fail "anchor v2のValue Cardを作成できる"
    return
  fi
  new_anchor="$(python3 - "$STATE" "$episode" "$old_anchor" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode, old = sys.argv[2:4]
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
selected = [
    card for card in cards
    if card["episode_id"] == episode
    and card["provenance"]["evaluator_model"] == "value-model-cycle8-coexist"
]
assert len(selected) == 2
anchors = {
    card["provenance"]["input_anchor_ids"][0]
    for card in selected
}
anchors.remove(old)
print(anchors.pop())
PY
)"
  if run_cli inspect "$episode" --json >"$inspection" 2>>"$err" \
    && python3 - "$inspection" "$old_anchor" "$new_anchor" <<'PY'
import json
import pathlib
import sys

inspection = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert inspection["schema_version"] == 5
cards = inspection["value_primitive_cards"]
assert len(cards) == 2
assert {
    tuple(card["provenance"]["input_anchor_ids"])
    for card in cards
} == {(sys.argv[2],), (sys.argv[3],)}
assert len({card["provenance"]["packet_sha256"] for card in cards}) == 2
PY
  then
    python3 - "$STATE" "$old_anchor" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "meaning-cards" / (
    sys.argv[2].removeprefix("sha256:") + ".json"
)
path.unlink()
PY
    if run_cli inspect "$episode" --json >"$stale" 2>>"$err" \
      && python3 - "$stale" "$new_anchor" <<'PY'
import json
import pathlib
import sys

cards = json.loads(pathlib.Path(sys.argv[1]).read_text())["value_primitive_cards"]
assert len(cards) == 1
assert cards[0]["provenance"]["input_anchor_ids"] == [sys.argv[2]]
PY
    then
      pass "anchor世代別Cardを共存認証し削除済み世代だけstale化する"
    else
      cat "$err" >&2
      fail "anchor世代別Cardを共存認証し削除済み世代だけstale化する"
    fi
  else
    cat "$err" >&2
    fail "anchor世代別Cardを共存認証し削除済み世代だけstale化する"
  fi
}

setup_cycle8_prepared_temp() {
  local fixture="$1" model="$2"
  fresh_blocker_fixture "$fixture" || return 1
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" "$model" <<'PY'
import pathlib
import sys
import time

import value_compiler
from evaluation import _executable_identity, _invoke
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
model = sys.argv[2]
evaluator_path, evaluator_sha256 = _executable_identity(
    "flight-recorder-value-evaluator"
)
with vault_lock(root):
    episode, packet = value_compiler._authenticated_packets(
        root, "default-v1", None
    )[0]
request = {
    "schema_version": 1,
    "model": model,
    "packet": packet,
    "remaining_cost_microusd": 6000,
}
started = time.monotonic_ns()
raw = _invoke(evaluator_path, evaluator_sha256, request, 60)
latency_ms = max(0, (time.monotonic_ns() - started) // 1_000_000)
primitives, cost = value_compiler._validate_response(raw, packet, 6000)
card = value_compiler._build_card(
    episode, packet, primitives, model, evaluator_path, evaluator_sha256,
    "default-v1", cost, latency_ms,
)
fingerprint = value_compiler._attempt_fingerprint(
    packet["packet_sha256"], model, evaluator_sha256, "default-v1"
)
prepared = {
    "schema_version": 1,
    "contract_version": value_compiler.PREPARED_CONTRACT,
    "fingerprint": fingerprint,
    "episode_id": episode["episode_id"],
    "packet_sha256": packet["packet_sha256"],
    "evaluator_model": model,
    "evaluator_adapter_sha256": evaluator_sha256,
    "policy_version": "default-v1",
    "card": card,
}
with vault_lock(root):
    path = value_compiler._store_prepared(root, prepared)
    temporary = path.with_name(f".{path.name}.cycle8")
    path.rename(temporary)
PY
}

test_prepared_temp_promotion_fsyncs_directory() {
  echo "test_prepared_temp_promotion_fsyncs_directory:"
  setup_cycle8_prepared_temp \
    cycle8-prepared-fsync value-model-cycle8-prepared-fsync || {
      fail "cycle8 prepared fsync fixtureを構築できる"
      return
    }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$STATE" <<'PY'
import os
import pathlib
import stat
import sys

import value_compiler

root = pathlib.Path(sys.argv[1])
directory = root / "value-compiler" / "prepared"
calls = []
original = os.fsync


def tracked(descriptor):
    if stat.S_ISDIR(os.fstat(descriptor).st_mode):
        calls.append(descriptor)
    return original(descriptor)


os.fsync = tracked
try:
    value_compiler._recover_prepared_temporaries(root)
    records = value_compiler._stored_prepared_records(root)
finally:
    os.fsync = original
assert len(records) == 1
assert not list(directory.glob(".*.json.*"))
assert len(list(directory.glob("*.json"))) == 1
assert calls, "prepared directory was not fsynced after promotion"
PY
  then
    pass "prepared tempのrename/unlink後にdirectoryをfsyncする"
  else
    fail "prepared tempのrename/unlink後にdirectoryをfsyncする"
  fi
}

test_unsafe_prepared_directory_has_zero_mutation() {
  echo "test_unsafe_prepared_directory_has_zero_mutation:"
  local kind failures=0
  for kind in mode uid type; do
    setup_cycle8_prepared_temp \
      "cycle8-prepared-unsafe-$kind" \
      "value-model-cycle8-prepared-unsafe-$kind" || {
        fail "cycle8 unsafe prepared $kind fixtureを構築できる"
        return
      }
    if ! PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$STATE" "$kind" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

import value_compiler
from vault import VaultError

root = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
directory = root / "value-compiler" / "prepared"
original_lstat = pathlib.Path.lstat
if kind == "mode":
    directory.chmod(0o777)
elif kind == "type":
    backup = directory.with_name("prepared-cycle8-backup")
    directory.rename(backup)
    directory.write_bytes(b"not-a-directory")
    directory.chmod(0o600)
elif kind == "uid":
    def forged_lstat(path):
        metadata = original_lstat(path)
        if path == directory:
            fields = list(metadata)
            fields[4] = os.geteuid() + 1
            return os.stat_result(fields)
        return metadata

    pathlib.Path.lstat = forged_lstat
else:
    raise AssertionError(kind)


def snapshot():
    if kind == "type":
        backup = directory.with_name("prepared-cycle8-backup")
        return (
            stat.S_IMODE(original_lstat(directory).st_mode),
            hashlib.sha256(directory.read_bytes()).hexdigest(),
            tuple(
                (path.name, hashlib.sha256(path.read_bytes()).hexdigest())
                for path in sorted(backup.iterdir())
            ),
        )
    return (
        stat.S_IMODE(original_lstat(directory).st_mode),
        tuple(
            (path.name, hashlib.sha256(path.read_bytes()).hexdigest())
            for path in sorted(directory.iterdir())
        ),
    )


before = snapshot()
try:
    value_compiler._recover_prepared_temporaries(root)
except VaultError:
    pass
else:
    raise AssertionError("unsafe prepared directory was accepted")
finally:
    pathlib.Path.lstat = original_lstat
assert snapshot() == before
PY
    then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "unsafe prepared directoryをpromotion前に拒否しmutationしない"
  else
    fail "unsafe prepared directoryをpromotion前に拒否しmutationしない"
  fi
}

test_human_inspect_maps_evidence_ids_to_fields() {
  echo "test_human_inspect_maps_evidence_ids_to_fields:"
  local episode human="$TEST_ROOT/value-cycle8-fields.txt"
  local inspection="$TEST_ROOT/value-cycle8-fields.json"
  local err="$TEST_ROOT/value-cycle8-fields.err"
  fresh_blocker_fixture cycle8-fields || {
    fail "cycle8 evidence-field fixtureを構築できる"
    return
  }
  run_cli value compile \
    --evaluator flight-recorder-value-evaluator \
    --model value-model-cycle8-fields \
    --max-episodes 1 --max-cost-microusd 6000 --json \
    >/dev/null 2>"$err" || {
      fail "evidence-field表示用Cardを作成できる"
      return
    }
  episode="$(python3 - "$STATE" <<'PY'
import json
import pathlib
import sys

for path in (pathlib.Path(sys.argv[1]) / "value-primitive-cards").glob("*.json"):
    value = json.loads(path.read_text())
    if value["provenance"]["evaluator_model"] == "value-model-cycle8-fields":
        print(value["episode_id"])
        break
PY
)"
  if run_cli inspect "$episode" >"$human" 2>"$err" \
    && run_cli inspect "$episode" --json >"$inspection" 2>>"$err" \
    && python3 - "$human" "$inspection" <<'PY'
import json
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
card = json.loads(pathlib.Path(sys.argv[2]).read_text())["value_primitive_cards"][0]
for evidence_id, field in card["provenance"]["input_evidence_fields"].items():
    assert any(evidence_id in line and field in line for line in lines), (
        evidence_id, field
    )
PY
  then
    pass "human inspectでevidence ref hashとfield種別を対応表示する"
  else
    cat "$err" >&2
    fail "human inspectでevidence ref hashとfield種別を対応表示する"
  fi
}

test_input_changed_provider_cost_consumes_batch_budget() {
  echo "test_input_changed_provider_cost_consumes_batch_budget:"
  local budget state_name started_dir release_dir counter capture err process
  local first_episode first_anchor second_episode second_anchor index status
  local failures=0
  for budget in 6000 12000; do
    state_name="cycle9-spend-$budget"
    fresh_blocker_fixture "$state_name" || {
      fail "cycle9 spend $budget fixtureを構築できる"
      return
    }
    started_dir="$TEST_ROOT/value-cycle9-$budget-started"
    release_dir="$TEST_ROOT/value-cycle9-$budget-release"
    counter="$TEST_ROOT/value-cycle9-$budget-count"
    capture="$TEST_ROOT/value-cycle9-$budget-capture.jsonl"
    err="$TEST_ROOT/value-cycle9-$budget.err"
    IFS=$'\t' read -r \
      first_episode first_anchor second_episode second_anchor < <(
      PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
        python3 - "$STATE" <<'PY'
import pathlib
import sys

import value_compiler
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
with vault_lock(root):
    index = value_compiler._build_anchor_index(root, "default-v1")
    candidates = value_compiler._authenticated_packets(
        root, "default-v1", None, anchor_index=index
    )
assert len(candidates) >= 2
values = []
for episode, packet in candidates[:2]:
    anchor_id = packet["anchor_ids"][0]
    values.extend((episode["episode_id"], str(index["records"][anchor_id]["path"])))
print(*values, sep="\t")
PY
    )
    FLIGHT_RECORDER_TEST_VALUE_STARTED_DIR="$started_dir" \
      FLIGHT_RECORDER_TEST_VALUE_RELEASE_DIR="$release_dir" \
      FLIGHT_RECORDER_TEST_VALUE_COUNT="$counter" \
      FLIGHT_RECORDER_TEST_VALUE_CAPTURE="$capture" \
      run_cli value compile \
        --evaluator flight-recorder-value-evaluator \
        --model "value-model-cycle9-spend-$budget" \
        --max-episodes 2 --max-cost-microusd "$budget" \
        --timeout 60 --json \
        >"$TEST_ROOT/value-cycle9-$budget.json" 2>"$err" &
    process=$!
    for index in $(seq 1 100); do
      [[ -e "$started_dir/1" ]] && break
      sleep 0.05
    done
    if [[ ! -e "$started_dir/1" ]]; then
      mkdir -p "$release_dir"
      touch "$release_dir/1" "$release_dir/2"
      wait "$process" 2>/dev/null
      failures=$((failures + 1))
      continue
    fi
    python3 - "$first_anchor" "$release_dir/1" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).unlink()
release = pathlib.Path(sys.argv[2])
release.parent.mkdir(parents=True, exist_ok=True)
release.touch()
PY
    if [[ "$budget" -eq 12000 ]]; then
      for index in $(seq 1 100); do
        [[ -e "$started_dir/2" ]] && break
        ! kill -0 "$process" 2>/dev/null && break
        sleep 0.05
      done
      if [[ -e "$started_dir/2" ]]; then
        python3 - "$second_anchor" "$release_dir/2" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).unlink()
pathlib.Path(sys.argv[2]).touch()
PY
      else
        failures=$((failures + 1))
      fi
    else
      for index in $(seq 1 60); do
        [[ -e "$started_dir/2" ]] && break
        ! kill -0 "$process" 2>/dev/null && break
        sleep 0.05
      done
      # Release an incorrect second charge so a Red run cannot block cleanup.
      if [[ -e "$started_dir/2" ]]; then
        touch "$release_dir/2"
      fi
    fi
    wait "$process"
    status=$?
    if [[ "$status" -eq 0 ]] || ! python3 - \
        "$STATE" "$budget" "$counter" "$capture" \
        "$first_episode" "$second_episode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
budget = int(sys.argv[2])
counter = int(pathlib.Path(sys.argv[3]).read_text())
requests = [
    json.loads(line)
    for line in pathlib.Path(sys.argv[4]).read_text().splitlines()
    if line
]
episodes = sys.argv[5:7]
expected_count = 1 if budget == 6000 else 2
assert counter == expected_count
assert len(requests) == expected_count
assert [item["remaining_cost_microusd"] for item in requests] == (
    [6000] if budget == 6000 else [12000, 6000]
)
model = f"value-model-cycle9-spend-{budget}"
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
assert not any(
    card["provenance"]["evaluator_model"] == model for card in cards
)
attempts = json.loads(
    (root / "value-compiler" / "attempts.json").read_text()
)["attempts"]
failed = [item for item in attempts if item["evaluator_model"] == model]
assert len(failed) == expected_count
assert {item["episode_id"] for item in failed} == set(episodes[:expected_count])
assert all(
    item["state"] == "failed"
    and item["diagnostic_code"] == "input_changed"
    for item in failed
)
PY
    then
      cat "$err" >&2
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "公開失敗でもprovider実支出を即時budget消費しremainingを単調減少させる"
  else
    fail "公開失敗でもprovider実支出を即時budget消費しremainingを単調減少させる"
  fi
}

main() {
  if [[ "${FLIGHT_RECORDER_TEST_VALUE_BLOCKERS_ONLY:-0}" == "1" \
      || "${FLIGHT_RECORDER_TEST_VALUE_CYCLE6_ONLY:-0}" == "1" \
      || "${FLIGHT_RECORDER_TEST_VALUE_CYCLE7_ONLY:-0}" == "1" \
      || "${FLIGHT_RECORDER_TEST_VALUE_CYCLE8_ONLY:-0}" == "1" \
      || "${FLIGHT_RECORDER_TEST_VALUE_CYCLE9_ONLY:-0}" == "1" \
      || "${FLIGHT_RECORDER_TEST_VALUE_PILOT_PERF_ONLY:-0}" == "1" ]]; then
    true
  elif ! build_fixture; then
    fail "Value Compiler fixtureを構築できる"
    echo
    echo "Result: $PASS passed, $FAIL failed"
    exit 1
  fi
  if [[ "${FLIGHT_RECORDER_TEST_VALUE_CONCURRENCY_ONLY:-0}" == "1" ]]; then
    test_concurrent_compile_reuses_reservation_without_blocking_inspect
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_ATTEMPTS_ONLY:-0}" == "1" ]]; then
    test_orphaned_valid_response_is_prepared_and_finalized
    test_oversized_response_leaves_durable_failure_without_recharge
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_REVIEW_ONLY:-0}" == "1" ]]; then
    case "${FLIGHT_RECORDER_TEST_VALUE_REVIEW_CASE:-all}" in
      directional)
        test_directional_grounding_rejects_positive_from_unknown_outcome
        ;;
      malformed)
        test_malformed_evaluator_fails_cleanly_and_closes_attempt
        ;;
      tamper)
        test_rehashed_observation_tamper_fails_current_binding
        ;;
      all)
        test_directional_grounding_rejects_positive_from_unknown_outcome
        test_malformed_evaluator_fails_cleanly_and_closes_attempt
        test_rehashed_observation_tamper_fails_current_binding
        ;;
      *)
        fail "unknown review test case"
        ;;
    esac
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_BLOCKERS_ONLY:-0}" == "1" ]]; then
    case "${FLIGHT_RECORDER_TEST_VALUE_BLOCKER_CASE:-all}" in
      anchor-first)
        test_anchor_first_materializes_only_semantic_candidates
        ;;
      prepared)
        test_valid_provider_result_is_prepared_before_final_auth
        ;;
      cleanup)
        test_completed_attempts_are_cleaned_before_capacity_check
        ;;
      temp)
        test_card_storage_ignores_only_strict_atomic_temps
        ;;
      all)
        test_anchor_first_materializes_only_semantic_candidates
        test_valid_provider_result_is_prepared_before_final_auth
        test_completed_attempts_are_cleaned_before_capacity_check
        test_card_storage_ignores_only_strict_atomic_temps
        ;;
      *)
        fail "unknown blocker test case"
        ;;
    esac
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_CYCLE6_ONLY:-0}" == "1" ]]; then
    case "${FLIGHT_RECORDER_TEST_VALUE_CYCLE6_CASE:-all}" in
      performance)
        test_reauthentication_scans_anchors_once_per_batch
        ;;
      semantic-tamper)
        test_rehashed_semantic_tamper_rebuilds_current_packet
        ;;
      attempt-shape)
        test_unhashable_attempt_diagnostic_is_vault_error
        ;;
      prepared-temp)
        test_complete_prepared_atomic_temp_recovers_pending_attempt
        ;;
      prepared-invalid)
        test_invalid_prepared_temps_never_leave_silent_pending
        ;;
      batch-failure)
        test_batch_failures_continue_and_return_nonzero
        ;;
      all)
        test_reauthentication_scans_anchors_once_per_batch
        test_rehashed_semantic_tamper_rebuilds_current_packet
        test_unhashable_attempt_diagnostic_is_vault_error
        test_complete_prepared_atomic_temp_recovers_pending_attempt
        test_invalid_prepared_temps_never_leave_silent_pending
        test_batch_failures_continue_and_return_nonzero
        ;;
      *)
        fail "unknown cycle6 test case"
        ;;
    esac
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_CYCLE7_ONLY:-0}" == "1" ]]; then
    case "${FLIGHT_RECORDER_TEST_VALUE_CYCLE7_CASE:-all}" in
      changed-input)
        test_one_changed_candidate_does_not_abort_batch
        ;;
      human-inspect)
        test_human_inspect_exposes_value_card_evidence
        ;;
      all)
        test_one_changed_candidate_does_not_abort_batch
        test_human_inspect_exposes_value_card_evidence
        ;;
      *)
        fail "unknown cycle7 test case"
        ;;
    esac
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_CYCLE8_ONLY:-0}" == "1" ]]; then
    case "${FLIGHT_RECORDER_TEST_VALUE_CYCLE8_CASE:-all}" in
      anchor-delta)
        test_new_anchor_during_provider_invalidates_old_packet
        ;;
      coexist)
        test_historical_anchor_cards_coexist_and_stale_is_finite
        ;;
      prepared-fsync)
        test_prepared_temp_promotion_fsyncs_directory
        ;;
      prepared-unsafe)
        test_unsafe_prepared_directory_has_zero_mutation
        ;;
      human-fields)
        test_human_inspect_maps_evidence_ids_to_fields
        ;;
      all)
        test_new_anchor_during_provider_invalidates_old_packet
        test_historical_anchor_cards_coexist_and_stale_is_finite
        test_prepared_temp_promotion_fsyncs_directory
        test_unsafe_prepared_directory_has_zero_mutation
        test_human_inspect_maps_evidence_ids_to_fields
        ;;
      *)
        fail "unknown cycle8 test case"
        ;;
    esac
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_CYCLE9_ONLY:-0}" == "1" ]]; then
    test_input_changed_provider_cost_consumes_batch_budget
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_PILOT_PERF_ONLY:-0}" == "1" ]]; then
    test_ten_candidate_batch_authenticates_graph_constant_times
  else
    test_versioned_cards_are_grounded_bounded_and_idempotent
    test_wrong_axis_reference_fails_closed_without_storing_a_card
    test_forget_and_purge_cover_value_primitive_cards
    test_concurrent_compile_reuses_reservation_without_blocking_inspect
    test_orphaned_valid_response_is_prepared_and_finalized
    test_oversized_response_leaves_durable_failure_without_recharge
    test_directional_grounding_rejects_positive_from_unknown_outcome
    test_malformed_evaluator_fails_cleanly_and_closes_attempt
    test_rehashed_observation_tamper_fails_current_binding
    test_anchor_first_materializes_only_semantic_candidates
    test_valid_provider_result_is_prepared_before_final_auth
    test_completed_attempts_are_cleaned_before_capacity_check
    test_card_storage_ignores_only_strict_atomic_temps
    test_reauthentication_scans_anchors_once_per_batch
    test_rehashed_semantic_tamper_rebuilds_current_packet
    test_unhashable_attempt_diagnostic_is_vault_error
    test_complete_prepared_atomic_temp_recovers_pending_attempt
    test_invalid_prepared_temps_never_leave_silent_pending
    test_batch_failures_continue_and_return_nonzero
    test_one_changed_candidate_does_not_abort_batch
    test_human_inspect_exposes_value_card_evidence
    test_new_anchor_during_provider_invalidates_old_packet
    test_historical_anchor_cards_coexist_and_stale_is_finite
    test_prepared_temp_promotion_fsyncs_directory
    test_unsafe_prepared_directory_has_zero_mutation
    test_human_inspect_maps_evidence_ids_to_fields
    test_input_changed_provider_cost_consumes_batch_budget
    test_ten_candidate_batch_authenticates_graph_constant_times
  fi
  echo
  echo "Result: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
