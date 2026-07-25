#!/usr/bin/env bash
# Daily scheduler contract tests (external dependencies: git and python3).
# launchctl/systemctl are always supplied by fixtures; these tests never touch
# the host scheduler.
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

init_remote() {
  local remote="$1"
  git init -q --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
}

run_cli() {
  local platform="$1" state="$2" home="$3" config_home="$4" call_log="$5"
  shift 5
  PATH="$FAKE_BIN:$PATH" \
    HOME="$home" \
    XDG_CONFIG_HOME="$config_home" \
    FLIGHT_RECORDER_STATE_DIR="$state" \
    FLIGHT_RECORDER_SCHEDULER_PLATFORM="$platform" \
    AGENT_FLIGHT_RECORDER_TEST_SCHEDULER_RUNTIME_PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
    FLIGHT_RECORDER_SCHEDULER_CALL_LOG="$call_log" \
    FLIGHT_RECORDER_SCHEDULER_MANAGER_STATE="$call_log.manager" \
    "$CLI" "$@"
}

init_vault() {
  local platform="$1" state="$2" home="$3" config_home="$4"
  local call_log="$5" remote="$6" recovery="$7"
  make_identity "$recovery"
  run_cli "$platform" "$state" "$home" "$config_home" "$call_log" init \
    --remote "$remote" \
    --recovery-recipient "$(recipient_of "$recovery")"
}

record_event() {
  local state="$1" now="$2"
  FLIGHT_RECORDER_STATE_DIR="$state" \
    AGENT_FLIGHT_RECORDER_NOW="$now" \
    "$RECORDER" --harness claude-code <"$FIXTURE" >/dev/null 2>&1
}

count_remote_chunks() {
  local remote="$1"
  git --git-dir="$remote" ls-tree -r --name-only main 2>/dev/null \
    | grep -Ec '^devices/[0-9a-f-]+/[0-9]{4}/[0-9]{2}/[0-9]{2}/[0-9a-f]{64}\.jsonl\.age$' \
    || true
}

test_macos_install_contract() {
  echo "test_macos_install_contract:"
  local base="$TEST_ROOT/mac fixture"
  local state="$base/vault state" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/scheduler-calls.log"
  local agents="$home/Library/LaunchAgents"
  local managed="$agents/io.agent-harness.flight-recorder.sync.plist"
  local unrelated="$agents/com.example.user-owned.plist"
  local status_json="$base/status.json"
  mkdir -p "$base" "$agents" "$config_home"
  : >"$call_log"
  printf '%s\n' 'user-owned-launch-agent' >"$unrelated"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1 || {
    fail "macOS fixture Vaultを初期化できる"
    return
  }

  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 \
    && grep -qx '/scheduler/' "$state/.gitignore" \
    && python3 - "$managed" "$CLI" "$state" <<'PY' 2>/dev/null
import pathlib
import plistlib
import sys

path, cli, state = map(pathlib.Path, sys.argv[1:])
value = plistlib.loads(path.read_bytes())
assert value["Label"] == "io.agent-harness.flight-recorder.sync"
assert value["ProgramArguments"] == [str(cli), "scheduler", "run"]
assert value["EnvironmentVariables"]["FLIGHT_RECORDER_STATE_DIR"] == str(state)
assert value["EnvironmentVariables"]["PATH"]
assert value["RunAtLoad"] is True
calendar = value["StartCalendarInterval"]
assert calendar["Hour"] in range(24)
assert calendar["Minute"] in range(60)
assert cli.is_absolute()
assert state.is_absolute()
PY
  then
    pass "launchd plistは絶対pathを使いlocal scheduler stateをGit除外する"
  else
    fail "launchd plistは絶対pathを使いlocal scheduler stateをGit除外する"
  fi

  local first
  first="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$managed" 2>/dev/null)"
  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 \
    && [[ "$first" == "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$managed" 2>/dev/null)" ]] \
    && run_cli macos "$state" "$home" "$config_home" "$call_log" \
      status --json >"$status_json" 2>/dev/null \
    && python3 - "$status_json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

scheduler = json.loads(pathlib.Path(sys.argv[1]).read_text())["scheduler"]
assert scheduler["configured"] is True
assert scheduler["platform"] == "macos"
assert scheduler["state"] in {"idle", "healthy"}
PY
  then
    pass "launchd installは冪等でstatusへmanaged設定を表示する"
  else
    fail "launchd installは冪等でstatusへmanaged設定を表示する"
  fi
}

test_macos_uninstall_and_collision_contract() {
  echo "test_macos_uninstall_and_collision_contract:"
  local base="$TEST_ROOT/mac fixture"
  local state="$base/vault state" home="$base/home" config_home="$base/config"
  local call_log="$base/scheduler-calls.log"
  local agents="$home/Library/LaunchAgents"
  local managed="$agents/io.agent-harness.flight-recorder.sync.plist"
  local unrelated="$agents/com.example.user-owned.plist"
  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler uninstall >/dev/null 2>&1 \
    && [[ ! -e "$managed" && "$(cat "$unrelated")" == "user-owned-launch-agent" ]] \
    && grep -q $'launchctl\t.*bootstrap' "$call_log" \
    && grep -q $'launchctl\t.*bootout' "$call_log"; then
    pass "launchd uninstallはmanaged plistだけを解除・削除する"
  else
    fail "launchd uninstallはmanaged plistだけを解除・削除する"
  fi

  printf '%s\n' 'colliding-user-config' >"$managed"
  local install_status=0 uninstall_status=0
  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler install >/dev/null 2>&1 || install_status=$?
  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler uninstall >/dev/null 2>&1 || uninstall_status=$?
  if [[ "$install_status" -ne 0 && "$install_status" -ne 2 \
      && "$install_status" -ne 126 && "$install_status" -ne 127 \
      && "$uninstall_status" -ne 0 && "$uninstall_status" -ne 2 \
      && "$uninstall_status" -ne 126 && "$uninstall_status" -ne 127 ]] \
    && [[ "$(cat "$managed")" == "colliding-user-config" \
      && "$(cat "$unrelated")" == "user-owned-launch-agent" ]]; then
    pass "同名の非managed launchd設定はfail-closedで保全する"
  else
    fail "同名の非managed launchd設定はfail-closedで保全する"
  fi
}

test_linux_install_contract() {
  echo "test_linux_install_contract:"
  local base="$TEST_ROOT/linux fixture"
  local state="$base/vault state" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/scheduler-calls.log"
  local units="$config_home/systemd/user"
  local service="$units/agent-harness-flight-recorder-sync.service"
  local timer="$units/agent-harness-flight-recorder-sync.timer"
  local unrelated="$units/example-user.service"
  mkdir -p "$base" "$units"
  : >"$call_log"
  printf '%s\n' 'user-owned-systemd-unit' >"$unrelated"
  init_remote "$remote"
  init_vault linux "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1 || {
    fail "Linux fixture Vaultを初期化できる"
    return
  }

  if run_cli linux "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 \
    && python3 - "$service" "$timer" "$CLI" "$state" \
      "$PLUGIN_DIR/scripts" <<'PY' 2>/dev/null
import configparser
import pathlib
import sys

service_path, timer_path, cli, state, scripts = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(scripts))
from scheduler import _systemd_exec_quote, _systemd_quote

service = configparser.ConfigParser(interpolation=None)
service.optionxform = str
service.read(service_path, encoding="utf-8")
timer = configparser.ConfigParser(interpolation=None)
timer.optionxform = str
timer.read(timer_path, encoding="utf-8")
assert service["Service"]["Type"] == "oneshot"
assert service["Service"]["ExecStart"] == f"{cli} scheduler run"
environment = service["Service"]["Environment"]
assert f'"FLIGHT_RECORDER_STATE_DIR={state}"' in environment
assert "PATH=" in environment
assert timer["Timer"]["OnCalendar"] == "daily"
assert timer["Timer"]["Persistent"].lower() == "true"
assert timer["Install"]["WantedBy"] == "timers.target"
assert cli.is_absolute()
assert state.is_absolute()
escaped_exec = _systemd_exec_quote(
    '/tmp/clone ${HOME}/percent%/quote"x\\y'
)
assert "$${HOME}" in escaped_exec
assert "percent%%" in escaped_exec
assert '\\"' in escaped_exec
assert _systemd_quote("VALUE=${HOME}") == "VALUE=${HOME}"
PY
  then
    pass "systemd user unitは絶対pathとlogin/sleep後missed runを安全に設定する"
  else
    fail "systemd user unitは絶対pathとlogin/sleep後missed runを安全に設定する"
  fi

  local first_service first_timer
  first_service="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$service" 2>/dev/null)"
  first_timer="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$timer" 2>/dev/null)"
  if run_cli linux "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 \
    && [[ "$first_service" == "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$service" 2>/dev/null)" ]] \
    && [[ "$first_timer" == "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$timer" 2>/dev/null)" ]]; then
    pass "systemd timer installは冪等である"
  else
    fail "systemd timer installは冪等である"
  fi
}

test_linux_uninstall_and_collision_contract() {
  echo "test_linux_uninstall_and_collision_contract:"
  local base="$TEST_ROOT/linux fixture"
  local state="$base/vault state" home="$base/home" config_home="$base/config"
  local call_log="$base/scheduler-calls.log"
  local units="$config_home/systemd/user"
  local service="$units/agent-harness-flight-recorder-sync.service"
  local timer="$units/agent-harness-flight-recorder-sync.timer"
  local unrelated="$units/example-user.service"
  if run_cli linux "$state" "$home" "$config_home" "$call_log" \
      scheduler uninstall >/dev/null 2>&1 \
    && [[ ! -e "$service" && ! -e "$timer" \
      && "$(cat "$unrelated")" == "user-owned-systemd-unit" ]] \
    && grep -q $'systemctl\t--user\t.*enable' "$call_log" \
    && grep -q $'systemctl\t--user\t.*disable' "$call_log"; then
    pass "systemd uninstallはmanaged user unitsだけを解除・削除する"
  else
    fail "systemd uninstallはmanaged user unitsだけを解除・削除する"
  fi

  printf '%s\n' 'colliding-user-config' >"$service"
  local install_status=0 uninstall_status=0
  run_cli linux "$state" "$home" "$config_home" "$call_log" \
    scheduler install >/dev/null 2>&1 || install_status=$?
  run_cli linux "$state" "$home" "$config_home" "$call_log" \
    scheduler uninstall >/dev/null 2>&1 || uninstall_status=$?
  if [[ "$install_status" -ne 0 && "$install_status" -ne 2 \
      && "$install_status" -ne 126 && "$install_status" -ne 127 \
      && "$uninstall_status" -ne 0 && "$uninstall_status" -ne 2 \
      && "$uninstall_status" -ne 126 && "$uninstall_status" -ne 127 ]] \
    && [[ "$(cat "$service")" == "colliding-user-config" \
      && "$(cat "$unrelated")" == "user-owned-systemd-unit" ]]; then
    pass "同名の非managed systemd設定はfail-closedで保全する"
  else
    fail "同名の非managed systemd設定はfail-closedで保全する"
  fi
}

test_scheduler_run_reuses_sync_core_and_lock() {
  echo "test_scheduler_run_reuses_sync_core_and_lock:"
  local base="$TEST_ROOT/concurrent"
  local state="$base/vault" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/scheduler-calls.log"
  mkdir -p "$base" "$home" "$config_home"
  : >"$call_log"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1 || {
    fail "多重起動fixture Vaultを初期化できる"
    return
  }
  record_event "$state" "2026-07-25T07:00:00Z"

  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler run >/dev/null 2>&1 &
  local first_pid=$!
  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler run >/dev/null 2>&1 &
  local second_pid=$!
  local first_status=0 second_status=0
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?

  if [[ "$first_status" -eq 0 && "$second_status" -eq 0 \
    && "$(count_remote_chunks "$remote")" == "1" ]]; then
    pass "scheduler runはCLI sync coreとlockを共有し二重publishしない"
  else
    fail "scheduler runはCLI sync coreとlockを共有し二重publishしない"
  fi
}

test_offline_run_is_fail_open_and_visible_in_status() {
  echo "test_offline_run_is_fail_open_and_visible_in_status:"
  local base="$TEST_ROOT/offline"
  local state="$base/vault" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/scheduler-calls.log"
  local entered="$base/remote-entered" release="$base/remote-release"
  local status_json="$base/status.json"
  mkdir -p "$base" "$home" "$config_home"
  : >"$call_log"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1 || {
    fail "offline fixture Vaultを初期化できる"
    return
  }
  record_event "$state" "2026-07-25T08:00:00Z"
  {
    printf '%s\n' '#!/bin/sh'
    printf 'touch "%s"\n' "$entered"
    printf 'while [ ! -e "%s" ]; do sleep 0.01; done\n' "$release"
    printf '%s\n' 'exit 1'
  } >"$remote/hooks/pre-receive"
  chmod +x "$remote/hooks/pre-receive"

  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler run >/dev/null 2>&1 &
  local scheduler_pid=$! attempts=0
  while [[ ! -e "$entered" && "$attempts" -lt 500 ]]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [[ ! -e "$entered" ]]; then
    touch "$release"
    wait "$scheduler_pid" 2>/dev/null || true
    fail "remote失敗fixtureへ到達する"
    return
  fi

  record_event "$state" "2026-07-25T08:01:00Z" &
  local recorder_pid=$!
  sleep 0.5
  if ! kill -0 "$recorder_pid" 2>/dev/null \
    && [[ "$(wc -l <"$state/inbox/events.jsonl" | tr -d ' ')" == "1" ]]; then
    pass "offline sync待機中もharness hookをblockしない"
  else
    fail "offline sync待機中もharness hookをblockしない"
  fi

  touch "$release"
  local scheduler_status=0
  wait "$scheduler_pid" || scheduler_status=$?
  if [[ "$scheduler_status" -eq 0 ]]; then
    pass "schedulerのremote失敗はexit 0でretry stormを起こさない"
  else
    fail "schedulerのremote失敗はexit 0でretry stormを起こさない"
  fi

  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      status --json >"$status_json" 2>/dev/null \
    && python3 - "$status_json" <<'PY' 2>/dev/null
import json
import pathlib
import sys

scheduler = json.loads(pathlib.Path(sys.argv[1]).read_text())["scheduler"]
assert scheduler["state"] == "error"
assert scheduler["last_attempt_at"]
assert scheduler["last_success_at"] is None
assert scheduler["last_error_category"] == "remote"
PY
  then
    pass "offline失敗はscheduler statusへerrorとして残る"
  else
    fail "offline失敗はscheduler statusへerrorとして残る"
  fi
}

test_manager_namespace_collision_contract() {
  echo "test_manager_namespace_collision_contract:"
  local mac_base="$TEST_ROOT/mac-manager-collision"
  local mac_state="$mac_base/vault" mac_home="$mac_base/home"
  local mac_config="$mac_base/config" mac_remote="$mac_base/remote.git"
  local mac_recovery="$mac_base/recovery.agekey"
  local mac_log="$mac_base/calls.log" mac_foreign="$mac_base/foreign.plist"
  mkdir -p "$mac_base" "$mac_home/Library/LaunchAgents" "$mac_config"
  : >"$mac_log"
  init_remote "$mac_remote"
  init_vault macos "$mac_state" "$mac_home" "$mac_config" "$mac_log" \
    "$mac_remote" "$mac_recovery" >/dev/null 2>&1
  printf 'launchd\t%s\n' "$mac_foreign" >"$mac_log.manager"
  local mac_install=0 mac_uninstall=0
  run_cli macos "$mac_state" "$mac_home" "$mac_config" "$mac_log" \
    scheduler install >/dev/null 2>&1 || mac_install=$?
  run_cli macos "$mac_state" "$mac_home" "$mac_config" "$mac_log" \
    scheduler uninstall >/dev/null 2>&1 || mac_uninstall=$?
  if [[ "$mac_install" -ne 0 && "$mac_uninstall" -eq 0 \
    && "$(cat "$mac_log.manager")" == $'launchd\t'"$mac_foreign" ]]; then
    pass "別pathからload済みの同名launchd jobを置換・停止しない"
  else
    fail "別pathからload済みの同名launchd jobを置換・停止しない"
  fi

  local linux_base="$TEST_ROOT/linux-manager-collision"
  local linux_state="$linux_base/vault" linux_home="$linux_base/home"
  local linux_config="$linux_base/config"
  local linux_remote="$linux_base/remote.git"
  local linux_recovery="$linux_base/recovery.agekey"
  local linux_log="$linux_base/calls.log"
  local foreign_units="$linux_base/vendor-units"
  mkdir -p "$linux_base" "$linux_home" "$linux_config" "$foreign_units"
  : >"$linux_log"
  init_remote "$linux_remote"
  init_vault linux "$linux_state" "$linux_home" "$linux_config" "$linux_log" \
    "$linux_remote" "$linux_recovery" >/dev/null 2>&1
  {
    printf 'agent-harness-flight-recorder-sync.service\t%s\n' \
      "$foreign_units/agent-harness-flight-recorder-sync.service"
    printf 'agent-harness-flight-recorder-sync.timer\t%s\n' \
      "$foreign_units/agent-harness-flight-recorder-sync.timer"
  } >"$linux_log.manager"
  local linux_install=0 linux_uninstall=0 before after
  before="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$linux_log.manager")"
  run_cli linux "$linux_state" "$linux_home" "$linux_config" "$linux_log" \
    scheduler install >/dev/null 2>&1 || linux_install=$?
  run_cli linux "$linux_state" "$linux_home" "$linux_config" "$linux_log" \
    scheduler uninstall >/dev/null 2>&1 || linux_uninstall=$?
  after="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$linux_log.manager")"
  if [[ "$linux_install" -ne 0 && "$linux_uninstall" -eq 0 \
    && "$before" == "$after" ]]; then
    pass "別search pathの同名systemd unitsをoverride・disableしない"
  else
    fail "別search pathの同名systemd unitsをoverride・disableしない"
  fi
}

test_manifest_provenance_contract() {
  echo "test_manifest_provenance_contract:"
  local base="$TEST_ROOT/manifest-provenance"
  local state="$base/vault" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/calls.log"
  local managed="$home/Library/LaunchAgents/io.agent-harness.flight-recorder.sync.plist"
  local manifest="$state/scheduler/install.json"
  mkdir -p "$base" "$home/Library/LaunchAgents" "$config_home"
  : >"$call_log"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1
  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler install >/dev/null 2>&1

  local upgrade_status=0
  python3 - "$managed" "$manifest" <<'PY' 2>/dev/null || upgrade_status=$?
import hashlib
import json
import pathlib
import plistlib
import sys

managed, manifest = map(pathlib.Path, sys.argv[1:])
value = plistlib.loads(managed.read_bytes())
value["ProgramArguments"][0] = "/old/clone/scripts/flight-recorder"
data = plistlib.dumps(value, sort_keys=True)
managed.write_bytes(data)
record = json.loads(manifest.read_text())
record["targets"][str(managed)] = hashlib.sha256(data).hexdigest()
manifest.write_text(
    json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
)
PY
  if [[ "$upgrade_status" -eq 0 ]]; then
    run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 || upgrade_status=$?
  fi
  if [[ "$upgrade_status" -eq 0 ]] \
    && python3 - "$managed" "$CLI" <<'PY' 2>/dev/null
import pathlib
import plistlib
import sys

managed, cli = map(pathlib.Path, sys.argv[1:])
assert plistlib.loads(managed.read_bytes())["ProgramArguments"][0] == str(cli)
PY
  then
    pass "manifestで旧clone由来configを証明し安全に更新する"
  else
    fail "manifestで旧clone由来configを証明し安全に更新する"
  fi

  rm -f "$managed"
  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler uninstall >/dev/null 2>&1 \
    && [[ ! -s "$call_log.manager" && ! -e "$manifest" ]]; then
    pass "managed file消失後もmanifestに基づき自身のjobだけを解除する"
  else
    fail "managed file消失後もmanifestに基づき自身のjobだけを解除する"
  fi
}

test_install_transaction_contract() {
  echo "test_install_transaction_contract:"
  local base="$TEST_ROOT/install-transaction"
  local state="$base/vault" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/calls.log"
  local managed="$home/Library/LaunchAgents/io.agent-harness.flight-recorder.sync.plist"
  local manifest="$state/scheduler/install.json"
  mkdir -p "$base" "$home/Library/LaunchAgents" "$config_home"
  : >"$call_log"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1

  FLIGHT_RECORDER_SCHEDULER_TEST_DELAY=0.3 \
    run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 &
  local first_pid=$!
  sleep 0.05
  run_cli macos "$state" "$home" "$config_home" "$call_log" \
    scheduler install >/dev/null 2>&1 &
  local second_pid=$!
  local first_status=0 second_status=0
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?
  if [[ ( ( "$first_status" -eq 0 && "$second_status" -ne 0 ) \
      || ( "$first_status" -ne 0 && "$second_status" -eq 0 ) ) \
    && -e "$managed" && -e "$manifest" \
    && "$(sed -n 's/^launchd	//p' "$call_log.manager")" == "$managed" ]]; then
    pass "同時installはuser-global transaction lockで直列化し成功jobを保つ"
  else
    fail "同時installはuser-global transaction lockで直列化し成功jobを保つ"
  fi

  local race_base="$TEST_ROOT/install-foreign-race"
  local race_state="$race_base/vault" race_home="$race_base/home"
  local race_config="$race_base/config" race_remote="$race_base/remote.git"
  local race_recovery="$race_base/recovery.agekey"
  local race_log="$race_base/calls.log" foreign="$race_base/foreign.plist"
  local race_target="$race_home/Library/LaunchAgents/io.agent-harness.flight-recorder.sync.plist"
  mkdir -p "$race_base" "$race_home/Library/LaunchAgents" "$race_config"
  : >"$race_log"
  init_remote "$race_remote"
  init_vault macos "$race_state" "$race_home" "$race_config" "$race_log" \
    "$race_remote" "$race_recovery" >/dev/null 2>&1
  local race_status=0
  FLIGHT_RECORDER_SCHEDULER_BOOTSTRAP_FAIL_FOREIGN_PATH="$foreign" \
    run_cli macos "$race_state" "$race_home" "$race_config" "$race_log" \
      scheduler install >/dev/null 2>&1 || race_status=$?
  if [[ "$race_status" -ne 0 && ! -e "$race_target" \
    && ! -e "$race_state/scheduler/install.json" \
    && "$(cat "$race_log.manager")" == $'launchd\t'"$foreign" ]]; then
    pass "activation競合時のrollbackは後からloadされたforeign jobを停止しない"
  else
    fail "activation競合時のrollbackは後からloadされたforeign jobを停止しない"
  fi
}

test_scheduler_gitignore_migration_contract() {
  echo "test_scheduler_gitignore_migration_contract:"
  local base="$TEST_ROOT/gitignore-migration"
  local state="$base/vault" home="$base/home" config_home="$base/config"
  local remote="$base/remote.git" recovery="$base/recovery.agekey"
  local call_log="$base/calls.log"
  mkdir -p "$base" "$home/Library/LaunchAgents" "$config_home"
  : >"$call_log"
  init_remote "$remote"
  init_vault macos "$state" "$home" "$config_home" "$call_log" \
    "$remote" "$recovery" >/dev/null 2>&1
  python3 - "$PLUGIN_DIR/scripts" "$state/.gitignore" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from vault import PRE_SCHEDULER_GITIGNORE

pathlib.Path(sys.argv[2]).write_text(PRE_SCHEDULER_GITIGNORE)
PY
  if run_cli macos "$state" "$home" "$config_home" "$call_log" \
      scheduler install >/dev/null 2>&1 \
    && grep -qx '/scheduler/' "$state/.gitignore"; then
    pass "既存managed .gitignoreを移行しscheduler平文をGit対象外に保つ"
  else
    fail "既存managed .gitignoreを移行しscheduler平文をGit対象外に保つ"
  fi
}

echo "=== Flight Recorder Daily Scheduler Tests ==="
test_macos_install_contract
test_macos_uninstall_and_collision_contract
test_linux_install_contract
test_linux_uninstall_and_collision_contract
test_scheduler_run_reuses_sync_core_and_lock
test_offline_run_is_fail_open_and_visible_in_status
test_manager_namespace_collision_contract
test_manifest_provenance_contract
test_install_transaction_contract
test_scheduler_gitignore_migration_contract
echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
