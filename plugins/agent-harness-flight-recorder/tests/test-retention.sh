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
import json
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
        raw = path.read_bytes()
        if relative.as_posix() == "index/index-seal.json":
            value = json.loads(raw)
            value.pop("issued_at", None)
            value.pop("integrity", None)
            database = value.get("database", {})
            database.pop("inode", None)
            database.pop("mtime_ns", None)
            raw = json.dumps(
                value, sort_keys=True, separators=(",", ":")
            ).encode()
        print("F", relative, mode, hashlib.sha256(raw).hexdigest())
    elif stat.S_ISLNK(metadata.st_mode):
        print("L", relative, mode, os.readlink(path))
PY
}

write_purge_recovery_marker() {
  local state="$1" episode="$2" old_oid="$3" new_oid="$4"
  mkdir -p "$state/index"
  chmod 700 "$state/index"
  python3 - \
    "$state/index/purge-recovery.json" "$episode" "$old_oid" "$new_oid" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = {
    "schema_version": 1,
    "contract_version": "purge-cleanup-recovery-v1",
    "state": "push_pending",
    "episode_id": sys.argv[2],
    "policy_version": "default-v1",
    "old_remote_oid": sys.argv[3],
    "new_rewritten_oid": sys.argv[4],
}
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
path.chmod(0o600)
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
    pass "push前unlink失敗でhistoryと全local stateを復元しsealを再発行する"
  else
    printf '%s\n' "$before_files" >"$base/before-files.snapshot"
    vault_byte_snapshot "$state" >"$base/after-files.snapshot"
    diff -u "$base/before-files.snapshot" "$base/after-files.snapshot" >&2 || true
    fail "push前unlink失敗でhistoryと全local stateを復元しsealを再発行する"
  fi
}

test_rollback_attempts_exact_refs_after_restore_history_failure() {
  echo "test_rollback_attempts_exact_refs_after_restore_history_failure:"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$TEST_ROOT" <<'PY'
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
events = []
retention._original_refs = lambda _root: ["refs/original/refs/heads/main"]


def broken_restore_history(_root):
    events.append("restore-history")
    raise RuntimeError("fixture restore-history failure")


def restore_refs(_root, _snapshot):
    events.append("restore-refs")


def restore_files(_snapshots):
    events.append("restore-files")
    return []


def restore_value(_root, _snapshot):
    events.append("restore-value-attempts")


def restore_evaluation(_root, _snapshot):
    events.append("restore-evaluation-attempts")


def restore_receipt(_root, _snapshot):
    events.append("restore-receipt-attempts")


retention._restore_history = broken_restore_history
retention._restore_ref_snapshot = restore_refs
retention._restore_local_file_snapshots = restore_files
retention.restore_value_attempts = restore_value
retention.restore_attempts = restore_evaluation
retention.restore_receipt_attempts = restore_receipt
retention._remote_main_oid = lambda _root: "a" * 40
retention._cleanup_original_history = lambda _root: events.append("cleanup")
errors = retention._rollback_purge_state(
    root,
    refs={"refs/heads/main": "a" * 40},
    remote_main_oid="a" * 40,
    files=[],
    index_projection_files=[],
    value_attempts=b"value",
    evaluation_attempts=b"evaluation",
    receipt_attempts=b"receipt",
)
assert errors
assert events[:2] == ["restore-history", "restore-refs"], events
assert {
    "restore-files",
    "restore-value-attempts",
    "restore-evaluation-attempts",
    "restore-receipt-attempts",
}.issubset(events)
PY
  then
    pass "_restore_history失敗後もexact refsと全artifact/ledger復元を試す"
  else
    fail "_restore_history失敗後もexact refsと全artifact/ledger復元を試す"
  fi
}

test_incomplete_ref_rollback_preserves_original_history() {
  echo "test_incomplete_ref_rollback_preserves_original_history:"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$TEST_ROOT" <<'PY'
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
events = []
retention._original_refs = lambda _root: []


def broken_refs(_root, _snapshot):
    events.append("restore-refs")
    raise RuntimeError("fixture exact refs failure")


retention._restore_ref_snapshot = broken_refs
retention._restore_local_file_snapshots = lambda _snapshots: []
retention.restore_value_attempts = lambda _root, _snapshot: None
retention.restore_attempts = lambda _root, _snapshot: None
retention.restore_receipt_attempts = lambda _root, _snapshot: None
retention._remote_main_oid = lambda _root: "a" * 40
retention._cleanup_original_history = lambda _root: events.append("cleanup")
errors = retention._rollback_purge_state(
    root,
    refs={"refs/heads/main": "a" * 40},
    remote_main_oid="a" * 40,
    files=[],
    index_projection_files=[],
    value_attempts=None,
    evaluation_attempts=None,
    receipt_attempts=None,
)
assert errors
assert "restore-refs" in events
assert "cleanup" not in events, events
PY
  then
    pass "exact refs/remote復元失敗時はrefs/originalをcleanupしない"
  else
    fail "exact refs/remote復元失敗時はrefs/originalをcleanupしない"
  fi
}

test_cli_reports_incomplete_rollback_with_original_context() {
  echo "test_cli_reports_incomplete_rollback_with_original_context:"
  local base="$TEST_ROOT/purge-cycle10-incomplete"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local episode err="$base/incomplete.err" status
  init_fixture "$base" || {
    fail "cycle10 incomplete rollback fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" 2>"$err" <<'PY'
import pathlib
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
original_remove = retention._remove_local_derivatives


def fail_after_rewrite(root, scope, *, apply=True):
    if apply:
        raise VaultError("fixture original mutation failure")
    return original_remove(root, scope, apply=apply)


retention._remove_local_derivatives = fail_after_rewrite
retention._restore_history = lambda _root: (_ for _ in ()).throw(
    VaultError("fixture restore history failure")
)
retention._restore_ref_snapshot = lambda _root, _snapshot: (
    (_ for _ in ()).throw(VaultError("fixture exact refs failure"))
)
try:
    retention.purge(root, episode, None, None, apply=True)
except VaultError as error:
    print(f"flight-recorder: {error}", file=sys.stderr)
    raise SystemExit(1)
raise AssertionError("injected rollback unexpectedly succeeded")
PY
  status=$?
  if [[ "$status" -ne 0 ]] \
    && grep -Eiq 'rollback incomplete|rollback.*incomplete' "$err" \
    && grep -Fq 'fixture original mutation failure' "$err" \
    && ! grep -q 'Traceback' "$err"; then
    pass "rollback incompleteを元例外文脈付きでCLIへ有限表示する"
  else
    fail "rollback incompleteを元例外文脈付きでCLIへ有限表示する"
  fi
}

test_post_push_cleanup_failure_keeps_remote_commit_point() {
  echo "test_post_push_cleanup_failure_keeps_remote_commit_point:"
  local base="$TEST_ROOT/purge-cycle10-post-push"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode original_remote result="$base/result.json"
  init_fixture "$base" || {
    fail "cycle10 post-push fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  original_remote="$(git --git-dir="$remote" rev-parse main)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$result" <<'PY'
import json
import pathlib
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
result = pathlib.Path(sys.argv[3])
rollback_calls = 0
original_rollback = retention._rollback_purge_state


def counted_rollback(*args, **kwargs):
    global rollback_calls
    rollback_calls += 1
    return original_rollback(*args, **kwargs)


def broken_cleanup(_root):
    raise VaultError("fixture cleanup failure")


retention._rollback_purge_state = counted_rollback
retention._cleanup_original_history = broken_cleanup
try:
    retention.purge(root, episode, None, None, apply=True)
except VaultError as error:
    result.write_text(json.dumps({
        "error": str(error),
        "rollback_calls": rollback_calls,
    }))
else:
    raise AssertionError("cleanup failure unexpectedly succeeded")
PY
  if python3 - "$state" "$remote" "$original_remote" "$result" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
remote = pathlib.Path(sys.argv[2])
original_remote = sys.argv[3]
result = json.loads(pathlib.Path(sys.argv[4]).read_text())


def git(*arguments):
    return subprocess.run(
        ["git", *arguments], check=True, stdout=subprocess.PIPE
    ).stdout.decode().strip()


remote_oid = git(f"--git-dir={remote}", "rev-parse", "main")
local_oid = git("-C", str(root), "rev-parse", "HEAD")
refs = git(
    "-C", str(root), "for-each-ref", "--format=%(refname)",
    "refs/original/",
).splitlines()
assert remote_oid != original_remote
assert remote_oid == local_oid
assert refs, "post-push cleanup retry material was removed"
assert result["rollback_calls"] == 0
message = result["error"].lower()
assert "remote rewrite applied" in message
assert "local cleanup incomplete" in message
PY
  then
    pass "push成功後cleanup失敗はremote commitを維持しretry材料を残す"
  else
    fail "push成功後cleanup失敗はremote commitを維持しretry材料を残す"
  fi
}

test_cleanup_failure_marker_recovers_before_scope() {
  echo "test_cleanup_failure_marker_recovers_before_scope:"
  local base="$TEST_ROOT/purge-cycle11-cleanup"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode old_oid new_oid marker="$state/index/purge-recovery.json"
  init_fixture "$base" || {
    fail "cycle11 cleanup marker fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  old_oid="$(git --git-dir="$remote" rev-parse main)"
  if ! PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$marker" <<'PY'
import json
import pathlib
import stat
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
marker = pathlib.Path(sys.argv[3])
original_run_git = retention._run_git


def validate_marker_before_push():
    metadata = marker.lstat()
    assert stat.S_ISREG(metadata.st_mode)
    assert stat.S_IMODE(metadata.st_mode) == 0o600
    assert metadata.st_uid == __import__("os").geteuid()
    assert metadata.st_nlink == 1
    value = json.loads(marker.read_text())
    assert value == {
        "schema_version": 1,
        "contract_version": "purge-cleanup-recovery-v1",
        "state": "push_pending",
        "episode_id": episode,
        "policy_version": "default-v1",
        "old_remote_oid": value["old_remote_oid"],
        "new_rewritten_oid": value["new_rewritten_oid"],
    }
    assert value["new_rewritten_oid"] == retention._ref_snapshot(root)["refs/heads/main"]


def checked_run_git(root, arguments, *, env=None):
    if arguments[:3] == ["push", "--force", "origin"]:
        validate_marker_before_push()
    return original_run_git(root, arguments, env=env)


retention._run_git = checked_run_git
retention._cleanup_original_history = lambda _root: (
    (_ for _ in ()).throw(VaultError("fixture cleanup failure"))
)
try:
    retention.purge(root, episode, None, None, apply=True)
except VaultError as error:
    assert "remote rewrite applied" in str(error).lower()
else:
    raise AssertionError("cleanup failure unexpectedly succeeded")
PY
  then
    fail "push前marker保存とcleanup failureを注入できる"
    return
  fi
  if ! python3 - "$marker" "$episode" "$old_oid" <<'PY'
import json
import pathlib
import stat
import sys

path = pathlib.Path(sys.argv[1])
metadata = path.lstat()
assert stat.S_ISREG(metadata.st_mode)
assert stat.S_IMODE(metadata.st_mode) == 0o600
assert metadata.st_nlink == 1
value = json.loads(path.read_text())
assert value["episode_id"] == sys.argv[2]
assert value["old_remote_oid"] == sys.argv[3]
assert value["state"] == "push_pending"
PY
  then
    fail "cleanup failure後にstrict durable markerが残る"
    return
  fi
  new_oid="$(git --git-dir="$remote" rev-parse main)"
  if [[ "$new_oid" == "$old_oid" ]]; then
    fail "cleanup failure前のremote rewriteがcommit済みである"
    return
  fi
  if run_cli "$state" purge "$episode" --apply \
      >"$base/retry.out" 2>"$base/retry.err" \
    && [[ "$(git --git-dir="$remote" rev-parse main)" == "$new_oid" \
      && ! -e "$marker" ]] \
    && [[ -z "$(
      git -C "$state" for-each-ref --format='%(refname)' refs/original/
    )" ]]; then
    pass "cleanup失敗後の再applyはscope前にcleanup-only回復する"
  else
    fail "cleanup失敗後の再applyはscope前にcleanup-only回復する"
  fi
}

test_crash_after_push_recovers_cleanup_only() {
  echo "test_crash_after_push_recovers_cleanup_only:"
  local base="$TEST_ROOT/purge-cycle11-crash"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode old_oid new_oid marker="$state/index/purge-recovery.json"
  local status
  init_fixture "$base" || {
    fail "cycle11 crash marker fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  old_oid="$(git --git-dir="$remote" rev-parse main)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$marker" <<'PY'
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
marker = pathlib.Path(sys.argv[3])
original_run_git = retention._run_git


def checked_run_git(root, arguments, *, env=None):
    if arguments[:3] == ["push", "--force", "origin"]:
        assert marker.is_file(), "push occurred before durable marker"
    return original_run_git(root, arguments, env=env)


retention._run_git = checked_run_git
retention._cleanup_original_history = lambda _root: (_ for _ in ()).throw(
    SystemExit(75)
)
retention.purge(root, episode, None, None, apply=True)
PY
  status=$?
  new_oid="$(git --git-dir="$remote" rev-parse main)"
  if [[ "$status" -eq 75 && "$new_oid" != "$old_oid" && -f "$marker" ]] \
    && run_cli "$state" purge "$episode" --apply \
      >"$base/retry.out" 2>"$base/retry.err" \
    && [[ "$(git --git-dir="$remote" rev-parse main)" == "$new_oid" \
      && ! -e "$marker" ]]; then
    pass "push後process crashのmarkerをcleanup-onlyで回収する"
  else
    fail "push後process crashのmarkerをcleanup-onlyで回収する"
  fi
}

test_push_pending_marker_with_old_remote_resumes_normal_purge() {
  echo "test_push_pending_marker_with_old_remote_resumes_normal_purge:"
  local base="$TEST_ROOT/purge-cycle11-old-remote"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode old_oid marker="$state/index/purge-recovery.json"
  init_fixture "$base" || {
    fail "cycle11 old-remote marker fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  old_oid="$(git --git-dir="$remote" rev-parse main)"
  write_purge_recovery_marker \
    "$state" "$episode" "$old_oid" "$(printf 'b%.0s' {1..40})"
  if run_cli "$state" purge "$episode" --apply \
      >"$base/apply.out" 2>"$base/apply.err" \
    && [[ ! -e "$marker" \
      && "$(git --git-dir="$remote" rev-parse main)" != "$old_oid" ]]; then
    pass "remote==oldのpush_pending markerをclearしnormal purgeを続行する"
  else
    fail "remote==oldのpush_pending markerをclearしnormal purgeを続行する"
  fi
}

test_unsafe_cleanup_markers_fail_before_mutation() {
  echo "test_unsafe_cleanup_markers_fail_before_mutation:"
  local kind base state remote db episode marker old_oid new_oid
  local before_files before_head before_remote failures=0 status
  for kind in malformed symlink hardlink mode remote-diverged; do
    base="$TEST_ROOT/purge-cycle11-unsafe-$kind"
    state="$base/vault"
    remote="$base/remote.git"
    db="$state/index/vault.sqlite"
    marker="$state/index/purge-recovery.json"
    init_fixture "$base" || {
      fail "cycle11 unsafe $kind fixtureを作成できる"
      return
    }
    episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
    old_oid="$(git --git-dir="$remote" rev-parse main)"
    new_oid="$(printf 'b%.0s' {1..40})"
    if [[ "$kind" == "remote-diverged" ]]; then
      write_purge_recovery_marker \
        "$state" "$episode" "$(printf 'a%.0s' {1..40})" "$new_oid"
    else
      write_purge_recovery_marker "$state" "$episode" "$old_oid" "$new_oid"
    fi
    case "$kind" in
      malformed)
        printf '%s\n' '{"schema_version":1,"broken":true}' >"$marker"
        chmod 600 "$marker"
        ;;
      symlink)
        mv "$marker" "$state/index/purge-recovery-target.json"
        ln -s purge-recovery-target.json "$marker"
        ;;
      hardlink)
        ln "$marker" "$state/index/purge-recovery-hardlink.json"
        ;;
      mode)
        chmod 644 "$marker"
        ;;
    esac
    before_files="$(vault_byte_snapshot "$state")"
    before_head="$(git -C "$state" rev-parse HEAD)"
    before_remote="$(git --git-dir="$remote" rev-parse main)"
    run_cli "$state" purge "$episode" --apply \
      >"$base/apply.out" 2>"$base/apply.err"
    status=$?
    if [[ "$status" -eq 0 \
      || "$before_head" != "$(git -C "$state" rev-parse HEAD)" \
      || "$before_remote" != "$(git --git-dir="$remote" rev-parse main)" \
      || "$before_files" != "$(vault_byte_snapshot "$state")" \
      || $(grep -c 'Traceback' "$base/apply.err") -ne 0 ]]; then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "malformed/unsafe/diverged cleanup markerをmutation前に拒否する"
  else
    fail "malformed/unsafe/diverged cleanup markerをmutation前に拒否する"
  fi
}

test_pre_push_crash_marker_pushes_new_with_lease() {
  echo "test_pre_push_crash_marker_pushes_new_with_lease:"
  local base="$TEST_ROOT/purge-cycle12-pre-push"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode old_oid new_oid marker="$state/index/purge-recovery.json"
  local status calls="$base/push-calls.json"
  init_fixture "$base" || {
    fail "cycle12 pre-push crash fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  old_oid="$(git --git-dir="$remote" rev-parse main)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$marker" <<'PY'
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
marker = pathlib.Path(sys.argv[3])
original = retention._run_git


def crash_before_push(root, arguments, *, env=None):
    if arguments and arguments[0] == "push":
        assert marker.is_file(), "push attempted before marker durability"
        raise SystemExit(76)
    return original(root, arguments, env=env)


retention._run_git = crash_before_push
retention.purge(root, episode, None, None, apply=True)
PY
  status=$?
  new_oid="$(git -C "$state" rev-parse HEAD)"
  if [[ "$status" -ne 76 || ! -f "$marker" \
    || "$(git --git-dir="$remote" rev-parse main)" != "$old_oid" \
    || "$new_oid" == "$old_oid" ]]; then
    fail "push直前crashでmarker/local=new/remote=oldを保持する"
    return
  fi
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" "$calls" "$old_oid" <<'PY'
import json
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
output = pathlib.Path(sys.argv[3])
old_oid = sys.argv[4]
calls = []
original = retention._run_git


def checked(root, arguments, *, env=None):
    if arguments and arguments[0] == "push":
        calls.append(arguments)
        assert f"--force-with-lease=refs/heads/main:{old_oid}" in arguments
        assert "--force" not in arguments
    return original(root, arguments, env=env)


retention._run_git = checked
result = retention.purge(root, episode, None, None, apply=True)
assert result.get("cleanup_only") is True
output.write_text(json.dumps(calls))
PY
  then
    if [[ ! -e "$marker" \
      && "$(git --git-dir="$remote" rev-parse main)" == "$new_oid" ]] \
      && python3 - "$calls" <<'PY'
import json
import pathlib
import sys

calls = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert len(calls) == 1
assert all("--force" not in call for call in calls)
PY
    then
      pass "pre-push crash markerをold leaseでpushしcleanup-only完了する"
    else
      fail "pre-push crash markerをold leaseでpushしcleanup-only完了する"
    fi
  else
    fail "pre-push crash markerをold leaseでpushしcleanup-only完了する"
  fi
}

test_normal_push_lease_rejects_third_party_race() {
  echo "test_normal_push_lease_rejects_third_party_race:"
  local base="$TEST_ROOT/purge-cycle12-third-race"
  local state="$base/vault" remote="$base/remote.git"
  local db="$state/index/vault.sqlite"
  local episode old_oid third_oid result="$base/result.json"
  init_fixture "$base" || {
    fail "cycle12 third-party race fixtureを作成できる"
    return
  }
  episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
  old_oid="$(git --git-dir="$remote" rev-parse main)"
  third_oid="$(python3 - "$remote" "$old_oid" <<'PY'
import subprocess
import sys

remote, parent = sys.argv[1:]
tree = subprocess.run(
    ["git", f"--git-dir={remote}", "rev-parse", f"{parent}^{{tree}}"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode().strip()
print(subprocess.run(
    ["git", f"--git-dir={remote}", "commit-tree", tree, "-p", parent],
    input=b"fixture third-party update\n",
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode().strip())
PY
)"
  PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - \
      "$state" "$episode" "$remote" "$third_oid" "$old_oid" "$result" <<'PY'
import json
import pathlib
import subprocess
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1])
episode, remote, third_oid, old_oid = sys.argv[2:6]
output = pathlib.Path(sys.argv[6])
original = retention._run_git
calls = []
moved = False


def raced(root, arguments, *, env=None):
    global moved
    if arguments and arguments[0] == "push":
        calls.append(arguments)
        if not moved:
            subprocess.run(
                ["git", f"--git-dir={remote}", "update-ref", "refs/heads/main", third_oid],
                check=True,
            )
            moved = True
    return original(root, arguments, env=env)


retention._run_git = raced
try:
    retention.purge(root, episode, None, None, apply=True)
except VaultError as error:
    output.write_text(json.dumps({"error": str(error), "calls": calls}))
else:
    raise AssertionError("third-party race unexpectedly succeeded")
PY
  if python3 - "$state" "$remote" "$old_oid" "$third_oid" "$result" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
remote, old_oid, third_oid = sys.argv[2:5]
result = json.loads(pathlib.Path(sys.argv[5]).read_text())


def git(*arguments):
    return subprocess.run(
        ["git", *arguments], check=True, stdout=subprocess.PIPE
    ).stdout.decode().strip()


assert git(f"--git-dir={remote}", "rev-parse", "main") == third_oid
assert git("-C", str(root), "rev-parse", "HEAD") == old_oid
refs = git(
    "-C", str(root), "for-each-ref", "--format=%(refname)", "refs/original/"
).splitlines()
assert refs, "rollback recovery material was cleaned after remote race"
calls = result["calls"]
assert calls
first = calls[0]
assert f"--force-with-lease=refs/heads/main:{old_oid}" in first
assert all("--force" not in call for call in calls)
assert "rollback incomplete" in result["error"].lower()
PY
  then
    pass "normal push leaseはthird-party remoteを上書きせずrollback材料を保持する"
  else
    fail "normal push leaseはthird-party remoteを上書きせずrollback材料を保持する"
  fi
}

test_rollback_remote_restore_uses_new_oid_lease_only() {
  echo "test_rollback_remote_restore_uses_new_oid_lease_only:"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$TEST_ROOT" <<'PY'
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
old = "a" * 40
new = "b" * 40
third = "c" * 40


def exercise(initial):
    current = initial
    calls = []
    cleanup = []
    retention._original_refs = lambda _root: []
    retention._restore_ref_snapshot = lambda _root, _refs: None
    retention._restore_local_file_snapshots = lambda _files: []
    retention.restore_value_attempts = lambda _root, _snapshot: None
    retention.restore_attempts = lambda _root, _snapshot: None
    retention.restore_receipt_attempts = lambda _root, _snapshot: None
    retention._remote_main_oid = lambda _root: current

    def run_git(_root, arguments, *, env=None):
        nonlocal current
        calls.append(arguments)
        expected = f"--force-with-lease=refs/heads/main:{new}"
        if expected in arguments and initial == new:
            current = old

    retention._run_git = run_git
    retention._cleanup_original_history = lambda _root: cleanup.append(True)
    errors = retention._rollback_purge_state(
        root,
        refs={"refs/heads/main": old},
        remote_main_oid=old,
        rewritten_remote_oid=new,
        files=[],
        index_projection_files=[],
        value_attempts=None,
        evaluation_attempts=None,
        receipt_attempts=None,
    )
    return current, calls, cleanup, errors


current, calls, cleanup, errors = exercise(new)
assert current == old and not errors and cleanup
assert len(calls) == 1
assert f"--force-with-lease=refs/heads/main:{new}" in calls[0]
assert "--force" not in calls[0]
assert f"{old}:refs/heads/main" in calls[0]

current, calls, cleanup, errors = exercise(old)
assert current == old and calls == [] and not errors and cleanup

current, calls, cleanup, errors = exercise(third)
assert current == third
assert calls == []
assert errors
assert cleanup == []
PY
  then
    pass "rollbackはknown newだけをlease付きでoldへ戻しthirdを変更しない"
  else
    fail "rollbackはknown newだけをlease付きでoldへ戻しthirdを変更しない"
  fi
}

git_state_snapshot() {
  local state="$1"
  {
    if git -C "$state" symbolic-ref -q HEAD; then
      true
    else
      echo DETACHED
    fi
    git -C "$state" rev-parse HEAD
    git -C "$state" for-each-ref \
      --format='%(refname) %(objectname)' | LC_ALL=C sort
    git -C "$state" status --porcelain=v1 --untracked-files=all
  }
}

test_purge_preflight_requires_synced_main_head() {
  echo "test_purge_preflight_requires_synced_main_head:"
  local kind base state remote db episode unrelated old_oid third_oid
  local before_git before_files before_remote result failures=0
  for kind in remote-ahead detached other-branch; do
    base="$TEST_ROOT/purge-cycle13-$kind"
    state="$base/vault"
    remote="$base/remote.git"
    db="$state/index/vault.sqlite"
    result="$base/result.json"
    init_fixture "$base" || {
      fail "cycle13 $kind fixtureを作成できる"
      return
    }
    episode="$(db_value_for_event "$db" "$TARGET_EVENT" episode_id)"
    unrelated="$(db_value_for_event "$db" "$UNRELATED_EVENT" episode_id)"
    write_attempt_ledger "$state" "$episode" "$unrelated"
    write_receipt_attempt_ledger "$state" "$episode" "$unrelated" || {
      fail "cycle13 $kind receipt ledgerを作成できる"
      return
    }
    write_value_artifacts "$state" "$episode" "$unrelated" || {
      fail "cycle13 $kind Value artifactsを作成できる"
      return
    }
    materialize_prepared_receipts "$state" || {
      fail "cycle13 $kind stored receiptsを作成できる"
      return
    }
    old_oid="$(git --git-dir="$remote" rev-parse main)"
    case "$kind" in
      remote-ahead)
        third_oid="$(python3 - "$remote" "$old_oid" <<'PY'
import subprocess
import sys

remote, parent = sys.argv[1:]
tree = subprocess.run(
    ["git", f"--git-dir={remote}", "rev-parse", f"{parent}^{{tree}}"],
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode().strip()
print(subprocess.run(
    ["git", f"--git-dir={remote}", "commit-tree", tree, "-p", parent],
    input=b"fixture remote-ahead preflight\n",
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode().strip())
PY
)"
        git --git-dir="$remote" update-ref refs/heads/main "$third_oid"
        ;;
      detached)
        git -C "$state" checkout --detach -q
        ;;
      other-branch)
        git -C "$state" checkout -q -b fixture-other
        ;;
    esac
    before_git="$(git_state_snapshot "$state")"
    before_files="$(vault_byte_snapshot "$state")"
    before_remote="$(git --git-dir="$remote" rev-parse main)"
    PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
      python3 - "$state" "$episode" "$result" <<'PY'
import json
import pathlib
import sys

import retention

root = pathlib.Path(sys.argv[1])
episode = sys.argv[2]
result = pathlib.Path(sys.argv[3])
original = retention._run_git
pushes = []


def tracked(root, arguments, *, env=None):
    if arguments and arguments[0] == "push":
        pushes.append(arguments)
    return original(root, arguments, env=env)


retention._run_git = tracked
try:
    retention.purge(root, episode, None, None, apply=True)
except Exception as error:
    result.write_text(json.dumps({
        "success": False,
        "error": str(error),
        "pushes": pushes,
    }))
else:
    result.write_text(json.dumps({
        "success": True,
        "error": "",
        "pushes": pushes,
    }))
PY
    if ! python3 - "$result" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["success"] is False
assert "sync required" in value["error"].lower()
assert value["pushes"] == []
PY
    then
      failures=$((failures + 1))
    elif [[ "$before_git" != "$(git_state_snapshot "$state")" \
      || "$before_files" != "$(vault_byte_snapshot "$state")" \
      || "$before_remote" != "$(git --git-dir="$remote" rev-parse main)" ]]; then
      failures=$((failures + 1))
    fi
  done
  if [[ "$failures" -eq 0 ]]; then
    pass "purge preflightはsynced main以外をpushゼロ・mutationゼロで拒否する"
  else
    fail "purge preflightはsynced main以外をpushゼロ・mutationゼロで拒否する"
  fi
}

test_review_rollback_boundaries_fail_closed() {
  echo "test_review_rollback_boundaries_fail_closed:"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$TEST_ROOT" <<'PY'
import os
import pathlib
import stat
import sys

import retention
from vault import VaultError

root = pathlib.Path(sys.argv[1]) / "review-cycle14"
index = root / "index"
index.mkdir(parents=True, mode=0o700)

# Snapshot files must be exactly 0600 even under a restrictive umask.
source = index / "source.sqlite"
target = index / "snapshot.sqlite"
source.write_bytes(b"snapshot")
source.chmod(0o600)
previous_umask = os.umask(0o777)
try:
    retention._copy_disk_snapshot(source, target)
finally:
    os.umask(previous_umask)
assert stat.S_IMODE(target.stat().st_mode) == 0o600
target.unlink()

# A pre-marker crash may leave an empty, safe rollback directory. The next
# apply must remove it before normal purge processing can resume.
rollback = root / retention.PURGE_ROLLBACK_DIRECTORY
rollback.mkdir(mode=0o700)
assert retention._resume_purge_recovery(root, "episode", "default-v1") is None
assert not rollback.exists()

# Unexpected contents must fail through the stable VaultError boundary.
rollback.mkdir(mode=0o700)
(rollback / "unexpected").write_bytes(b"x")
try:
    retention._discard_index_projection_snapshots(root)
except VaultError as error:
    assert isinstance(error.__cause__, OSError)
else:
    raise AssertionError("unsafe rollback directory was accepted")
(rollback / "unexpected").unlink()
rollback.rmdir()

# Never issue a valid seal after restoring the forget state failed.
captured_reseal = []
retention._original_refs = lambda _root: []
retention._restore_ref_snapshot = lambda _root, _refs: None
retention._restore_local_file_snapshots = lambda _files: [
    VaultError("forget restore failed")
]

def restore_projection(_root, _snapshots, *, reseal=True):
    captured_reseal.append(reseal)
    return []

retention._restore_index_projection_snapshots = restore_projection
retention.restore_value_attempts = lambda _root, _snapshot: None
retention.restore_attempts = lambda _root, _snapshot: None
retention.restore_receipt_attempts = lambda _root, _snapshot: None
retention._remote_main_oid = lambda _root: "a" * 40
retention._cleanup_original_history = lambda _root: None
errors = retention._rollback_purge_state(
    root,
    refs={"refs/heads/main": "a" * 40},
    remote_main_oid="a" * 40,
    files=[],
    index_projection_files=[],
    value_attempts=None,
    evaluation_attempts=None,
    receipt_attempts=None,
)
assert errors
assert captured_reseal == [False]
PY
  then
    pass "purge rollbackはmode・残留directory・例外境界・forget失敗時resealを安全に扱う"
  else
    fail "purge rollbackはmode・残留directory・例外境界・forget失敗時resealを安全に扱う"
  fi
}

echo "=== Flight Recorder Retention Tests ==="
if [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE7_ONLY:-0}" == "1" ]]; then
  test_purge_push_rejection_restores_retryable_local_state
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE8_ONLY:-0}" == "1" ]]; then
  test_purge_dry_run_does_not_recover_prepared_temp
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE9_ONLY:-0}" == "1" ]]; then
  test_purge_unlink_failure_restores_complete_local_state
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE10_ONLY:-0}" == "1" ]]; then
  case "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE10_CASE:-all}" in
    ordering)
      test_rollback_attempts_exact_refs_after_restore_history_failure
      ;;
    preserve)
      test_incomplete_ref_rollback_preserves_original_history
      ;;
    visibility)
      test_cli_reports_incomplete_rollback_with_original_context
      ;;
    commit-point)
      test_post_push_cleanup_failure_keeps_remote_commit_point
      ;;
    all)
      test_rollback_attempts_exact_refs_after_restore_history_failure
      test_incomplete_ref_rollback_preserves_original_history
      test_cli_reports_incomplete_rollback_with_original_context
      test_post_push_cleanup_failure_keeps_remote_commit_point
      ;;
    *)
      fail "unknown cycle10 test case"
      ;;
  esac
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE11_ONLY:-0}" == "1" ]]; then
  case "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE11_CASE:-all}" in
    cleanup)
      test_cleanup_failure_marker_recovers_before_scope
      ;;
    crash)
      test_crash_after_push_recovers_cleanup_only
      ;;
    old-remote)
      test_push_pending_marker_with_old_remote_resumes_normal_purge
      ;;
    unsafe)
      test_unsafe_cleanup_markers_fail_before_mutation
      ;;
    all)
      test_cleanup_failure_marker_recovers_before_scope
      test_crash_after_push_recovers_cleanup_only
      test_push_pending_marker_with_old_remote_resumes_normal_purge
      test_unsafe_cleanup_markers_fail_before_mutation
      ;;
    *)
      fail "unknown cycle11 test case"
      ;;
  esac
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE12_ONLY:-0}" == "1" ]]; then
  case "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE12_CASE:-all}" in
    resume-push)
      test_pre_push_crash_marker_pushes_new_with_lease
      ;;
    third-race)
      test_normal_push_lease_rejects_third_party_race
      ;;
    rollback-lease)
      test_rollback_remote_restore_uses_new_oid_lease_only
      ;;
    all)
      test_pre_push_crash_marker_pushes_new_with_lease
      test_normal_push_lease_rejects_third_party_race
      test_rollback_remote_restore_uses_new_oid_lease_only
      ;;
    *)
      fail "unknown cycle12 test case"
      ;;
  esac
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE13_ONLY:-0}" == "1" ]]; then
  test_purge_preflight_requires_synced_main_head
elif [[ "${FLIGHT_RECORDER_TEST_RETENTION_CYCLE14_ONLY:-0}" == "1" ]]; then
  test_review_rollback_boundaries_fail_closed
else
  test_forget_preserves_source_and_survives_rebuild
  test_dangling_forget_marker_fails_closed
  test_purge_dry_run_previews_scope_without_rewriting_history
  test_purge_apply_removes_target_history_and_keeps_unrelated_chunk
  test_purge_push_rejection_restores_retryable_local_state
  test_invalid_attempt_ledger_blocks_purge_before_rewrite
  test_purge_dry_run_does_not_recover_prepared_temp
  test_purge_unlink_failure_restores_complete_local_state
  test_rollback_attempts_exact_refs_after_restore_history_failure
  test_incomplete_ref_rollback_preserves_original_history
  test_cli_reports_incomplete_rollback_with_original_context
  test_post_push_cleanup_failure_keeps_remote_commit_point
  test_cleanup_failure_marker_recovers_before_scope
  test_crash_after_push_recovers_cleanup_only
  test_push_pending_marker_with_old_remote_resumes_normal_purge
  test_unsafe_cleanup_markers_fail_before_mutation
  test_pre_push_crash_marker_pushes_new_with_lease
  test_normal_push_lease_rejects_third_party_race
  test_rollback_remote_restore_uses_new_oid_lease_only
  test_purge_preflight_requires_synced_main_head
  test_review_rollback_boundaries_fail_closed
fi
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
