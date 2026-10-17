#!/usr/bin/env bash
# Auto-evaluation candidate selection, backoff and failure-reason contract tests.
#
# A run used to build the full ten-year report (every Episode Card and every
# relationship edge) just to pick at most a few Episodes, so its memory grew with
# the number of link edges, and failed attempts were re-opened one by one on every
# tick. These tests pin the replacement: bounded newest-first selection,
# exponential backoff after consecutive evaluator failures, and finite failure
# reasons that never carry evaluator output.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
TEST_ROOT="$(mktemp -d)" || exit 1
[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] || {
  echo "failed to create temporary directory" >&2
  exit 1
}
STATE="$TEST_ROOT/vault"
PASS=0
FAIL=0

cleanup() {
  [[ -n "$TEST_ROOT" && "$TEST_ROOT" != "/" && -d "$TEST_ROOT" ]] || return
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
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$STATE" "$CLI" "$@"
}

reset_auto_state() {
  rm -f "$STATE/auto-evaluation/attempts.json" "$STATE/auto-evaluation/status.json"
}

configure_auto() {
  run_cli auto-evaluation configure \
    --evaluator "$1" \
    --model evaluator-test-model \
    --policy-version default-v1 \
    --uncertainty-score-below 700 \
    --max-evaluations-per-run 2 \
    --max-cost-microusd-per-run 50000 \
    --json >/dev/null 2>&1
}

# Six dense groups whose 20 events all link (190 link edges each), plus thirty
# unrelated single events of which six carry a passing test.
init_dense_fixture() {
  local remote="$TEST_ROOT/remote.git"
  local recovery="$TEST_ROOT/recovery.agekey"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$recovery" >/dev/null 2>&1
  run_cli init \
    --remote "$remote" \
    --recovery-recipient \
    "$(PATH="$FAKE_BIN:$PATH" age-keygen -y "$recovery")" \
    >/dev/null 2>&1
  mkdir -p "$STATE/inbox"
  python3 - "$STATE/inbox/events.jsonl" <<'PY'
import datetime as dt
import json
import pathlib
import sys

now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def digest(number):
    return "sha256:" + f"{number:024x}"


events = []


def add(index, moment, workspace, branch, files, *, decision_bearing=False):
    events.append({
        "schema_version": 3,
        "event_id": f"52000000-0000-4000-8000-{index:012d}",
        "recorded_at": moment.isoformat().replace("+00:00", "Z"),
        "harness": "codex" if index % 2 else "claude-code",
        "source_event": "PostToolUse" if decision_bearing else "Stop",
        "event_kind": "tool.completed" if decision_bearing else "turn.completed",
        "session_id_hash": digest(5000 + index // 20),
        "turn_id_hash": None,
        "workspace_id": workspace,
        "model": "fixture-model",
        "permission_mode": None,
        "tool": "Bash" if decision_bearing else None,
        "metrics": None,
        "outcome": (
            {"status": "success", "exit_code": 0} if decision_bearing else None
        ),
        "operation_kind": "test" if decision_bearing else None,
        "relationship_context": {
            "task_id_hash": None,
            "task_source": None,
            "branch_or_worktree_id": branch,
            "changed_file_fingerprints": files,
            "changed_files_state": "complete" if files else "missing",
        },
    })


index = 0
for group in range(6):
    start = now - dt.timedelta(hours=2 * (group + 1))
    for member in range(20):
        index += 1
        add(
            index,
            start + dt.timedelta(seconds=5 * member),
            digest(group + 1),
            digest(100 + group),
            [digest(200 + group)],
        )
for single in range(30):
    index += 1
    add(
        index,
        now - dt.timedelta(hours=13, minutes=20 * single),
        digest(1000 + single),
        None,
        [],
        decision_bearing=single % 5 == 0,
    )
pathlib.Path(sys.argv[1]).write_text(
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

# Shared Python helpers for the in-process tests.
cat >"$TEST_ROOT/common.py" <<'PY'
import datetime as dt
import json
import pathlib

CANDIDATE_TYPES = {"test", "build", "lint", "git_commit", "pull_request"}


def candidate(card):
    confidence = card["confidence"]
    if confidence is not None and confidence["minimum_supporting_score"] >= 700:
        return False
    return card["event_count"] > 1 or any(
        fact["evidence_type"] in CANDIDATE_TYPES
        and fact["state"] in {"success", "failure"}
        for fact in card["deterministic_evidence"]
    )


def stamp(moment):
    return moment.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def status_of(root):
    return json.loads((pathlib.Path(root) / "auto-evaluation/status.json").read_text())


def attempts_of(root):
    path = pathlib.Path(root) / "auto-evaluation/attempts.json"
    if not path.exists():
        return []
    return json.loads(path.read_text())["attempts"]
PY

test_selection_matches_report_and_stays_bounded() {
  echo "test_selection_matches_report_and_stays_bounded:"
  local err="$TEST_ROOT/selection.err"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" \
    python3 - "$STATE" <<'PY' 2>"$err"
import pathlib
import sys
import tracemalloc

import reporting
from common import candidate
from reporting import report, select_episode_ids

root = pathlib.Path(sys.argv[1])
tracemalloc.start()
view = report(root, "3650d", "default-v1")
expected = [card["episode_id"] for card in view["cards"] if candidate(card)]
report_peak = tracemalloc.get_traced_memory()[1]
assert len(view["cards"]) == 36 and len(expected) == 12, (len(view["cards"]), len(expected))
del view


def card_parity(connection, policy):
    full = reporting._edges_by_episode(connection, "default-v1")
    count = 0
    for (episode_id,) in connection.execute(
        "SELECT episode_id FROM episodes WHERE policy_version = ?", ("default-v1",)
    ):
        expected, _ = reporting._episode_card(root, connection, policy, episode_id, full)
        stand_in = reporting._episode_edge_floor(connection, "default-v1", episode_id)
        actual, _ = reporting._episode_card(root, connection, policy, episode_id, stand_in)
        assert actual == expected, episode_id
        count += 1
    return count


# The weakest-score stand-in yields exactly the card that every edge would.
assert reporting._authenticated_query(root, "default-v1", card_parity) == 36

real_edges = reporting._edges_by_episode
reporting._edges_by_episode = lambda *_a, **_k: (_ for _ in ()).throw(
    AssertionError("selection must not materialize every relationship edge")
)
tracemalloc.reset_peak()
everything = select_episode_ids(root, "3650d", "default-v1", None, candidate, 1000)
tracemalloc.reset_peak()
newest = select_episode_ids(root, "3650d", "default-v1", None, candidate, 1)
newest_peak = tracemalloc.get_traced_memory()[1]
reporting._edges_by_episode = real_edges
tracemalloc.stop()

# The window is applied to an Episode's latest event, as report does.
for window in ("30d", "5h", "3h"):
    windowed = [
        card["episode_id"] for card in report(root, window, "default-v1")["cards"]
        if candidate(card)
    ]
    assert select_episode_ids(
        root, window, "default-v1", None, candidate, 1000
    ) == windowed, window
    # Groups start 2h apart and the singles are 13h old or more.
    assert len(windowed) == {"30d": 12, "5h": 2, "3h": 1}[window], (window, len(windowed))
assert everything == expected, "selection order differs from report order"
assert select_episode_ids(root, "3650d", "default-v1", None, candidate, 3) == expected[:3]
assert newest == expected[:1]
# Choosing one Episode builds one card, not 36 cards and 1,140 edges.
assert newest_peak * 3 < report_peak, (newest_peak, report_peak)
print("report_peak=%d selection_peak=%d" % (report_peak, newest_peak))
PY
  then
    pass "選別はreportと同じ新しい順・同じ集合を返し、全edgeを作らず1 Episode分のメモリに収まる"
  else
    cat "$err" >&2
    fail "選別はreportと同じ新しい順・同じ集合を返し、全edgeを作らず1 Episode分のメモリに収まる"
  fi
}

test_run_never_builds_the_full_report() {
  echo "test_run_never_builds_the_full_report:"
  reset_auto_state
  configure_auto flight-recorder-background-evaluator || {
    fail "自動評価を構成できる"
    return
  }
  local err="$TEST_ROOT/no-report.err"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" \
    FLIGHT_RECORDER_TEST_EVALUATOR_COST=12000 \
    python3 - "$STATE" <<'PY' 2>"$err"
import pathlib
import sys

import background_evaluation
import reporting

root = pathlib.Path(sys.argv[1])
reporting.report = lambda *_a, **_k: (_ for _ in ()).throw(
    AssertionError("an auto-evaluation run must not build the full report")
)
reporting._edges_by_episode = lambda *_a, **_k: (_ for _ in ()).throw(
    AssertionError("an auto-evaluation run must not load every edge")
)
result = background_evaluation.run(root)
assert result["state"] == "completed", result
assert result["evaluated_count"] == 2, result
# The budget is two evaluations; eight more candidates are visited as slack.
assert result["candidate_count"] == 10, result
assert result["measured_cost_microusd"] == 24000, result
PY
  then
    pass "自動評価の実行はreport()もedge全件の展開も使わず、予算内の件数だけ評価する"
  else
    cat "$err" >&2
    fail "自動評価の実行はreport()もedge全件の展開も使わず、予算内の件数だけ評価する"
  fi
}

test_backoff_grows_then_recovers() {
  echo "test_backoff_grows_then_recovers:"
  reset_auto_state
  configure_auto flight-recorder-background-evaluator || {
    fail "自動評価を構成できる"
    return
  }
  local err="$TEST_ROOT/backoff.err"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" \
    python3 - "$STATE" <<'PY' 2>"$err"
import datetime as dt
import os
import pathlib
import sys

import background_evaluation
import evaluation
import reporting
from chunk_rotation import parse_time
from common import attempts_of, stamp, status_of

root = pathlib.Path(sys.argv[1])
calls = []


def evaluator_failing(root, episode_id, policy_version, policy_path, *_rest,
                      trigger, remaining_cost_microusd, before_invoke):
    card = reporting.inspect_episode(root, episode_id, policy_version, policy_path)["card"]
    before_invoke(card)
    calls.append(episode_id)
    raise evaluation.EvaluatorFailure(
        "evaluator execution failed", "nonzero_exit",
        exit_code=1, claude_on_path=False,
    )


evaluation.evaluate = evaluator_failing
now = dt.datetime(2026, 10, 17, 12, 0, 0, tzinfo=dt.timezone.utc)
delays = []
for failure in range(1, 10):
    os.environ["FLIGHT_RECORDER_NOW"] = stamp(now)
    result = background_evaluation.run(root)
    assert result["state"] == "error", result
    assert result["failure_reason"] == "nonzero_exit", result
    status = status_of(root)
    assert status["consecutive_failures"] == failure, status
    assert status["exit_code"] == 1 and status["claude_on_path"] is False
    assert len(calls) == failure
    # Every reason field is finite; nothing from the evaluator is carried.
    assert set(status) <= {
        "schema_version", "state", "diagnostic_code", "attempt_count",
        "failure_reason", "exit_code", "claude_on_path", "consecutive_failures",
        "last_failure_at", "next_retry_at", "last_success_at",
    }, sorted(status)
    retry_at = parse_time(status["next_retry_at"])
    delays.append((retry_at - now).total_seconds())
    # Halfway into the backoff nothing is selected and nothing is invoked.
    os.environ["FLIGHT_RECORDER_NOW"] = stamp(now + (retry_at - now) / 2)
    waiting = background_evaluation.run(root)
    assert waiting["state"] == "backoff" and waiting["evaluated_count"] == 0
    assert len(calls) == failure
    now = retry_at + dt.timedelta(seconds=1)
assert all(later >= earlier for earlier, later in zip(delays, delays[1:])), delays
assert delays[0] <= 300 and delays[-1] >= 43200 and max(delays) <= 86400, delays
# Each failed attempt is remembered, so no episode is retried automatically.
assert len(attempts_of(root)) == 9
assert len({item["episode_id"] for item in attempts_of(root)}) == 9


def evaluator_working(root, episode_id, policy_version, policy_path, *_rest,
                      trigger, remaining_cost_microusd, before_invoke):
    card = reporting.inspect_episode(root, episode_id, policy_version, policy_path)["card"]
    before_invoke(card)
    return {"evaluation": {"measured_cost_microusd": 3}}


evaluation.evaluate = evaluator_working
os.environ["FLIGHT_RECORDER_NOW"] = stamp(now)
recovered = background_evaluation.run(root)
assert recovered["state"] == "completed" and recovered["evaluated_count"] >= 1, recovered
status = status_of(root)
for key in ("failure_reason", "exit_code", "claude_on_path",
            "consecutive_failures", "last_failure_at", "next_retry_at"):
    assert key not in status, (key, status)
assert status["last_success_at"] == stamp(now), status
print("delays_minutes=%s" % [round(delay / 60) for delay in delays])
PY
  then
    pass "連続失敗は指数的にbackoffし(上限24h)、成功した実行で失敗状態が消える"
  else
    cat "$err" >&2
    fail "連続失敗は指数的にbackoffし(上限24h)、成功した実行で失敗状態が消える"
  fi
}

test_a_success_earlier_in_the_run_restarts_the_failure_streak() {
  echo "test_a_success_earlier_in_the_run_restarts_the_failure_streak:"
  reset_auto_state
  configure_auto flight-recorder-background-evaluator || {
    fail "自動評価を構成できる"
    return
  }
  local err="$TEST_ROOT/streak.err"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" \
    python3 - "$STATE" <<'PY' 2>"$err"
import datetime as dt
import json
import os
import pathlib
import sys

import background_evaluation
import evaluation
import reporting
from common import stamp, status_of

root = pathlib.Path(sys.argv[1])
now = dt.datetime(2026, 10, 17, 12, 0, 0, tzinfo=dt.timezone.utc)
# A long failure streak recorded by an earlier run, whose retry time has passed.
earlier = {
    "schema_version": 1, "state": "error", "diagnostic_code": "evaluator_failed",
    "attempt_count": 0, "failure_reason": "nonzero_exit", "exit_code": 1,
    "consecutive_failures": 8, "last_failure_at": stamp(now - dt.timedelta(days=2)),
    "next_retry_at": stamp(now - dt.timedelta(hours=1)),
}
path = root / "auto-evaluation/status.json"
path.write_text(json.dumps(earlier, sort_keys=True), encoding="utf-8")
path.chmod(0o600)

calls = []


def succeeds_then_fails(root, episode_id, policy_version, policy_path, *_rest,
                        trigger, remaining_cost_microusd, before_invoke):
    card = reporting.inspect_episode(root, episode_id, policy_version, policy_path)["card"]
    before_invoke(card)
    calls.append(episode_id)
    if len(calls) == 1:
        return {"evaluation": {"measured_cost_microusd": 4}}
    raise evaluation.EvaluatorFailure("evaluator execution failed", "timeout")


evaluation.evaluate = succeeds_then_fails
os.environ["FLIGHT_RECORDER_NOW"] = stamp(now)
result = background_evaluation.run(root)
status = status_of(root)
assert result["state"] == "error" and result["evaluated_count"] == 1, result
# The success shows the evaluator works: the new failure is the first of a new
# streak, so the retry is minutes away rather than a day.
assert status["consecutive_failures"] == 1, status
assert status["failure_reason"] == "timeout" and "exit_code" not in status, status
assert status["last_success_at"] == stamp(now), status
delay = (dt.datetime.fromisoformat(status["next_retry_at"].replace("Z", "+00:00")) - now).total_seconds()
assert 150 <= delay <= 300, delay
PY
  then
    pass "同じ実行内で評価が成功した後の失敗は、連続失敗数を1から数え直す"
  else
    cat "$err" >&2
    fail "同じ実行内で評価が成功した後の失敗は、連続失敗数を1から数え直す"
  fi
}

test_failure_before_the_model_can_run_releases_the_reservation() {
  echo "test_failure_before_the_model_can_run_releases_the_reservation:"
  reset_auto_state
  mkdir -p "$TEST_ROOT/bin"
  printf '#!/nonexistent/interpreter\n' >"$TEST_ROOT/bin/flight-recorder-broken-evaluator"
  chmod 0755 "$TEST_ROOT/bin/flight-recorder-broken-evaluator"
  configure_auto flight-recorder-broken-evaluator || {
    fail "launch失敗するevaluatorを構成できる"
    return
  }
  local output="$TEST_ROOT/launch.json"
  PATH="$TEST_ROOT/bin:$PATH" run_cli auto-evaluation run --json \
    >"$output" 2>"$TEST_ROOT/launch.err"
  if python3 - "$output" "$STATE" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
status = json.loads((root / "auto-evaluation/status.json").read_text())
attempts = root / "auto-evaluation/attempts.json"
# The evaluator never ran, so nothing says the episode is hard to evaluate:
# the reservation is released instead of being kept as a failed attempt.
assert value["state"] == "error" and value["failure_reason"] == "launch_failed", value
assert status["failure_reason"] == "launch_failed"
assert "exit_code" not in status
assert status["attempt_count"] == 0
assert not attempts.exists() or json.loads(attempts.read_text())["attempts"] == []
PY
  then
    pass "モデルを呼べない失敗(launch失敗)はreservationを解放し、failed台帳に積まない"
  else
    cat "$TEST_ROOT/launch.err" >&2
    fail "モデルを呼べない失敗(launch失敗)はreservationを解放し、failed台帳に積まない"
  fi
}

echo "=== Flight Recorder Auto-Evaluation Selection Tests ==="
if ! init_dense_fixture; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_selection_matches_report_and_stays_bounded
test_run_never_builds_the_full_report
test_backoff_grows_then_recovers
test_a_success_earlier_in_the_run_restarts_the_failure_streak
test_failure_before_the_model_can_run_releases_the_reservation

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
