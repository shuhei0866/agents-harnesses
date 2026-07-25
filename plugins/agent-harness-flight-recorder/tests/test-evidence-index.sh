#!/usr/bin/env bash
# SQLite evidence index contract tests (external dependencies: git and python3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
RECORDER="$PLUGIN_DIR/scripts/record-event"
FAKE_BIN="$SCRIPT_DIR/fixtures/fake-bin"
FIXTURE="$SCRIPT_DIR/fixtures/claude-code-stop.json"
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

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

run_cli() {
  local state="$1"
  shift
  PATH="$FAKE_BIN:$PATH" FLIGHT_RECORDER_STATE_DIR="$state" "$CLI" "$@"
}

record_event() {
  local state="$1" now="$2"
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" "$now" <<'PY'
import json
import pathlib
import sys
import uuid

path, recorded_at = sys.argv[1:]
event = {
    "schema_version": 1,
    "event_id": str(uuid.uuid5(uuid.NAMESPACE_URL, recorded_at)),
    "recorded_at": recorded_at,
    "harness": "claude-code",
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
pathlib.Path(path).write_text(
    json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
}

init_remote() {
  local remote="$1"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
}

init_fixture() {
  local base="$1" now="$2"
  local remote="$base/remote.git" state="$base/vault"
  local recovery="$base/recovery.agekey"
  mkdir -p "$base"
  init_remote "$remote"
  make_identity "$recovery"
  run_cli "$state" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")" >/dev/null 2>&1
  record_event "$state" "$now"
  run_cli "$state" sync >/dev/null 2>&1
}

db_snapshot() {
  python3 - "$1" <<'PY'
import json
import sqlite3
import sys

path = sys.argv[1]
tables = (
    "schema_metadata",
    "source_chunks",
    "source_events",
    "import_provenance",
    "derived_state",
)
connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
snapshot = {
    "user_version": connection.execute("PRAGMA user_version").fetchone()[0],
    "tables": {},
}
for table in tables:
    columns = [
        tuple(row[1:6])
        for row in connection.execute(f'PRAGMA table_info("{table}")')
    ]
    foreign_keys = sorted(
        tuple(row[2:8])
        for row in connection.execute(f'PRAGMA foreign_key_list("{table}")')
    )
    rows = [
        tuple(row)
        for row in connection.execute(f'SELECT * FROM "{table}"')
    ]
    snapshot["tables"][table] = {
        "columns": columns,
        "foreign_keys": foreign_keys,
        "rows": sorted(rows, key=lambda row: repr(row)),
    }
print(json.dumps(snapshot, sort_keys=True, separators=(",", ":"), default=str))
PY
}

db_counts() {
  python3 - "$1" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(
    connection.execute("SELECT COUNT(*) FROM source_chunks").fetchone()[0],
    connection.execute("SELECT COUNT(*) FROM source_events").fetchone()[0],
    connection.execute("SELECT COUNT(*) FROM import_provenance").fetchone()[0],
)
PY
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

source_tree_snapshot() {
  python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [root / "index" / "imported-chunks.json"]
paths.extend(sorted((root / "cache" / "imported").rglob("*.jsonl")))
for path in paths:
    relative = path.relative_to(root).as_posix()
    print(relative, hashlib.sha256(path.read_bytes()).hexdigest())
PY
}

test_full_rebuild_is_logically_deterministic() {
  echo "test_full_rebuild_is_logically_deterministic:"
  local base="$TEST_ROOT/deterministic"
  local state="$base/vault"
  local db="$state/index/vault.sqlite" before after
  init_fixture "$base" "2026-07-25T01:00:00Z" || {
    fail "deterministic fixtureを作成できる"
    return
  }

  if ! run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "import済みchunkからindexをfull rebuildできる"
    return
  fi
  before="$(db_snapshot "$db" 2>/dev/null)" || {
    fail "初回indexを読み取れる"
    return
  }
  rm "$db"
  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    after="$(db_snapshot "$db" 2>/dev/null)"
    if [[ "$before" == "$after" && "$(db_counts "$db")" == "1 1 1" ]]; then
      pass "DB削除後も同じchunksからlogical schema/rowsを決定論的に再構築する"
    else
      fail "DB削除後も同じchunksからlogical schema/rowsを決定論的に再構築する"
    fi
  else
    fail "DB削除後にfull rebuildできる"
  fi
}

test_incremental_import_is_idempotent() {
  echo "test_incremental_import_is_idempotent:"
  local base="$TEST_ROOT/incremental"
  local state="$base/vault"
  local db="$state/index/vault.sqlite" first repeated expanded
  init_fixture "$base" "2026-07-25T02:00:00Z" || {
    fail "incremental fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "incremental fixtureのindexを作成できる"
    return
  }
  first="$(db_counts "$db" 2>/dev/null)"
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1
  repeated="$(db_counts "$db" 2>/dev/null)"
  record_event "$state" "2026-07-26T02:01:00Z"
  run_cli "$state" sync >/dev/null 2>&1
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1
  expanded="$(db_counts "$db" 2>/dev/null)"

  if [[ "$first" == "1 1 1" && "$repeated" == "$first" \
    && "$expanded" == "2 2 2" ]]; then
    pass "incremental rebuildは既知chunkを重複せず新規chunkだけ追加する"
  else
    fail "incremental rebuildは既知chunkを重複せず新規chunkだけ追加する"
  fi
}

test_full_rebuild_recovers_corrupt_database() {
  echo "test_full_rebuild_recovers_corrupt_database:"
  local base="$TEST_ROOT/corrupt"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  init_fixture "$base" "2026-07-25T03:00:00Z" || {
    fail "corrupt fixtureを作成できる"
    return
  }
  mkdir -p "$state/index"
  printf '%s\n' 'not a sqlite database' >"$db"

  if run_cli "$state" rebuild-index >/dev/null 2>&1 \
    && [[ "$(db_counts "$db" 2>/dev/null)" == "1 1 1" ]] \
    && python3 - "$db" <<'PY' 2>/dev/null
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
PY
  then
    pass "破損DBを原本chunkからfull rebuildして復旧する"
  else
    fail "破損DBを原本chunkからfull rebuildして復旧する"
  fi
}

test_failed_rebuild_is_atomic() {
  echo "test_failed_rebuild_is_atomic:"
  local base="$TEST_ROOT/atomic"
  local state="$base/vault"
  local db="$state/index/vault.sqlite" device bad_digest source_path cache
  local before_db before_sources after_db after_sources
  init_fixture "$base" "2026-07-25T04:00:00Z" || {
    fail "atomic fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "atomic fixtureのindexを作成できる"
    return
  }
  device="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["devices"][0]["device_id"])' "$state/vault.json")"
  bad_digest="$(printf 'f%.0s' {1..64})"
  source_path="devices/$device/2026/07/27/$bad_digest.jsonl.age"
  cache="$state/cache/imported/$device/2026/07/27/$bad_digest.jsonl"
  mkdir -p "$(dirname "$cache")"
  printf '%s\n' '{"record_type":"chunk_header","broken":true}' >"$cache"
  python3 - "$state/index/imported-chunks.json" "$source_path" "$bad_digest" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["chunks"][sys.argv[2]] = {
    "blob_oid": "f" * 40,
    "chunk_id": f"sha256:{sys.argv[3]}",
}
path.write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  before_db="$(sha256_file "$db")"
  before_sources="$(source_tree_snapshot "$state")"

  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "invalidな新規cache chunkを成功扱いしない"
    return
  fi
  after_db="$(sha256_file "$db")"
  after_sources="$(source_tree_snapshot "$state")"
  if [[ "$before_db" == "$after_db" && "$before_sources" == "$after_sources" \
    && "$(db_counts "$db" 2>/dev/null)" == "1 1 1" ]]; then
    pass "full rebuild失敗時に旧DBとreceipt/cache原本を変更しない"
  else
    fail "full rebuild失敗時に旧DBとreceipt/cache原本を変更しない"
  fi
}

test_schema_contract_and_local_security() {
  echo "test_schema_contract_and_local_security:"
  local base="$TEST_ROOT/schema"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  init_fixture "$base" "2026-07-25T05:00:00Z" || {
    fail "schema fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "schema fixtureのindexを作成できる"
    return
  }

  if python3 - "$db" <<'PY' 2>/dev/null
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
required_tables = {
    "schema_metadata",
    "source_chunks",
    "source_events",
    "import_provenance",
    "derived_state",
}
tables = {
    row[0]
    for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table'"
    )
}
assert required_tables <= tables
assert connection.execute("PRAGMA user_version").fetchone()[0] == 2

def columns(table):
    return {row[1] for row in connection.execute(f'PRAGMA table_info("{table}")')}

assert {
    "chunk_id", "source_path", "git_blob_oid", "vault_id", "device_id",
    "created_at", "event_schema_version", "event_count",
    "canonical_plaintext_sha256",
} <= columns("source_chunks")
assert {
    "event_id", "chunk_id", "ordinal", "schema_version", "recorded_at",
    "harness", "source_event", "event_kind", "session_id_hash",
    "turn_id_hash", "workspace_id", "model", "permission_mode", "tool",
    "metrics_json", "outcome_json",
    "relationship_task_id_hash", "relationship_task_source",
    "relationship_branch_or_worktree_id",
    "relationship_changed_file_fingerprints_json",
    "relationship_changed_files_state", "canonical_event_json",
} <= columns("source_events")
assert {
    "chunk_id", "source_path", "git_blob_oid", "cache_path",
    "receipt_schema_version", "index_schema_version",
} <= columns("import_provenance")
source_only = {
    "canonical_event_json", "canonical_plaintext_sha256", "git_blob_oid",
    "source_path", "cache_path",
}
assert not (source_only & columns("derived_state"))

metadata = dict(connection.execute("SELECT key, value FROM schema_metadata"))
assert metadata["event_schema_versions"] == "1,2"
assert metadata["schema_version"] == "2"
assert metadata["source_of_truth"] == "encrypted_chunk_v1_event_v1_v2"
assert metadata["index_role"] == "derived_rebuildable"

# This fixture was recorded as Event v1. SQLite v2 must preserve its existing
# projection while representing absent v2 relationship context as SQL NULL,
# rather than manufacturing a misleading "same missing value" signal.
v1_projection = connection.execute(
    """
    SELECT schema_version,
           relationship_task_id_hash,
           relationship_task_source,
           relationship_branch_or_worktree_id,
           relationship_changed_file_fingerprints_json,
           relationship_changed_files_state
    FROM source_events
    """
).fetchone()
assert v1_projection == (1, None, None, None, None, None)

event_foreign_keys = list(
    connection.execute('PRAGMA foreign_key_list("source_events")')
)
provenance_foreign_keys = list(
    connection.execute('PRAGMA foreign_key_list("import_provenance")')
)
assert any(row[2] == "source_chunks" and row[3] == "chunk_id" for row in event_foreign_keys)
assert any(row[2] == "source_chunks" and row[3] == "chunk_id" for row in provenance_foreign_keys)
assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
PY
  then
    pass "SQLite v2はv1互換source・v2 context・derived境界・provenance・FKを明示する"
  else
    fail "SQLite v2はv1互換source・v2 context・derived境界・provenance・FKを明示する"
  fi

  if python3 - "$db" <<'PY' 2>/dev/null
import os
import stat
import sys

assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600
PY
  then
    pass "index DBを0600で作成する"
  else
    fail "index DBを0600で作成する"
  fi
  if git -C "$state" check-ignore -q index/vault.sqlite; then
    pass "index DBはGit同期対象外である"
  else
    fail "index DBはGit同期対象外である"
  fi

  local saved="$state/index/original.sqlite" sentinel="$base/sentinel"
  mv "$db" "$saved"
  printf '%s\n' 'must remain unchanged' >"$sentinel"
  ln -s "$sentinel" "$db"
  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "symlinkのindex DBを拒否する"
  elif [[ "$(cat "$sentinel")" == "must remain unchanged" \
    && -L "$db" ]]; then
    pass "symlinkのindex DBを拒否してlink先を変更しない"
  else
    fail "symlinkのindex DBを拒否してlink先を変更しない"
  fi
}

test_migration_failure_and_unreceipted_cache_are_isolated() {
  echo "test_migration_failure_and_unreceipted_cache_are_isolated:"
  local base="$TEST_ROOT/migration"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local before_sources after_sources
  init_fixture "$base" "2026-07-25T06:00:00Z" || {
    fail "migration fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "migration fixtureのindexを作成できる"
    return
  }
  before_sources="$(source_tree_snapshot "$state")"
  python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA user_version = 999")
connection.commit()
connection.close()
PY
  if run_cli "$state" rebuild-index --incremental >/dev/null 2>&1; then
    fail "unsupported schemaをin-place migrationしない"
  elif [[ "$(python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); print(c.execute("PRAGMA user_version").fetchone()[0])' "$db")" == "999" \
    && "$before_sources" == "$(source_tree_snapshot "$state")" ]]; then
    pass "migration失敗時に旧DBとdecoded sourceを変更しない"
  else
    fail "migration失敗時に旧DBとdecoded sourceを変更しない"
  fi
  if run_cli "$state" rebuild-index >/dev/null 2>&1 \
    && [[ "$(db_counts "$db")" == "1 1 1" ]]; then
    pass "unsupported schemaもfull rebuildで現在版へ復旧する"
  else
    fail "unsupported schemaもfull rebuildで現在版へ復旧する"
  fi

  local unreceipted="$state/cache/imported/unreceipted.jsonl"
  printf '%s\n' '{"must":"not be indexed without provenance"}' >"$unreceipted"
  local before_db
  before_db="$(sha256_file "$db")"
  before_sources="$(source_tree_snapshot "$state")"
  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "receiptのないdecoded cacheを黙ってindexしない"
  else
    after_sources="$(source_tree_snapshot "$state")"
    if [[ "$before_db" == "$(sha256_file "$db")" \
      && "$before_sources" == "$after_sources" ]]; then
      pass "unreceipted cacheを拒否して旧DBを保持する"
    else
      fail "unreceipted cacheを拒否して旧DBを保持する"
    fi
  fi
}

test_incremental_rejects_symlinked_index_directory() {
  echo "test_incremental_rejects_symlinked_index_directory:"
  local base="$TEST_ROOT/index-directory-symlink"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local external="$base/external-index"
  local external_db="$external/vault.sqlite"
  local before after
  init_fixture "$base" "2026-07-25T07:00:00Z" || {
    fail "index directory symlink fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "index directory symlink fixtureのDBを作成できる"
    return
  }
  mv "$state/index" "$external"
  ln -s "$external" "$state/index"
  before="$(sha256_file "$external_db")"

  if run_cli "$state" rebuild-index --incremental >/dev/null 2>&1; then
    fail "Vault外を指すindex directory symlinkを拒否する"
  else
    after="$(sha256_file "$external_db")"
    if [[ "$before" == "$after" && -L "$state/index" ]]; then
      pass "index directory symlinkを拒否して外部DBを変更しない"
    else
      fail "index directory symlinkを拒否して外部DBを変更しない"
    fi
  fi
}

test_incremental_rejects_wal_and_schema_drift_without_mutation() {
  echo "test_incremental_rejects_wal_and_schema_drift_without_mutation:"
  local base="$TEST_ROOT/wal-schema-drift"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local before_hash before_mode after_hash after_mode
  init_fixture "$base" "2026-07-25T08:00:00Z" || {
    fail "WAL schema drift fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "WAL schema drift fixtureのDBを作成できる"
    return
  }
  python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
assert connection.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
connection.execute("PRAGMA user_version=999")
connection.commit()
connection.close()
PY
  before_mode="$(python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(connection.execute("PRAGMA journal_mode").fetchone()[0])
connection.close()
PY
)"
  before_hash="$(sha256_file "$db")"

  if run_cli "$state" rebuild-index --incremental >/dev/null 2>&1; then
    fail "WALかつ未知schemaのDBをincremental更新しない"
  else
    after_mode="$(python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(connection.execute("PRAGMA journal_mode").fetchone()[0])
connection.close()
PY
)"
    after_hash="$(sha256_file "$db")"
    if [[ "$before_hash" == "$after_hash" && "$before_mode" == "wal" \
      && "$after_mode" == "$before_mode" ]]; then
      pass "incremental拒否時にWAL DBのbytes/journal modeを変更しない"
    else
      fail "incremental拒否時にWAL DBのbytes/journal modeを変更しない"
    fi
  fi
}

test_incremental_rejects_unexpected_database_objects() {
  echo "test_incremental_rejects_unexpected_database_objects:"
  local base="$TEST_ROOT/unexpected-object"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local before after
  init_fixture "$base" "2026-07-25T09:00:00Z" || {
    fail "unexpected DB object fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "unexpected DB object fixtureのDBを作成できる"
    return
  }
  python3 - "$db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    """
    CREATE TRIGGER unexpected_source_event_trigger
    AFTER INSERT ON source_events
    BEGIN
      SELECT 1;
    END
    """
)
connection.commit()
connection.close()
PY
  before="$(sha256_file "$db")"

  if run_cli "$state" rebuild-index --incremental >/dev/null 2>&1; then
    fail "receipt/cacheに存在しないunexpected DB objectを受理しない"
  else
    after="$(sha256_file "$db")"
    if [[ "$before" == "$after" ]] \
      && python3 - "$db" <<'PY' 2>/dev/null
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert connection.execute(
    "SELECT COUNT(*) FROM sqlite_master "
    "WHERE type='trigger' AND name='unexpected_source_event_trigger'"
).fetchone()[0] == 1
PY
    then
      pass "unexpected triggerをfail closedで拒否して旧DBを変更しない"
    else
      fail "unexpected triggerをfail closedで拒否して旧DBを変更しない"
    fi
  fi
}

test_full_rebuild_authenticates_receipt_blob_oid() {
  echo "test_full_rebuild_authenticates_receipt_blob_oid:"
  local base="$TEST_ROOT/receipt-blob-mismatch"
  local state="$base/vault"
  local db="$state/index/vault.sqlite"
  local before_db before_sources before_artifacts
  local after_db after_sources after_artifacts
  init_fixture "$base" "2026-07-25T10:00:00Z" || {
    fail "receipt blob mismatch fixtureを作成できる"
    return
  }
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "receipt blob mismatch fixtureのDBを作成できる"
    return
  }
  python3 - "$state/index/imported-chunks.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
receipt = next(iter(value["chunks"].values()))
replacement = "a" * 40
if receipt["blob_oid"] == replacement:
    replacement = "b" * 40
receipt["blob_oid"] = replacement
path.write_text(
    json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
  before_db="$(sha256_file "$db")"
  before_sources="$(source_tree_snapshot "$state")"
  before_artifacts="$(python3 - "$state" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted((root / "devices").rglob("*.jsonl.age")):
    print(path.relative_to(root).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest())
PY
)"

  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "Git blobと一致しない有効形式のreceipt blob_oidを受理しない"
  else
    after_db="$(sha256_file "$db")"
    after_sources="$(source_tree_snapshot "$state")"
    after_artifacts="$(python3 - "$state" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for path in sorted((root / "devices").rglob("*.jsonl.age")):
    print(path.relative_to(root).as_posix(), hashlib.sha256(path.read_bytes()).hexdigest())
PY
)"
    if [[ "$before_db" == "$after_db" \
      && "$before_sources" == "$after_sources" \
      && "$before_artifacts" == "$after_artifacts" ]]; then
      pass "receipt認証失敗時に旧DB・artifact・cache・receiptを変更しない"
    else
      fail "receipt認証失敗時に旧DB・artifact・cache・receiptを変更しない"
    fi
  fi
}

test_full_rebuild_collects_stale_regular_temporary_database() {
  echo "test_full_rebuild_collects_stale_regular_temporary_database:"
  local base="$TEST_ROOT/stale-temp"
  local state="$base/vault"
  local stale="$state/index/.vault.sqlite.interrupted"
  init_fixture "$base" "2026-07-25T11:00:00Z" || {
    fail "stale temp fixtureを作成できる"
    return
  }
  mkdir -p "$state/index"
  printf '%s\n' 'stale incomplete database' >"$stale"

  if run_cli "$state" rebuild-index >/dev/null 2>&1 \
    && [[ ! -e "$stale" && ! -L "$stale" \
      && "$(db_counts "$state/index/vault.sqlite" 2>/dev/null)" == "1 1 1" ]]; then
    pass "次回full rebuildでstale regular DB tempを回収する"
  else
    fail "次回full rebuildでstale regular DB tempを回収する"
  fi
}

echo "=== Flight Recorder SQLite Evidence Index Tests ==="
TESTS=(
  test_full_rebuild_is_logically_deterministic
  test_incremental_import_is_idempotent
  test_full_rebuild_recovers_corrupt_database
  test_failed_rebuild_is_atomic
  test_schema_contract_and_local_security
  test_migration_failure_and_unreceipted_cache_are_isolated
  test_incremental_rejects_symlinked_index_directory
  test_incremental_rejects_wal_and_schema_drift_without_mutation
  test_incremental_rejects_unexpected_database_objects
  test_full_rebuild_authenticates_receipt_blob_oid
  test_full_rebuild_collects_stale_regular_temporary_database
)
for test_name in "${TESTS[@]}"; do
  if [[ -z "${EVIDENCE_INDEX_TEST_FILTER:-}" \
    || "$test_name" == *"$EVIDENCE_INDEX_TEST_FILTER"* ]]; then
    "$test_name"
  fi
done
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
