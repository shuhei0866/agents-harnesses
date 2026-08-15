#!/usr/bin/env bash
# Authenticated evidence-index seal contract tests.
# External dependencies: git and python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PLUGIN_DIR/scripts/flight-recorder"
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
  python3 -c '
import os
import signal
import subprocess
import sys

fake_bin, state, cli, *arguments = sys.argv[1:]
environment = dict(os.environ)
environment["PATH"] = fake_bin + os.pathsep + environment["PATH"]
environment["FLIGHT_RECORDER_STATE_DIR"] = state
process = subprocess.Popen(
    [cli, *arguments],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    env=environment,
    start_new_session=True,
)
try:
    stdout, stderr = process.communicate(timeout=60)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    stdout, stderr = process.communicate()
    sys.stderr.buffer.write(stderr)
    sys.stderr.write("index seal test command timed out\n")
    raise SystemExit(124)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
raise SystemExit(process.returncode)
' "$FAKE_BIN" "$state" "$CLI" "$@"
}

make_identity() {
  PATH="$FAKE_BIN:$PATH" age-keygen -o "$1" >/dev/null 2>&1
}

recipient_of() {
  PATH="$FAKE_BIN:$PATH" age-keygen -y "$1"
}

record_event() {
  local state="$1" event_id="$2" recorded_at="$3"
  mkdir -p "$state/inbox"
  python3 - "$state/inbox/events.jsonl" "$event_id" "$recorded_at" <<'PY'
import json
import os
import pathlib
import sys

path, event_id, recorded_at = sys.argv[1:]
event = {
    "schema_version": 2,
    "event_id": event_id,
    "recorded_at": recorded_at,
    "harness": "claude-code",
    "source_event": "Stop",
    "event_kind": "turn.completed",
    "session_id_hash": "sha256:" + "1" * 24,
    "turn_id_hash": None,
    "workspace_id": "sha256:" + "2" * 24,
    "model": "fixture-model",
    "permission_mode": None,
    "tool": None,
    "metrics": {"duration_ms": 1000},
    "outcome": {"status": "success", "exit_code": 0},
    "relationship_context": {
        "task_id_hash": "sha256:" + "3" * 24,
        "task_source": "payload",
        "branch_or_worktree_id": "sha256:" + "4" * 24,
        "changed_file_fingerprints": ["sha256:" + "5" * 24],
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
  record_event "$state" \
    "49000000-0000-4000-8000-000000000001" \
    "2026-08-13T00:00:00Z"
  run_cli "$state" sync >/dev/null 2>&1
  run_cli "$state" rebuild-index >/dev/null 2>&1
}

episode_id_for_fixture() {
  python3 - "$1/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = connection.execute(
    "SELECT episode_id FROM episodes "
    "WHERE policy_version='default-v1' ORDER BY episode_id LIMIT 1"
).fetchone()
assert row is not None
print(row[0])
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

validate_seal_contract() {
  python3 - "$1" "$2" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import stat
import sys

seal_path = pathlib.Path(sys.argv[1])
database_path = pathlib.Path(sys.argv[2])
seal_stat = seal_path.lstat()
assert stat.S_ISREG(seal_stat.st_mode)
assert stat.S_IMODE(seal_stat.st_mode) == 0o600
assert seal_stat.st_uid == os.geteuid()
assert seal_stat.st_nlink == 1
assert seal_stat.st_size <= 65536
value = json.loads(seal_path.read_text(encoding="utf-8"))
assert set(value) == {
    "schema_version", "contract_version", "issued_at", "database",
    "index_schema", "source_inventory", "forget_inventory",
    "relationship_projection", "integrity",
}
assert value["schema_version"] == 1
assert value["contract_version"] == "authenticated-evidence-index-seal-v1"
assert set(value["database"]) == {
    "sha256", "size_bytes", "device", "inode", "mtime_ns", "mode",
    "vault_id", "generation",
}
database = database_path.stat()
raw_digest = hashlib.sha256(database_path.read_bytes()).hexdigest()
identity = value["database"]
assert identity["sha256"] == "sha256:" + raw_digest
assert identity["size_bytes"] == database.st_size
assert identity["device"] == database.st_dev
assert identity["inode"] == database.st_ino
assert identity["mtime_ns"] == database.st_mtime_ns
assert identity["mode"] == stat.S_IMODE(database.st_mode) == 0o600
assert re.fullmatch(r"[0-9a-f-]{36}", identity["vault_id"])
assert re.fullmatch(r"sha256:[0-9a-f]{64}", identity["generation"])
assert set(value["index_schema"]) == {
    "user_version", "signature_sha256", "metadata_sha256",
}
assert value["index_schema"]["user_version"] == 3
assert set(value["source_inventory"]) == {
    "chunk_count", "event_count", "sha256",
}
assert value["source_inventory"]["chunk_count"] >= 1
assert value["source_inventory"]["event_count"] >= 1
assert set(value["forget_inventory"]) == {"entry_count", "sha256"}
assert set(value["relationship_projection"]) == {
    "generation", "policy_count", "policy_inventory_sha256",
}
assert re.fullmatch(r"sha256:[0-9a-f]{64}", value["relationship_projection"]["generation"])
assert value["relationship_projection"]["generation"] == identity["generation"]
assert value["relationship_projection"]["policy_count"] >= 1
assert value["integrity"]["algorithm"] == "hmac-sha256"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", value["integrity"]["mac"])
PY
}

test_trusted_full_and_incremental_rebuild_emit_bound_seal() {
  echo "test_trusted_full_and_incremental_rebuild_emit_bound_seal:"
  local base="$TEST_ROOT/emission"
  local state="$base/vault"
  local seal="$state/index/index-seal.json" before after
  init_fixture "$base" || {
    fail "seal emission fixtureを構築できる"
    return
  }
  if ! validate_seal_contract "$seal" "$state/index/vault.sqlite" 2>/dev/null; then
    fail "trusted full rebuildはDB fsync/validation後にbounded v1 sealを発行する"
    return
  fi
  before="$(sha256_file "$seal")"
  record_event "$state" \
    "49000000-0000-4000-8000-000000000002" \
    "2026-08-13T00:01:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "incremental seal fixtureを同期できる"
    return
  }
  if run_cli "$state" rebuild-index --incremental >/dev/null 2>&1 \
    && validate_seal_contract "$seal" "$state/index/vault.sqlite" 2>/dev/null; then
    after="$(sha256_file "$seal")"
    if [[ "$before" != "$after" ]]; then
      pass "full/incremental trusted rebuildは現在DB・source・policy generationへsealを更新する"
    else
      fail "full/incremental trusted rebuildは現在DB・source・policy generationへsealを更新する"
    fi
  else
    fail "full/incremental trusted rebuildは現在DB・source・policy generationへsealを更新する"
  fi
}

test_seal_missing_and_tampered_fail_without_legacy_fallback() {
  echo "test_seal_missing_and_tampered_fail_without_legacy_fallback:"
  local base="$TEST_ROOT/fail-closed"
  local state="$base/vault" episode
  init_fixture "$base" || {
    fail "fail-closed fixtureを構築できる"
    return
  }
  episode="$(episode_id_for_fixture "$state")"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" <<'PY' 2>/dev/null
import pathlib
import signal
import sys

import reporting
from vault import VaultError

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
episode_id = sys.argv[2]
seal = root / "index" / "index-seal.json"
called = []

def legacy(*_args, **_kwargs):
    called.append(True)
    raise AssertionError("legacy full graph verification must not run")

reporting._verify_graph = legacy
seal.unlink()
try:
    reporting.inspect_episode(root, episode_id, None)
except VaultError as error:
    assert "seal" in str(error).lower()
    assert "rebuild" in str(error).lower()
else:
    raise AssertionError("missing seal was accepted")
assert not called
PY
  then
    pass "missing sealはfull verify fallbackなしで明示rebuildを要求する"
  else
    fail "missing sealはfull verify fallbackなしで明示rebuildを要求する"
  fi

  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "tamper fixtureのsealを再発行できる"
    return
  }
  if [[ ! -f "$state/index/index-seal.json" ]]; then
    fail "tamper fixtureのsealを読み取れる"
    return
  fi
  python3 - "$state/index/index-seal.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
value["source_inventory"]["event_count"] += 1
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  if run_cli "$state" inspect "$episode" --json >"$base/out" 2>"$base/err"; then
    fail "MAC不一致のsealを拒否する"
  elif grep -Eiq "seal.*(invalid|rebuild|mismatch|integrity)" "$base/err"; then
    pass "MAC不一致のsealを固定診断でfail closedにする"
  else
    fail "MAC不一致のsealを固定診断でfail closedにする"
  fi
}

test_seal_file_security_contract() {
  echo "test_seal_file_security_contract:"
  local base="$TEST_ROOT/security"
  local state="$base/vault"
  local seal="$state/index/index-seal.json" saved="$base/saved.seal"
  local episode outside="$base/outside.seal"
  init_fixture "$base" || {
    fail "seal security fixtureを構築できる"
    return
  }
  if [[ ! -f "$seal" ]]; then
    fail "seal security fixtureを読み取れる"
    return
  fi
  episode="$(episode_id_for_fixture "$state")"
  cp "$seal" "$saved" || {
    fail "seal security fixtureを保存できる"
    return
  }

  chmod 0644 "$seal"
  if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
    fail "group/world-readable sealを拒否する"
    return
  fi
  cp "$saved" "$seal"
  chmod 0600 "$seal"
  ln "$seal" "$outside"
  if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
    fail "hardlinked sealを拒否する"
    return
  fi
  rm "$outside"
  mv "$seal" "$outside"
  ln -s "$outside" "$seal"
  if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
    fail "symlink sealを拒否する"
    return
  fi
  rm "$seal"
  cp "$saved" "$seal"
  chmod 0600 "$seal"
  python3 - "$seal" <<'PY'
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("ab") as stream:
    stream.write(b" " * 65537)
PY
  if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
    fail "oversized sealを拒否する"
    return
  fi
  cp "$saved" "$seal"
  chmod 0600 "$seal"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" <<'PY' 2>/dev/null
import os
import pathlib
import sys
from unittest import mock

import evidence_index
from vault import VaultError

root = pathlib.Path(sys.argv[1])
with mock.patch.object(evidence_index.os, "geteuid", return_value=os.geteuid() + 1):
    try:
        evidence_index.load_index_seal(root)
    except VaultError as error:
        assert "seal" in str(error).lower()
        assert "unsafe" in str(error).lower()
    else:
        raise AssertionError("foreign-owner seal was accepted")
PY
  then
    pass "sealはowner-only regular nlink=1かつ64KiB以下だけを受理する"
  else
    fail "sealはowner-only regular nlink=1かつ64KiB以下だけを受理する"
  fi
}

test_source_forget_database_and_relationship_changes_invalidate_seal() {
  echo "test_source_forget_database_and_relationship_changes_invalidate_seal:"
  local base="$TEST_ROOT/invalidation"
  local state="$base/vault" episode
  local seal="$state/index/index-seal.json" generation_before generation_after
  init_fixture "$base" || {
    fail "seal invalidation fixtureを構築できる"
    return
  }
  if [[ ! -f "$seal" ]]; then
    fail "seal invalidation fixtureを読み取れる"
    return
  fi
  episode="$(episode_id_for_fixture "$state")"
  generation_before="$(python3 - "$seal" <<'PY' 2>/dev/null
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["relationship_projection"]["generation"])
PY
)"

  record_event "$state" \
    "49000000-0000-4000-8000-000000000003" \
    "2026-08-13T00:02:00Z"
  run_cli "$state" sync >/dev/null 2>&1 || {
    fail "source invalidation fixtureを同期できる"
    return
  }
  if run_cli "$state" report --last 365d --json >/dev/null 2>&1; then
    fail "source inventory変更後のstale sealを拒否する"
    return
  fi
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1 || {
    fail "source変更後にincremental rebuildできる"
    return
  }
  episode="$(episode_id_for_fixture "$state")"
  local forget_seal_before forget_seal_after
  forget_seal_before="$(sha256_file "$seal")"
  run_cli "$state" forget "$episode" --json >/dev/null 2>&1 || {
    fail "forget seal fixtureを作成できる"
    return
  }
  forget_seal_after="$(sha256_file "$seal" 2>/dev/null)"
  if [[ "$forget_seal_before" == "$forget_seal_after" ]] \
    || ! run_cli "$state" report --last 365d --json >/dev/null 2>&1; then
    fail "forget mutationは新forget inventoryへatomic resealする"
    return
  fi
  run_cli "$state" rebuild-index --incremental >/dev/null 2>&1 || {
    fail "forget変更後にsealを再発行できる"
    return
  }
  python3 - "$state/index/vault.sqlite" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute(
    "INSERT INTO derived_state(namespace,key,policy_version,value_json) "
    "VALUES ('seal-test','tamper','default-v1','{}')"
)
connection.commit()
connection.close()
PY
  if run_cli "$state" report --last 365d --json >/dev/null 2>&1; then
    fail "DB bytes/identity変更後のstale sealを拒否する"
    return
  fi
  run_cli "$state" rebuild-index >/dev/null 2>&1 || {
    fail "DB変更後にfull rebuildでsealを復旧できる"
    return
  }
  if ! run_cli "$state" rebuild-relationships >/dev/null 2>&1; then
    fail "relationship rebuildでsealを再発行できる"
    return
  fi
  generation_after="$(python3 - "$seal" <<'PY' 2>/dev/null
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["relationship_projection"]["generation"])
PY
)"
  if [[ -n "$generation_before" && -n "$generation_after" \
    && "$generation_before" != "$generation_after" ]]; then
    pass "source/forget/index変更を拒否しrelationship rebuildは新generationへsealする"
  else
    fail "source/forget/index変更を拒否しrelationship rebuildは新generationへsealする"
  fi
}

test_hot_inspect_uses_sealed_read_without_full_graph_or_chunk_materialization() {
  echo "test_hot_inspect_uses_sealed_read_without_full_graph_or_chunk_materialization:"
  local base="$TEST_ROOT/hot-query"
  local state="$base/vault" episode
  init_fixture "$base" || {
    fail "sealed hot query fixtureを構築できる"
    return
  }
  episode="$(episode_id_for_fixture "$state")"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" <<'PY' 2>/dev/null
import pathlib
import signal
import sys

import reporting

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
episode_id = sys.argv[2]

def forbidden(*_args, **_kwargs):
    raise AssertionError("hot sealed read used legacy full materialization")

reporting._verify_graph = forbidden
reporting._authenticated_chunks = forbidden
reporting._edges_by_episode = forbidden
value = reporting.inspect_episode(root, episode_id, None)
assert value["card"]["episode_id"] == episode_id
PY
  then
    pass "hot inspectはseal+inventory+対象Episodeだけを認証し_verify_graph/load_chunksを呼ばない"
  else
    fail "hot inspectはseal+inventory+対象Episodeだけを認証し_verify_graph/load_chunksを呼ばない"
  fi
}

test_database_digest_is_streamed_with_bounded_reads() {
  echo "test_database_digest_is_streamed_with_bounded_reads:"
  local base="$TEST_ROOT/streaming"
  local state="$base/vault"
  init_fixture "$base" || {
    fail "streaming fixtureを構築できる"
    return
  }
  if PYTHONPATH="$PLUGIN_DIR/scripts" python3 - "$state" <<'PY' 2>/dev/null
import os
import pathlib
import signal
import sys
from unittest import mock

import evidence_index

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
database = root / "index" / "vault.sqlite"
original_read = os.read
reads = []

def bounded_read(descriptor, size):
    reads.append(size)
    assert 0 < size <= 1024 * 1024
    return original_read(descriptor, size)

with mock.patch.object(evidence_index.os, "read", bounded_read):
    digest = evidence_index._stream_file_sha256(database)
assert digest.startswith("sha256:")
assert reads and reads[-1] > 0
PY
  then
    pass "DB digestは全量read_bytesせず1MiB以下の固定chunkでstream検証する"
  else
    fail "DB digestは全量read_bytesせず1MiB以下の固定chunkでstream検証する"
  fi
}

test_failed_rebuild_keeps_database_and_seal_as_one_atomic_pair() {
  echo "test_failed_rebuild_keeps_database_and_seal_as_one_atomic_pair:"
  local base="$TEST_ROOT/atomic-pair"
  local state="$base/vault"
  local db="$state/index/vault.sqlite" seal="$state/index/index-seal.json"
  local db_before seal_before db_after seal_after
  init_fixture "$base" || {
    fail "atomic DB+seal fixtureを構築できる"
    return
  }
  db_before="$(sha256_file "$db")"
  seal_before="$(sha256_file "$seal" 2>/dev/null)" || {
    fail "atomic fixtureのsealを読み取れる"
    return
  }
  python3 - "$state/index/imported-chunks.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
first = next(iter(value["chunks"].values()))
first["blob_oid"] = "f" * 40
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  if run_cli "$state" rebuild-index >/dev/null 2>&1; then
    fail "invalid sourceによるrebuild失敗を要求する"
    return
  fi
  db_after="$(sha256_file "$db")"
  seal_after="$(sha256_file "$seal" 2>/dev/null)"
  if [[ "$db_before" == "$db_after" && "$seal_before" == "$seal_after" ]]; then
    pass "trusted rebuild失敗時は旧DBと旧sealをatomic pairとして保持する"
  else
    fail "trusted rebuild失敗時は旧DBと旧sealをatomic pairとして保持する"
  fi
}

test_docs_define_seal_threat_model_and_per_read_guarantee() {
  echo "test_docs_define_seal_threat_model_and_per_read_guarantee:"
  if python3 - \
    "$PLUGIN_DIR/docs/ARCHITECTURE.md" \
    "$PLUGIN_DIR/docs/DECISIONS.md" <<'PY' 2>/dev/null
import pathlib
import sys

architecture = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").lower()
decisions = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").lower()
combined = architecture + "\n" + decisions
required = (
    "authenticated evidence index seal",
    "trusted writer boundary",
    "before and after",
    "no full verification fallback",
    "explicit rebuild",
    "hmac-sha256",
    "index/index-seal.json",
    "source inventory",
    "relationship policy",
    "projection generation",
)
assert all(item in combined for item in required)
assert (
    "does not protect" in combined
    and "local process" in combined
    and "correlation key" in combined
)
assert "per-read" in combined
PY
  then
    pass "docsはwriter/per-read保証・非保証・fallback禁止・再構築手順を固定する"
  else
    fail "docsはwriter/per-read保証・非保証・fallback禁止・再構築手順を固定する"
  fi
}

test_seal_binds_internal_generation_and_authorized_envelope_key() {
  echo "test_seal_binds_internal_generation_and_authorized_envelope_key:"
  local base="$TEST_ROOT/generation-key"
  local state="$base/vault"
  local seal="$state/index/index-seal.json"
  init_fixture "$base" || {
    fail "generation/key fixtureを構築できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$seal" <<'PY' 2>/dev/null
import json
import pathlib
import signal
import sys
from unittest import mock

import evidence_index
from vault import VaultError

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
seal = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
connection = evidence_index._open_readonly(root / evidence_index.DATABASE_PATH)
try:
    assert evidence_index.read_database_generation(connection) == seal["database"]["generation"]
finally:
    connection.close()

with mock.patch.object(evidence_index, "authorized_key", return_value=b"x" * 32):
    try:
        evidence_index.load_index_seal(root)
    except VaultError as error:
        assert "local correlation key does not match the envelope" in str(error)
    else:
        raise AssertionError("seal accepted a key not authorized by the envelope")
PY
  then
    pass "seal generationはDB内部世代と一致しMAC鍵はlocal hash.keyとenvelope双方へ拘束する"
  else
    fail "seal generationはDB内部世代と一致しMAC鍵はlocal hash.keyとenvelope双方へ拘束する"
  fi
}

test_wal_sidecars_fail_closed_without_mutation() {
  echo "test_wal_sidecars_fail_closed_without_mutation:"
  local base="$TEST_ROOT/wal"
  local state="$base/vault" episode sidecar
  init_fixture "$base" || {
    fail "WAL sidecar fixtureを構築できる"
    return
  }
  episode="$(episode_id_for_fixture "$state")"
  for sidecar in vault.sqlite-wal vault.sqlite-shm vault.sqlite-journal; do
    printf '%s\n' "unsafe-sidecar-$sidecar" >"$state/index/$sidecar"
    chmod 0600 "$state/index/$sidecar"
    if run_cli "$state" inspect "$episode" --json >/dev/null 2>&1; then
      fail "SQLite sidecar $sidecar をsealed readで拒否する"
      return
    fi
    if [[ "$(cat "$state/index/$sidecar")" != "unsafe-sidecar-$sidecar" ]]; then
      fail "SQLite sidecar拒否時にmutationしない"
      return
    fi
    rm "$state/index/$sidecar"
  done
  pass "WAL/SHM/journal sidecarはmutationせずfail closedにする"
}

test_typed_episode_api_checks_source_before_and_after_outside_long_lock() {
  echo "test_typed_episode_api_checks_source_before_and_after_outside_long_lock:"
  local base="$TEST_ROOT/typed-read"
  local state="$base/vault" episode
  init_fixture "$base" || {
    fail "typed sealed read fixtureを構築できる"
    return
  }
  episode="$(episode_id_for_fixture "$state")"
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" "$episode" <<'PY' 2>/dev/null
import contextlib
import inspect
import pathlib
import signal
import sys
from unittest import mock

import evidence_index
from vault import VaultError

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
episode_id = sys.argv[2]
api = evidence_index.read_sealed_episode
assert tuple(inspect.signature(api).parameters) == (
    "root", "policy_version", "episode_id",
)

lock_active = False
lock_entries = 0
real_projection = evidence_index._read_episode_projection
real_inventory = evidence_index._validate_sealed_source_inventory
inventory_calls = 0

@contextlib.contextmanager
def short_lock(_root):
    global lock_active, lock_entries
    assert not lock_active
    lock_active = True
    lock_entries += 1
    try:
        yield
    finally:
        lock_active = False

def bounded_projection(*args, **kwargs):
    assert not lock_active
    return real_projection(*args, **kwargs)

def drift_on_second(*args, **kwargs):
    global inventory_calls
    inventory_calls += 1
    if inventory_calls == 2:
        raise VaultError("source inventory changed during sealed read")
    return real_inventory(*args, **kwargs)

with mock.patch.object(evidence_index, "vault_lock", short_lock), \
     mock.patch.object(evidence_index, "_read_episode_projection", bounded_projection), \
     mock.patch.object(evidence_index, "_validate_sealed_source_inventory", drift_on_second):
    try:
        api(root, "default-v1", episode_id)
    except VaultError as error:
        assert "source inventory changed during sealed read" in str(error)
    else:
        raise AssertionError("source drift was accepted")
assert inventory_calls == 2
assert lock_entries <= 2
PY
  then
    pass "typed Episode APIはgeneric callbackなしでsourceを前後検証しDB scan中lockを保持しない"
  else
    fail "typed Episode APIはgeneric callbackなしでsourceを前後検証しDB scan中lockを保持しない"
  fi
}

test_purge_snapshots_database_and_seal_for_exact_rollback() {
  echo "test_purge_snapshots_database_and_seal_for_exact_rollback:"
  local base="$TEST_ROOT/purge-snapshot"
  local state="$base/vault"
  init_fixture "$base" || {
    fail "purge seal snapshot fixtureを構築できる"
    return
  }
  if PATH="$FAKE_BIN:$PATH" PYTHONPATH="$PLUGIN_DIR/scripts" \
    python3 - "$state" <<'PY' 2>/dev/null
import os
import hashlib
import pathlib
import signal
import stat
import sys
from unittest import mock

import retention
import evidence_index

signal.alarm(15)
root = pathlib.Path(sys.argv[1])
database = root / "index" / "vault.sqlite"
seal = root / "index" / "index-seal.json"
paths = retention._index_projection_snapshot_paths(root)
assert paths == (database, seal)
before = {
    path: (hashlib.sha256(path.read_bytes()).hexdigest(), stat.S_IMODE(path.stat().st_mode))
    for path in paths
}
original_read_bytes = pathlib.Path.read_bytes

def bounded_read_bytes(path):
    if pathlib.Path(path) == database:
        raise AssertionError("large SQLite rollback must not use read_bytes")
    return original_read_bytes(path)

with mock.patch.object(pathlib.Path, "read_bytes", bounded_read_bytes):
    snapshots = retention._snapshot_index_projection(root)
assert all(backup.parent == root / retention.PURGE_ROLLBACK_DIRECTORY for _, backup, _ in snapshots)
database.write_bytes(b"mutated database")
seal.unlink()
errors = retention._restore_index_projection_snapshots(root, snapshots)
assert errors == []
for path, (digest, mode) in before.items():
    if path == database:
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest
    assert stat.S_IMODE(path.stat().st_mode) == mode
restored_seal = evidence_index.load_index_seal(root)
connection = evidence_index._open_sealed_readonly(root, restored_seal)
connection.close()
PY
  then
    pass "purgeはDBをdisk-backed exact復元しsealを新inodeへ再発行する"
  else
    fail "purgeはDBをdisk-backed exact復元しsealを新inodeへ再発行する"
  fi
}

echo "=== Flight Recorder Authenticated Index Seal Tests ==="
TESTS=(
  test_trusted_full_and_incremental_rebuild_emit_bound_seal
  test_seal_missing_and_tampered_fail_without_legacy_fallback
  test_seal_file_security_contract
  test_source_forget_database_and_relationship_changes_invalidate_seal
  test_hot_inspect_uses_sealed_read_without_full_graph_or_chunk_materialization
  test_database_digest_is_streamed_with_bounded_reads
  test_failed_rebuild_keeps_database_and_seal_as_one_atomic_pair
  test_docs_define_seal_threat_model_and_per_read_guarantee
  test_seal_binds_internal_generation_and_authorized_envelope_key
  test_wal_sidecars_fail_closed_without_mutation
  test_typed_episode_api_checks_source_before_and_after_outside_long_lock
  test_purge_snapshots_database_and_seal_for_exact_rollback
)
for test_name in "${TESTS[@]}"; do
  if [[ -z "${INDEX_SEAL_TEST_FILTER:-}" \
    || "$test_name" == *"$INDEX_SEAL_TEST_FILTER"* ]]; then
    "$test_name"
  fi
done
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
