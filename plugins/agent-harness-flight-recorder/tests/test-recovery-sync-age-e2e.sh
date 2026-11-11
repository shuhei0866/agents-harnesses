#!/usr/bin/env bash
# Historical ciphertext stays immutable when a later device joins with recovery.
set -euo pipefail
command -v age >/dev/null && command -v age-keygen >/dev/null || { echo 'SKIP: real age required'; exit 0; }
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
CLI="$PLUGIN/scripts/flight-recorder"
RECOVERY="$TEST_ROOT/recovery key.agekey"
REMOTE="$TEST_ROOT/remote.git"
A="$TEST_ROOT/a"
B="$TEST_ROOT/b"
age-keygen -o "$RECOVERY" >/dev/null 2>&1
git init -q --bare "$REMOTE"
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
FLIGHT_RECORDER_STATE_DIR="$A" "$CLI" init --remote "$REMOTE" --recovery-recipient "$(age-keygen -y "$RECOVERY")"
FLIGHT_RECORDER_STATE_DIR="$A" AGENT_FLIGHT_RECORDER_NOW=2026-07-25T06:00:00Z "$PLUGIN/scripts/record-event" --harness claude-code < "$PLUGIN/tests/fixtures/claude-code-stop.json"
FLIGHT_RECORDER_STATE_DIR="$A" "$CLI" sync
OLD_PATH=$(git -C "$A" ls-files 'devices/*.jsonl.age' 'devices/**/*.jsonl.age' | head -1)
OLD_OID=$(git -C "$A" hash-object "$OLD_PATH")
git clone -q "$REMOTE" "$B"
FLIGHT_RECORDER_STATE_DIR="$B" "$CLI" device join --identity "$RECOVERY"
if age -d -i "$B/keys/device.agekey" "$B/$OLD_PATH" >/dev/null 2>&1; then echo 'FAIL: historical chunk unexpectedly enrolled new identity'; exit 1; fi
if FLIGHT_RECORDER_STATE_DIR="$B" "$CLI" sync >"$TEST_ROOT/without-opt-in.log" 2>&1; then echo 'FAIL: history sync must require explicit opt-in'; exit 1; fi
FLIGHT_RECORDER_STATE_DIR="$B" FLIGHT_RECORDER_RECOVERY_IDENTITY="$RECOVERY" "$CLI" sync
[[ "$(git -C "$B" hash-object "$OLD_PATH")" == "$OLD_OID" ]]
FLIGHT_RECORDER_STATE_DIR="$B" AGENT_FLIGHT_RECORDER_NOW=2026-07-25T06:01:00Z "$PLUGIN/scripts/record-event" --harness codex < "$PLUGIN/tests/fixtures/claude-code-stop.json"
FLIGHT_RECORDER_STATE_DIR="$B" FLIGHT_RECORDER_RECOVERY_IDENTITY="$RECOVERY" "$CLI" sync
FLIGHT_RECORDER_STATE_DIR="$A" "$CLI" sync
PYTHONPATH="$PLUGIN/scripts" TEST_ROOT="$TEST_ROOT" FLIGHT_RECORDER_STATE_DIR="$B" FLIGHT_RECORDER_RECOVERY_IDENTITY="$RECOVERY" python3 - <<'PY'
import json,os,plistlib,stat
from pathlib import Path
from vault import external_recovery_identity,load_config,VaultError
from scheduler import _expected
root=Path(os.environ['FLIGHT_RECORDER_STATE_DIR']);config=load_config(root)
recovery=Path(os.environ['FLIGHT_RECORDER_RECOVERY_IDENTITY'])
mac=_expected(root,'macos')
assert plistlib.loads(next(iter(mac.values())))['EnvironmentVariables']['FLIGHT_RECORDER_RECOVERY_IDENTITY']==str(recovery)
linux=_expected(root,'linux')
service=next(v for k,v in linux.items() if str(k).endswith('.service'))
assert ('FLIGHT_RECORDER_RECOVERY_IDENTITY='+str(recovery)).encode() in service
for bad in ['relative.agekey', str(root/'keys/device.agekey')]:
 os.environ['FLIGHT_RECORDER_RECOVERY_IDENTITY']=bad
 try: external_recovery_identity(root,config)
 except VaultError: pass
 else: raise AssertionError('unsafe identity accepted')
os.environ['FLIGHT_RECORDER_RECOVERY_IDENTITY']=str(recovery)
recovery.chmod(0o644)
try:
 try: external_recovery_identity(root,config)
 except VaultError: pass
 else: raise AssertionError('shared identity accepted')
finally: recovery.chmod(0o600)
link=recovery.parent/'link.agekey';link.symlink_to(recovery)
os.environ['FLIGHT_RECORDER_RECOVERY_IDENTITY']=str(link)
try: external_recovery_identity(root,config)
except VaultError: pass
else: raise AssertionError('symlink identity accepted')
assert len(list((root/'cache/imported').rglob('*.jsonl')))==2
assert config['vault_id']==json.loads((Path(os.environ['TEST_ROOT'])/'a/vault.json').read_text())['vault_id']
print('PASS: explicit historical recovery, immutable ciphertext, scheduler paths, unsafe-key rejection')
PY
if git --git-dir="$REMOTE" ls-tree -r --name-only main | grep -Eq '(agekey|hash\.key|scheduler/|cache/)'; then echo 'FAIL: local-only state published'; exit 1; fi
echo 'PASS: recovery identity never enters Git Vault'
