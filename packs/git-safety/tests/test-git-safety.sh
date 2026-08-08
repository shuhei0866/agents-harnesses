#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PACK_DIR/bin/git-safety"

PASS=0
FAIL=0
for dependency in jq shasum git python3 mktemp; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "required command not found: $dependency" >&2
    exit 1
  fi
done
TMPDIR_TEST="$(mktemp -d)" || {
  echo "mktemp -d failed" >&2
  exit 1
}
if [ -z "$TMPDIR_TEST" ] || [ ! -d "$TMPDIR_TEST" ]; then
  echo "mktemp -d did not create a directory" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  [ $# -lt 2 ] || echo "    $2"
  FAIL=$((FAIL + 1))
}

run_cli() {
  python3 "$CLI" "$@"
}

new_case() {
  CASE_DIR="$TMPDIR_TEST/$1"
  SETTINGS="$CASE_DIR/home/.claude/settings.json"
  DATA_DIR="$CASE_DIR/data/git-safety-pack"
  mkdir -p "$(dirname "$SETTINGS")" "$(dirname "$DATA_DIR")"
}

assert_json() {
  local desc="$1" file="$2" query="$3"
  if jq -e "$query" "$file" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc" "query: $query"
  fi
}

echo "=== install: 安全で冪等な settings 配線 ==="

new_case install
if run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  pass "新規環境へ install できる"
else
  fail "新規環境へ install できる"
fi

assert_json "4 個の Bash hook を登録する" "$SETTINGS" \
  '[.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("git-safety-pack/runtime/run-guard"))] | length == 4'
assert_json "インストール所有者マーカーを作る" "$DATA_DIR/.git-safety-pack.json" \
  '.product == "agents-harnesses/git-safety-pack"'
assert_json "advisory mode を保存する" "$DATA_DIR/config.json" '.mode == "advisory"'
permission_failures=$(python3 - "$DATA_DIR" <<'PY'
import stat, sys
from pathlib import Path

root = Path(sys.argv[1])
paths = [root / "runtime" / "run-guard", *sorted((root / "guards").iterdir())]
for path in paths:
    mode = stat.S_IMODE(path.stat().st_mode)
    if not mode & stat.S_IXUSR or mode & (stat.S_IXGRP | stat.S_IXOTH):
        print(f"{path.name}:{mode:o}")
PY
)
if [ -z "$permission_failures" ]; then
  pass "copied runtime はownerだけが実行できる"
else
  fail "copied runtime はownerだけが実行できる" "unexpected modes: $permission_failures"
fi

before_settings=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
if run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  after_settings=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
  if [ "$before_settings" = "$after_settings" ]; then
    pass "同じ install の再実行は settings を変更しない"
  else
    fail "同じ install の再実行は settings を変更しない"
  fi
else
  fail "同じ install を再実行できる"
fi

new_case preserve
cat > "$SETTINGS" <<'JSON'
{
  "env": {"KEEP_ME": "yes"},
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "/existing/hook"}]
      }
    ]
  }
}
JSON
if run_cli install --mode enforce --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  assert_json "既存の設定と hook を保持する" "$SETTINGS" \
    '.env.KEEP_ME == "yes" and ([.hooks.PreToolUse[]?.hooks[]?.command] | index("/existing/hook") != null)'
  assert_json "enforce mode を保存する" "$DATA_DIR/config.json" '.mode == "enforce"'
  backup_count=$(find "$(dirname "$SETTINGS")" -maxdepth 1 -name 'settings.json.git-safety-backup.*' | wc -l | tr -d ' ')
  if [ "$backup_count" -ge 1 ]; then pass "既存 settings のバックアップを作る"; else fail "既存 settings のバックアップを作る"; fi
else
  fail "既存 settings へ install できる"
fi

echo ""
echo "=== dry-run / 異常系: ユーザーデータを変更しない ==="

new_case dry_run
if run_cli install --dry-run --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null \
  && [ ! -e "$SETTINGS" ] && [ ! -e "$DATA_DIR" ]; then
  pass "install --dry-run はファイルを作らない"
else
  fail "install --dry-run はファイルを作らない"
fi

new_case malformed
printf '{ broken json\n' > "$SETTINGS"
malformed_before=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
if run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "壊れた settings は安全に拒否する"
else
  malformed_after=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
  if [ "$malformed_before" = "$malformed_after" ] && [ ! -e "$DATA_DIR" ]; then
    pass "壊れた settings は上書きせず拒否する"
  else
    fail "壊れた settings は上書きせず拒否する"
  fi
fi

new_case invalid_mode
if run_cli install --mode observe --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "未知の mode を拒否する"
elif [ ! -e "$SETTINGS" ] && [ ! -e "$DATA_DIR" ]; then
  pass "未知の mode は無変更で拒否する"
else
  fail "未知の mode は無変更で拒否する"
fi

CASE_DIR="$TMPDIR_TEST/overlapping_install"
SETTINGS="$CASE_DIR/profile/sub/../settings.json"
DATA_DIR="$CASE_DIR/profile"
mkdir -p "$CASE_DIR"
if run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "data directory 内の settings path を拒否する"
elif [ ! -e "$DATA_DIR" ]; then
  pass "危険な settings/data 重複は無変更で拒否する"
else
  fail "危険な settings/data 重複は無変更で拒否する"
fi

new_case symlink
REAL_SETTINGS="$CASE_DIR/real-settings.json"
printf '{}\n' > "$REAL_SETTINGS"
ln -s "$REAL_SETTINGS" "$SETTINGS"
real_before=$(shasum -a 256 "$REAL_SETTINGS" | awk '{print $1}')
if run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "settings symlink を拒否する"
else
  real_after=$(shasum -a 256 "$REAL_SETTINGS" | awk '{print $1}')
  if [ -L "$SETTINGS" ] && [ "$real_before" = "$real_after" ] && [ ! -e "$DATA_DIR" ]; then
    pass "settings symlink とリンク先を変更せず拒否する"
  else
    fail "settings symlink とリンク先を変更せず拒否する"
  fi
fi

new_case permissions
printf '{}\n' > "$SETTINGS"
chmod 600 "$SETTINGS"
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
settings_mode=$(python3 -c \
  'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' \
  "$SETTINGS")
if [ "$settings_mode" = "600" ]; then
  pass "既存 settings の permission を維持する"
else
  fail "既存 settings の permission を維持する" "mode: $settings_mode"
fi

echo ""
echo "=== runtime: advisory / enforce を既存ガードへ正しく渡す ==="

new_case runtime
git -C "$CASE_DIR" init -q -b main
git -C "$CASE_DIR" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m init
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
INPUT=$(jq -n --arg cwd "$CASE_DIR" '{cwd:$cwd,tool_input:{command:"git commit -m test"}}')
ADVISORY_OUT=$(printf '%s\n' "$INPUT" | "$DATA_DIR/runtime/run-guard" commit-guard)
if echo "$ADVISORY_OUT" | jq -e \
  '.hookSpecificOutput.permissionDecision == "allow" and (.hookSpecificOutput.additionalContext | contains("WARNING"))' >/dev/null 2>&1; then
  pass "advisory は通常リスクを警告つきで許可する"
else
  fail "advisory は通常リスクを警告つきで許可する" "output: $ADVISORY_OUT"
fi

run_cli install --mode enforce --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
ENFORCE_OUT=$(printf '%s\n' "$INPUT" | "$DATA_DIR/runtime/run-guard" commit-guard)
if echo "$ENFORCE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "enforce は通常リスクも遮断する"
else
  fail "enforce は通常リスクも遮断する" "output: $ENFORCE_OUT"
fi

CRITICAL_INPUT=$(jq -n --arg cwd "$CASE_DIR" '{cwd:$cwd,tool_input:{command:"git commit --no-verify -m test"}}')
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
CRITICAL_OUT=$(printf '%s\n' "$CRITICAL_INPUT" | "$DATA_DIR/runtime/run-guard" commit-guard)
if echo "$CRITICAL_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "advisory でも重大操作は遮断する"
else
  fail "advisory でも重大操作は遮断する" "output: $CRITICAL_OUT"
fi

CASE_DIR="$TMPDIR_TEST/path with spaces 日本語"
SETTINGS="$CASE_DIR/home space/.claude/settings.json"
DATA_DIR="$CASE_DIR/data space/git-safety-pack"
mkdir -p "$(dirname "$SETTINGS")" "$(dirname "$DATA_DIR")"
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
INSTALLED_COMMAND=$(jq -r \
  '.hooks.PreToolUse[]?.hooks[]? | select(.command | contains("commit-guard")) | .command' \
  "$SETTINGS")
SPACE_OUT=$(printf '%s\n' "$CRITICAL_INPUT" | bash -c "$INSTALLED_COMMAND")
if echo "$SPACE_OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "空白とUnicodeを含む導入先でもsettings経由でguardを実行できる"
else
  fail "空白とUnicodeを含む導入先でもsettings経由でguardを実行できる" "command: $INSTALLED_COMMAND"
fi

echo ""
echo "=== doctor / uninstall: 検査と所有範囲限定の除去 ==="

if run_cli doctor --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  pass "正常な install を doctor が healthy と判定する"
else
  fail "正常な install を doctor が healthy と判定する"
fi

mv "$DATA_DIR/guards/commit-guard.sh" "$DATA_DIR/guards/commit-guard.sh.missing"
DOCTOR_OUT=$(run_cli doctor --settings "$SETTINGS" --data-dir "$DATA_DIR" 2>&1)
DOCTOR_STATUS=$?
if [ "$DOCTOR_STATUS" -eq 0 ] \
  || ! printf '%s\n' "$DOCTOR_OUT" | grep -q 'missing runtime file: .*commit-guard.sh'; then
  fail "欠損した guard を doctor が検出する"
else
  pass "欠損した guard を doctor が検出する"
fi
mv "$DATA_DIR/guards/commit-guard.sh.missing" "$DATA_DIR/guards/commit-guard.sh"

python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["env"] = {"KEEP_AFTER_UNINSTALL": "yes"}
data["hooks"]["PreToolUse"].append({
    "matcher": "Bash",
    "hooks": [{"type": "command", "command": "/keep/this-hook"}],
})
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY

if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  assert_json "uninstall は無関係な設定と hook を保持する" "$SETTINGS" \
    '.env.KEEP_AFTER_UNINSTALL == "yes" and ([.hooks.PreToolUse[]?.hooks[]?.command] | index("/keep/this-hook") != null)'
  if jq -e '[.hooks.PreToolUse[]?.hooks[]?.command | select(contains("git-safety-pack/runtime/run-guard"))] | length == 0' "$SETTINGS" >/dev/null \
    && [ ! -e "$DATA_DIR" ]; then
    pass "uninstall は所有する hook と data だけを除去する"
  else
    fail "uninstall は所有する hook と data だけを除去する"
  fi
else
  fail "uninstall できる"
fi

if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null; then
  pass "uninstall は冪等に再実行できる"
else
  fail "uninstall は冪等に再実行できる"
fi

new_case preserve_data
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
printf 'keep\n' > "$DATA_DIR/user-file"
printf 'keep guard data\n' > "$DATA_DIR/guards/user-file"
printf 'keep runtime data\n' > "$DATA_DIR/runtime/user-file"
if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null \
  && [ -f "$DATA_DIR/user-file" ] \
  && [ -f "$DATA_DIR/guards/user-file" ] \
  && [ -f "$DATA_DIR/runtime/user-file" ] \
  && [ ! -e "$DATA_DIR/guards/commit-guard.sh" ] \
  && [ ! -e "$DATA_DIR/runtime/run-guard" ] \
  && [ ! -e "$DATA_DIR/config.json" ] \
  && [ ! -e "$DATA_DIR/.git-safety-pack.json" ]; then
  pass "uninstall はdata directory配下の無関係なfileを保持する"
else
  fail "uninstall はdata directory配下の無関係なfileを保持する"
fi

new_case uninstall_dry_run
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
settings_before=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
marker_before=$(shasum -a 256 "$DATA_DIR/.git-safety-pack.json" | awk '{print $1}')
if run_cli uninstall --dry-run --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null \
  && [ "$settings_before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ] \
  && [ "$marker_before" = "$(shasum -a 256 "$DATA_DIR/.git-safety-pack.json" | awk '{print $1}')" ]; then
  pass "uninstall --dry-run は settings と data を変更しない"
else
  fail "uninstall --dry-run は settings と data を変更しない"
fi

CASE_DIR="$TMPDIR_TEST/overlapping_uninstall"
DATA_DIR="$CASE_DIR/profile"
SETTINGS="$DATA_DIR/settings.json"
mkdir -p "$DATA_DIR"
printf '{}\n' > "$SETTINGS"
printf 'keep\n' > "$DATA_DIR/user-file"
jq -n --arg product "agents-harnesses/git-safety-pack" \
  '{product:$product,version:"0.1.0",owned_commands:[],settings_structure:{}}' \
  > "$DATA_DIR/.git-safety-pack.json"
if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "旧版の危険な重複配置を uninstall が拒否する"
elif [ -f "$SETTINGS" ] && [ -f "$DATA_DIR/user-file" ]; then
  pass "旧版の危険な重複配置も settings と無関係なfileを削除しない"
else
  fail "旧版の危険な重複配置も settings と無関係なfileを削除しない"
fi

new_case symlink_runtime_uninstall
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
mv "$DATA_DIR/guards" "$DATA_DIR/guards-owned"
OUTSIDE_DIR="$CASE_DIR/outside"
mkdir -p "$OUTSIDE_DIR"
printf 'valuable\n' > "$OUTSIDE_DIR/commit-guard.sh"
ln -s "$OUTSIDE_DIR" "$DATA_DIR/guards"
settings_before=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "symlinkに置換されたruntime directoryをuninstallが拒否する"
elif [ -f "$OUTSIDE_DIR/commit-guard.sh" ] \
  && [ "$settings_before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ] \
  && [ -f "$DATA_DIR/.git-safety-pack.json" ]; then
  pass "runtime directoryのsymlink経由で外部fileを削除しない"
else
  fail "runtime directoryのsymlink経由で外部fileを削除しない"
fi

new_case unowned_hook
UNOWNED_COMMAND="$DATA_DIR/runtime/run-guard commit-guard"
jq -n --arg command "$UNOWNED_COMMAND" \
  '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$command}]}]}}' > "$SETTINGS"
run_cli install --mode advisory --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null
unowned_before=$(shasum -a 256 "$SETTINGS" | awk '{print $1}')
if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "導入前からある同一 command の所有権競合を拒否する"
elif [ "$unowned_before" = "$(shasum -a 256 "$SETTINGS" | awk '{print $1}')" ] \
  && [ -f "$DATA_DIR/.git-safety-pack.json" ]; then
  pass "所有権競合時は hook と runtime の両方を保持する"
else
  fail "所有権競合時は hook と runtime の両方を保持する"
fi

new_case unowned
mkdir -p "$DATA_DIR"
printf 'keep\n' > "$DATA_DIR/user-file"
if run_cli uninstall --settings "$SETTINGS" --data-dir "$DATA_DIR" >/dev/null 2>&1; then
  fail "所有者マーカーのない data directory を拒否する"
elif [ -f "$DATA_DIR/user-file" ]; then
  pass "所有者マーカーのない data directory は削除しない"
else
  fail "所有者マーカーのない data directory は削除しない"
fi

echo ""
echo "結果: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
