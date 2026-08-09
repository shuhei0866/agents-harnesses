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
event = {
    "schema_version": 3,
    "event_id": event_id,
    "recorded_at": timestamp,
    "harness": "codex",
    "source_event": "PostToolUse",
    "event_kind": "tool.completed",
    "session_id_hash": "sha256:" + task_digit * 24,
    "turn_id_hash": "sha256:" + task_digit * 24,
    "workspace_id": "sha256:" + "a" * 24,
    "model": "fixture-worker-model",
    "permission_mode": None,
    "tool": "Bash",
    "metrics": {"duration_ms": 1000 + int(task_digit, 16), "retry_count": 0},
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": "sha256:" + task_digit * 24,
        "task_source": "payload",
        "branch_or_worktree_id": "sha256:" + "b" * 24,
        "changed_file_fingerprints": ["sha256:" + task_digit * 24],
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
  FLIGHT_RECORDER_NOW="2026-08-09T01:02:03Z" \
    run_cli meaning generate "$episode" \
      --source-ref "$source_ref" --span-start-line 1 --span-end-line 4 \
      --evaluator flight-recorder-meaning-evaluator \
      --model "meaning-$label" --max-cost-microusd 50000 --timeout 240 \
      --json >/dev/null 2>&1
}

build_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
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

test_killed_provider_leaves_durable_pending_without_recharge() {
  echo "test_killed_provider_leaves_durable_pending_without_recharge:"
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
directory = root / "value-compiler"
attempts_path = directory / "attempts.json"
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert stat.S_IMODE(attempts_path.stat().st_mode) == 0o600
ledger = json.loads(attempts_path.read_text())
assert set(ledger) == {"schema_version", "attempts"}
assert ledger["schema_version"] == 1
assert isinstance(ledger["attempts"], list) and len(ledger["attempts"]) <= 1000
assert any(
    item.get("episode_id") == episode and item.get("state") == "pending"
    for item in ledger["attempts"]
)
PY
  then
    pass "provider前pending予約はkill後も再課金を防ぐ"
  else
    cat "$first_err" "$retry_err" >&2
    fail "provider前pending予約はkill後も再課金を防ぐ"
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

main() {
  if ! build_fixture; then
    fail "Value Compiler fixtureを構築できる"
    echo
    echo "Result: $PASS passed, $FAIL failed"
    exit 1
  fi
  if [[ "${FLIGHT_RECORDER_TEST_VALUE_CONCURRENCY_ONLY:-0}" == "1" ]]; then
    test_concurrent_compile_reuses_reservation_without_blocking_inspect
  elif [[ "${FLIGHT_RECORDER_TEST_VALUE_ATTEMPTS_ONLY:-0}" == "1" ]]; then
    test_killed_provider_leaves_durable_pending_without_recharge
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
  else
    test_versioned_cards_are_grounded_bounded_and_idempotent
    test_wrong_axis_reference_fails_closed_without_storing_a_card
    test_forget_and_purge_cover_value_primitive_cards
    test_concurrent_compile_reuses_reservation_without_blocking_inspect
    test_killed_provider_leaves_durable_pending_without_recharge
    test_oversized_response_leaves_durable_failure_without_recharge
    test_directional_grounding_rejects_positive_from_unknown_outcome
    test_malformed_evaluator_fails_cleanly_and_closes_attempt
    test_rehashed_observation_tamper_fails_current_binding
  fi
  echo
  echo "Result: $PASS passed, $FAIL failed"
  [[ "$FAIL" -eq 0 ]]
}

main "$@"
