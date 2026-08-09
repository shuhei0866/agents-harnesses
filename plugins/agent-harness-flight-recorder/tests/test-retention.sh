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
paths += sorted((root / "meaning-cards").glob("*.json"))
paths += sorted((root / "value-primitive-cards").glob("*.json"))
paths += sorted((root / "value-compiler" / "prepared").glob("*.json"))
attempts = root / "value-compiler" / "attempts.json"
if attempts.exists():
    paths.append(attempts)
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

meaning_card_count() {
  local state="$1" episode="$2"
  python3 - "$state" "$episode" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1]) / "meaning-cards"
count = 0
if directory.is_dir():
    for path in directory.glob("*.json"):
        value = json.loads(path.read_text(encoding="utf-8"))
        count += value.get("episode_id") == sys.argv[2]
print(count)
PY
}

generate_meaning_card() {
  local state="$1" episode="$2" label="$3"
  local source="$TEST_ROOT/$label-source.jsonl"
  local registered="$TEST_ROOT/$label-source-register.json"
  local source_ref
  python3 - "$source" "$label" <<'PY'
import json
import pathlib
import sys

path, label = sys.argv[1:]
rows = [
    {
        "type": "event_msg",
        "payload": {"turn_id": label, "type": "task_started"},
    },
    {
        "type": "response_item",
        "payload": {
            "role": "user",
            "type": "message",
            "content": [{"type": "input_text", "text": f"Diagnose {label}."}],
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "assistant",
            "type": "message",
            "content": [
                {"type": "output_text", "text": f"Completed {label}."}
            ],
        },
    },
    {
        "type": "event_msg",
        "payload": {"turn_id": label, "type": "task_complete"},
    },
]
pathlib.Path(path).write_text(
    "".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        for row in rows
    ),
    encoding="utf-8",
)
PY
  run_cli "$state" source register \
    --adapter codex --path "$source" --json >"$registered" 2>/dev/null \
    || return 1
  source_ref="$(
    python3 - "$registered" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  FLIGHT_RECORDER_NOW="2026-07-31T02:03:04Z" \
    run_cli "$state" meaning generate "$episode" \
      --source-ref "$source_ref" \
      --span-start-line 1 --span-end-line 4 \
      --evaluator flight-recorder-meaning-evaluator \
      --model "meaning-$label" \
      --max-cost-microusd 50000 --timeout 240 --json \
      >/dev/null 2>&1
}

write_attempt_ledger() {
  local state="$1" target_episode="$2" unrelated_episode="$3"
  mkdir -p "$state/auto-evaluation"
  chmod 700 "$state/auto-evaluation"
  python3 - "$state/auto-evaluation/attempts.json" \
    "$target_episode" "$unrelated_episode" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
attempts = [
    {
        "fingerprint": "sha256:" + "1" * 64,
        "episode_id": sys.argv[2],
        "state": "pending",
    },
    {
        "fingerprint": "sha256:" + "2" * 64,
        "episode_id": sys.argv[3],
        "state": "failed",
    },
]
value = {
    "schema_version": 2,
    "attempts": sorted(attempts, key=lambda item: item["fingerprint"]),
}
path.write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
path.chmod(0o600)
PY
}

write_receipt_attempt_ledger() {
  local state="$1" target_episode="$2" unrelated_episode="$3"
  local source="$TEST_ROOT/receipt-attempt-source.jsonl"
  local registered="$TEST_ROOT/receipt-attempt-source-register.json"
  local source_ref
  python3 - "$source" <<'PY'
import json
import pathlib
import sys

rows = [
    {
        "type": "event_msg",
        "payload": {"turn_id": "receipt-attempt", "type": "task_started"},
    },
    {
        "type": "response_item",
        "payload": {
            "role": "user",
            "type": "message",
            "content": [{"type": "input_text", "text": "Inspect purge."}],
        },
    },
    {
        "type": "response_item",
        "payload": {
            "role": "assistant",
            "type": "message",
            "content": [{"type": "output_text", "text": "Purge inspected."}],
        },
    },
    {
        "type": "event_msg",
        "payload": {"turn_id": "receipt-attempt", "type": "task_complete"},
    },
]
pathlib.Path(sys.argv[1]).write_text(
    "".join(
        json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
        for row in rows
    ),
    encoding="utf-8",
)
PY
  run_cli "$state" source register \
    --adapter codex --path "$source" --json >"$registered" 2>/dev/null \
    || return 1
  source_ref="$(
    python3 - "$registered" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["source_ref"])
PY
  )"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$target_episode" "$unrelated_episode" \
      "$source_ref" "$PLUGIN_DIR/rubrics/semantic-receipt-v1.json" <<'PY'
import pathlib
import sys

from chunk_rotation import canonical_json, safe_subdirectory
from reporting import inspect_episode
from semantic_receipts import _prepare_receipt

root = pathlib.Path(sys.argv[1])
episode_ids = sys.argv[2:4]
source_ref = sys.argv[4]
rubric = pathlib.Path(sys.argv[5])
items = []
for index, episode_id in enumerate(episode_ids, start=3):
    snapshot = inspect_episode(root, episode_id, "default-v1", None)
    prepared = _prepare_receipt(
        root,
        snapshot,
        episode_id,
        source_ref,
        start_line=1,
        end_line=4,
        evaluator="flight-recorder-auto-semantic-evaluator",
        model=f"purge-prepared-{index}",
        rubric_path=rubric,
        timeout_seconds=60,
        remaining_cost_microusd=50000,
    )
    items.append({
        "fingerprint": "sha256:" + str(index) * 64,
        "state": "prepared",
        "event_id": snapshot["card"]["source_event_ids"][0],
        "episode_id": episode_id,
        "prepared": prepared,
    })
directory = safe_subdirectory(root, "receipt-automation")
path = directory / "attempts.json"
path.write_bytes(canonical_json({"schema_version": 1, "items": items}) + b"\n")
path.chmod(0o600)
directory.chmod(0o700)
PY
}

write_value_artifacts() {
  local state="$1" target_episode="$2" unrelated_episode="$3"
  generate_meaning_card "$state" "$target_episode" value-retention-target \
    || return 1
  generate_meaning_card \
    "$state" "$unrelated_episode" value-retention-unrelated || return 1
  FLIGHT_RECORDER_TEST_VALUE_COST=6000 \
    run_cli "$state" value compile \
      --evaluator flight-recorder-value-evaluator \
      --model value-retention-stored \
      --max-episodes 2 --max-cost-microusd 12000 --json \
      >/dev/null 2>&1 || return 1
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$target_episode" "$unrelated_episode" <<'PY'
import pathlib
import sys
import time

import value_compiler
from evaluation import _executable_identity, _invoke
from vault import vault_lock

root = pathlib.Path(sys.argv[1])
episode_ids = set(sys.argv[2:4])
model = "value-retention-prepared"
evaluator_path, evaluator_sha256 = _executable_identity(
    "flight-recorder-value-evaluator"
)
with vault_lock(root):
    packets = value_compiler._authenticated_packets(
        root, "default-v1", None, episode_ids
    )
assert {episode["episode_id"] for episode, _packet in packets} == episode_ids
prepared_records = []
attempts = []
for episode, packet in packets:
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
        episode,
        packet,
        primitives,
        model,
        evaluator_path,
        evaluator_sha256,
        "default-v1",
        cost,
        latency_ms,
    )
    fingerprint = value_compiler._attempt_fingerprint(
        packet["packet_sha256"], model, evaluator_sha256, "default-v1"
    )
    prepared_records.append({
        "schema_version": 1,
        "contract_version": value_compiler.PREPARED_CONTRACT,
        "fingerprint": fingerprint,
        "episode_id": episode["episode_id"],
        "packet_sha256": packet["packet_sha256"],
        "evaluator_model": model,
        "evaluator_adapter_sha256": evaluator_sha256,
        "policy_version": "default-v1",
        "card": card,
    })
    attempt = value_compiler._new_attempt(
        episode["episode_id"],
        packet["packet_sha256"],
        model,
        evaluator_sha256,
        "default-v1",
    )
    attempt["state"] = "prepared"
    attempts.append(attempt)
with vault_lock(root):
    for prepared in prepared_records:
        value_compiler._store_prepared(root, prepared)
    value_compiler._store_attempts(
        root,
        {
            "schema_version": 1,
            "attempts": sorted(
                attempts, key=lambda item: item["fingerprint"]
            ),
        },
    )
PY
}

value_artifact_manifest() {
  python3 - "$1" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = sorted((root / "value-primitive-cards").glob("*.json"))
paths += sorted((root / "value-compiler" / "prepared").glob("*.json"))
paths.append(root / "value-compiler" / "attempts.json")
for path in paths:
    print(path.relative_to(root), hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

value_episode_manifest() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
for label, directory in (
    ("card", root / "value-primitive-cards"),
    ("prepared", root / "value-compiler" / "prepared"),
):
    for path in sorted(directory.glob("*.json")):
        value = json.loads(path.read_text())
        if value["episode_id"] == episode:
            print(label, path.name, hashlib.sha256(path.read_bytes()).hexdigest())
attempts = json.loads(
    (root / "value-compiler" / "attempts.json").read_text()
)["attempts"]
for item in attempts:
    if item["episode_id"] == episode:
        canonical = json.dumps(item, sort_keys=True, separators=(",", ":")).encode()
        print("attempt", item["fingerprint"], hashlib.sha256(canonical).hexdigest())
PY
}

prepared_directory_manifest() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import stat
import sys

directory = pathlib.Path(sys.argv[1]) / "value-compiler" / "prepared"
for path in sorted(directory.iterdir()):
    metadata = path.lstat()
    print(
        path.name,
        stat.S_IMODE(metadata.st_mode),
        hashlib.sha256(path.read_bytes()).hexdigest(),
    )
PY
}

materialize_prepared_receipts() {
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

from semantic_receipts import _store_prepared_receipt

root = pathlib.Path(sys.argv[1])
ledger = json.loads(
    (root / "receipt-automation" / "attempts.json").read_text()
)
for item in ledger["items"]:
    _store_prepared_receipt(root, item["prepared"])
PY
}

vault_byte_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root)
    if ".git" in relative.parts or path.name.endswith(".lock"):
        continue
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if stat.S_ISREG(metadata.st_mode):
        print("F", relative, mode, hashlib.sha256(path.read_bytes()).hexdigest())
    elif stat.S_ISLNK(metadata.st_mode):
        print("L", relative, mode, os.readlink(path))
PY
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
  generate_meaning_card "$state" "$episode" purge-preview || {
    fail "purge preview対象episodeのMeaning Cardを作成できる"
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
    && grep -Fq 'Local Meaning Card records: 1' "$output" \
    && [[ "$(meaning_card_count "$state" "$episode")" == "1" ]] \
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
  local episode unrelated_episode target_path unrelated_path
  local target_cache unrelated_cache
  local history_objects="$base/remote-history-objects.txt"
  init_fixture "$base" || {
    fail "purge apply fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  unrelated_episode="$(
    db_value_for_event "$db" "$UNRELATED_EVENT" episode_id
  )"
  generate_meaning_card "$state" "$episode" purge-apply-target || {
    fail "purge apply対象episodeのMeaning Cardを作成できる"
    return
  }
  generate_meaning_card \
    "$state" "$unrelated_episode" purge-apply-unrelated || {
      fail "purge apply非対象episodeのMeaning Cardを作成できる"
      return
  }
  write_attempt_ledger "$state" "$episode" "$unrelated_episode"
  write_receipt_attempt_ledger \
    "$state" "$episode" "$unrelated_episode" || {
      fail "purge apply用prepared Receipt attemptを作成できる"
      return
    }
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
    && [[ "$(meaning_card_count "$state" "$episode")" == "0" \
      && "$(meaning_card_count "$state" "$unrelated_episode")" == "1" ]] \
    && ! grep -Fq " $target_path" "$history_objects" \
    && grep -Fq " $unrelated_path" "$history_objects" \
    && python3 - "$db" "$TARGET_EVENT" "$UNRELATED_EVENT" \
      "$state/auto-evaluation/attempts.json" \
      "$state/receipt-automation/attempts.json" \
      "$episode" "$unrelated_episode" <<'PY'
import json
import pathlib
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
evaluation_items = json.loads(pathlib.Path(sys.argv[4]).read_text())["attempts"]
evaluation_episodes = {item["episode_id"] for item in evaluation_items}
receipt_items = json.loads(pathlib.Path(sys.argv[5]).read_text())["items"]
receipt_episodes = {item.get("episode_id") for item in receipt_items}
assert sys.argv[6] not in evaluation_episodes
assert evaluation_episodes == {sys.argv[7]}
assert sys.argv[6] not in receipt_episodes
assert receipt_episodes == {sys.argv[7]}
PY
  then
    pass "purgeは対象chunk・prepared attemptを除去しunrelated状態を保持する"
  else
    fail "purgeは対象chunk・prepared attemptを除去しunrelated状態を保持する"
  fi
}

test_purge_push_rejection_restores_retryable_local_state() {
  echo "test_purge_push_rejection_restores_retryable_local_state:"
  local base="$TEST_ROOT/purge-push-rejection"
  local state="$base/vault"
  local remote="$base/remote.git" db="$state/index/vault.sqlite"
  local episode unrelated_episode target_path target_cache
  local before_head before_remote before_source before_files before_attempts
  local before_receipt_attempts before_value before_unrelated_value
  init_fixture "$base" || {
    fail "push rejection fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  unrelated_episode="$(
    db_value_for_event "$db" "$UNRELATED_EVENT" episode_id
  )"
  write_attempt_ledger "$state" "$episode" "$unrelated_episode"
  write_receipt_attempt_ledger \
    "$state" "$episode" "$unrelated_episode" || {
      fail "push rejection用prepared Receipt attemptを作成できる"
      return
    }
  run_cli "$state" evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-test-model --json >/dev/null 2>&1 || {
      fail "push rejection対象episodeのevaluationを作成できる"
      return
    }
  write_value_artifacts "$state" "$episode" "$unrelated_episode" || {
    fail "push rejection用Value Card・prepared・attemptを作成できる"
    return
  }
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  target_cache="$(db_value_for_event "$db" "$TARGET_EVENT" cache_path)"
  before_head="$(git -C "$state" rev-parse HEAD)"
  before_remote="$(git --git-dir="$remote" rev-parse main)"
  before_source="$(source_snapshot "$db")"
  before_files="$(evidence_file_snapshot "$state")"
  before_attempts="$(
    shasum -a 256 "$state/auto-evaluation/attempts.json"
  )"
  before_receipt_attempts="$(
    shasum -a 256 "$state/receipt-automation/attempts.json"
  )"
  before_value="$(value_artifact_manifest "$state")"
  before_unrelated_value="$(
    value_episode_manifest "$state" "$unrelated_episode"
  )"

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
    || "$before_attempts" != "$(
      shasum -a 256 "$state/auto-evaluation/attempts.json"
    )" \
    || "$before_receipt_attempts" != "$(
      shasum -a 256 "$state/receipt-automation/attempts.json"
    )" \
    || "$before_value" != "$(value_artifact_manifest "$state")" \
    || ! -f "$state/$target_path" \
    || ! -f "$state/$target_cache" \
    || "$(meaning_card_count "$state" "$episode")" != "1" ]] \
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
      && "$(evaluation_count "$state")" == "0" \
      && "$(meaning_card_count "$state" "$episode")" == "0" ]] \
    && [[ "$before_unrelated_value" == "$(
      value_episode_manifest "$state" "$unrelated_episode"
    )" ]] \
    && ! git --git-dir="$remote" cat-file -e \
      "main:$target_path" 2>/dev/null \
    && python3 - "$state/auto-evaluation/attempts.json" \
      "$state/receipt-automation/attempts.json" \
      "$state" "$episode" "$unrelated_episode" <<'PY'
import json
import pathlib
import sys

evaluation_items = json.loads(pathlib.Path(sys.argv[1]).read_text())["attempts"]
evaluation_episodes = {item["episode_id"] for item in evaluation_items}
receipt_items = json.loads(pathlib.Path(sys.argv[2]).read_text())["items"]
receipt_episodes = {item.get("episode_id") for item in receipt_items}
root = pathlib.Path(sys.argv[3])
target, unrelated = sys.argv[4:6]
assert target not in evaluation_episodes
assert evaluation_episodes == {unrelated}
assert target not in receipt_episodes
assert receipt_episodes == {unrelated}
cards = [
    json.loads(path.read_text())
    for path in (root / "value-primitive-cards").glob("*.json")
]
prepared = [
    json.loads(path.read_text())
    for path in (root / "value-compiler" / "prepared").glob("*.json")
]
attempts = json.loads(
    (root / "value-compiler" / "attempts.json").read_text()
)["attempts"]
assert cards and {item["episode_id"] for item in cards} == {unrelated}
assert prepared and {item["episode_id"] for item in prepared} == {unrelated}
assert attempts and {item["episode_id"] for item in attempts} == {unrelated}
PY
  then
    pass "push拒否時はValue artifactsもbyte-exact復元し成功時だけ対象を除く"
  else
    fail "push拒否時はValue artifactsもbyte-exact復元し成功時だけ対象を除く"
  fi
}

test_invalid_attempt_ledger_blocks_purge_before_rewrite() {
  echo "test_invalid_attempt_ledger_blocks_purge_before_rewrite:"
  local base="$TEST_ROOT/purge-invalid-attempts"
  local state="$base/vault"
  local remote="$base/remote.git" db="$state/index/vault.sqlite"
  local episode target_path before_head before_remote before_source before_files
  init_fixture "$base" || {
    fail "invalid attempt ledger fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  mkdir -p "$state/auto-evaluation"
  chmod 700 "$state/auto-evaluation"
  printf '%s\n' '{"schema_version":2,"attempts":"broken"}' \
    >"$state/auto-evaluation/attempts.json"
  chmod 600 "$state/auto-evaluation/attempts.json"
  before_head="$(git -C "$state" rev-parse HEAD)"
  before_remote="$(git --git-dir="$remote" rev-parse main)"
  before_source="$(source_snapshot "$db")"
  before_files="$(evidence_file_snapshot "$state")"

  if run_cli "$state" purge "$episode" --apply \
    >"$base/invalid.out" 2>"$base/invalid.err"; then
    fail "invalid attempt ledgerを持つpurgeを拒否する"
  elif [[ "$before_head" == "$(git -C "$state" rev-parse HEAD)" \
    && "$before_remote" == "$(git --git-dir="$remote" rev-parse main)" \
    && "$before_source" == "$(source_snapshot "$db")" \
    && "$before_files" == "$(evidence_file_snapshot "$state")" \
    && -f "$state/$target_path" ]] \
    && ! grep -q "Traceback" "$base/invalid.err"; then
    pass "invalid attempt ledgerを履歴rewrite前に拒否する"
  else
    fail "invalid attempt ledgerを履歴rewrite前に拒否する"
  fi
}

test_purge_dry_run_does_not_recover_prepared_temp() {
  echo "test_purge_dry_run_does_not_recover_prepared_temp:"
  local base="$TEST_ROOT/purge-cycle8-read-only"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local episode unrelated_episode before after attempts_before
  init_fixture "$base" || {
    fail "cycle8 read-only purge fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  unrelated_episode="$(
    db_value_for_event "$db" "$UNRELATED_EVENT" episode_id
  )"
  write_value_artifacts "$state" "$episode" "$unrelated_episode" || {
    fail "cycle8 read-only用Value preparedを作成できる"
    return
  }
  python3 - "$state" "$episode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
for path in (root / "value-compiler" / "prepared").glob("*.json"):
    value = json.loads(path.read_text())
    if value["episode_id"] == episode:
        path.rename(path.with_name(f".{path.name}.cycle8-read-only"))
        break
else:
    raise AssertionError("target prepared record not found")
PY
  before="$(prepared_directory_manifest "$state")"
  attempts_before="$(shasum -a 256 "$state/value-compiler/attempts.json")"
  if run_cli "$state" purge "$episode" \
      >"$base/preview.txt" 2>"$base/preview.err"; then
    after="$(prepared_directory_manifest "$state")"
    if [[ "$before" == "$after" \
      && "$attempts_before" == "$(
        shasum -a 256 "$state/value-compiler/attempts.json"
      )" ]] \
      && find "$state/value-compiler/prepared" -type f \
        -name '.*.json.cycle8-read-only' -print -quit | grep -q .; then
      pass "purge dry-runはcomplete prepared tempを回復・変更しない"
    else
      fail "purge dry-runはcomplete prepared tempを回復・変更しない"
    fi
  else
    cat "$base/preview.err" >&2
    fail "purge dry-runはcomplete prepared tempを回復・変更しない"
  fi
}

test_purge_unlink_failure_restores_complete_local_state() {
  echo "test_purge_unlink_failure_restores_complete_local_state:"
  local base="$TEST_ROOT/purge-cycle9-unlink-failure"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode unrelated_episode target_path target_card
  local before_files before_head before_remote before_refs
  init_fixture "$base" || {
    fail "cycle9 purge rollback fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  unrelated_episode="$(
    db_value_for_event "$db" "$UNRELATED_EVENT" episode_id
  )"
  write_attempt_ledger "$state" "$episode" "$unrelated_episode"
  write_receipt_attempt_ledger \
    "$state" "$episode" "$unrelated_episode" || {
      fail "cycle9 receipt attempt fixtureを作成できる"
      return
    }
  run_cli "$state" evaluate "$episode" \
    --evaluator flight-recorder-evaluator \
    --model evaluator-cycle9-rollback --json >/dev/null 2>&1 || {
      fail "cycle9 evaluation fixtureを作成できる"
      return
    }
  write_value_artifacts "$state" "$episode" "$unrelated_episode" || {
    fail "cycle9 Value artifacts fixtureを作成できる"
    return
  }
  materialize_prepared_receipts "$state" || {
    fail "cycle9 stored Receipt fixtureを作成できる"
    return
  }
  # Preserve an unrelated forgotten marker and a valid pending-sync record so
  # rollback must restore both absence/presence and exact bytes.
  run_cli "$state" forget "$unrelated_episode" >/dev/null 2>&1 || {
    fail "cycle9 forgotten-state fixtureを作成できる"
    return
  }
  target_path="$(db_value_for_event "$db" "$TARGET_EVENT" source_path)"
  mkdir -p "$state/queue"
  chmod 700 "$state/queue"
  python3 - "$state/queue/pending-sync.json" "$target_path" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = {
    "schema_version": 1,
    "artifact_paths": [sys.argv[2]],
    "fixture_sentinel": "cycle9-byte-exact",
}
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
path.chmod(0o600)
PY
  target_card="$(python3 - "$state" "$episode" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in (root / "value-primitive-cards").glob("*.json"):
    value = json.loads(path.read_text())
    if value["episode_id"] == sys.argv[2]:
        print(path)
        break
else:
    raise AssertionError("target Value Card not found")
PY
)"
  before_files="$(vault_byte_snapshot "$state")"
  before_head="$(git -C "$state" rev-parse HEAD)"
  before_remote="$(git --git-dir="$remote" rev-parse main)"
  before_refs="$(
    git -C "$state" for-each-ref --format='%(refname) %(objectname)'
  )"

  if ! PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$target_card" <<'PY'
import pathlib
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
target = pathlib.Path(sys.argv[3])
original = pathlib.Path.unlink


def injected(path, *args, **kwargs):
    if path == target:
        raise OSError("fixture Value artifact unlink failure")
    return original(path, *args, **kwargs)


pathlib.Path.unlink = injected
try:
    try:
        retention.purge(root, episode, None, None, apply=True)
    except VaultError:
        pass
    else:
        raise AssertionError("injected purge unexpectedly succeeded")
finally:
    pathlib.Path.unlink = original
PY
  then
    fail "cycle9 unlink failureを注入できる"
    return
  fi

  if [[ "$before_remote" == "$(git --git-dir="$remote" rev-parse main)" \
    && "$before_head" == "$(git -C "$state" rev-parse HEAD)" \
    && "$before_refs" == "$(
      git -C "$state" for-each-ref --format='%(refname) %(objectname)'
    )" \
    && "$before_files" == "$(vault_byte_snapshot "$state")" ]]; then
    pass "push前unlink失敗でhistoryと全local stateをbyte-exact復元する"
  else
    fail "push前unlink失敗でhistoryと全local stateをbyte-exact復元する"
  fi
}

echo "=== Flight Recorder Retention Tests ==="
if [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE7_ONLY:-0}" == "1" ]]; then
  test_purge_push_rejection_restores_retryable_local_state
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE8_ONLY:-0}" == "1" ]]; then
  test_purge_dry_run_does_not_recover_prepared_temp
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE9_ONLY:-0}" == "1" ]]; then
  test_purge_unlink_failure_restores_complete_local_state
else
  test_forget_preserves_source_and_survives_rebuild
  test_dangling_forget_marker_fails_closed
  test_purge_dry_run_previews_scope_without_rewriting_history
  test_purge_apply_removes_target_history_and_keeps_unrelated_chunk
  test_purge_push_rejection_restores_retryable_local_state
  test_invalid_attempt_ledger_blocks_purge_before_rewrite
  test_purge_dry_run_does_not_recover_prepared_temp
  test_purge_unlink_failure_restores_complete_local_state
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
