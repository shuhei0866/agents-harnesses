#!/usr/bin/env bash
# Portability regression tests for:
#   line-ending-fix/fix-crlf.sh      (must not need GNU `grep -P` / `sed -i`)
#   session-sync/fetch-on-start.sh   (must not need GNU `timeout`)
#
# Runs on macOS (Bash 3.2, BSD tools) and Linux. Everything happens inside a
# disposable temp directory with a local bare remote and git stubs; no network,
# and neither hook is ever run against this checkout.
#
# Usage: bash claude-code/hooks/tests/test-portability.sh
# The timeout cases take about a minute and a half with timeout installed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRLF_HOOK="$SCRIPT_DIR/../line-ending-fix/fix-crlf.sh"
FETCH_HOOK="$SCRIPT_DIR/../session-sync/fetch-on-start.sh"

PASS=0
FAIL=0
SKIP=0

T="$(mktemp -d "${TMPDIR:-/tmp}/test-portability.XXXXXX")" || { echo "cannot create temp dir" >&2; exit 1; }
T="$(cd "$T" && pwd -P)"

cleanup() {
  if [ -n "${T:-}" ] && [ -d "$T" ]; then
    rm -rf "$T"
  fi
}
trap cleanup EXIT

# Isolate git from user/system configuration and from any enclosing repository.
export GIT_ALLOW_PROTOCOL=file
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_CEILING_DIRECTORIES="$T"
export GIT_TERMINAL_PROMPT=0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  if [ -n "${2:-}" ]; then
    echo "    $2"
  fi
  FAIL=$((FAIL + 1))
}

skip() {
  echo "  SKIP: $1"
  SKIP=$((SKIP + 1))
}

check() {
  # check <description> <command...>
  local desc="$1"
  shift
  if "$@"; then
    pass "$desc"
  else
    fail "$desc" "status=$STATUS elapsed=${ELAPSED:-n/a}s stdout=[${OUT}] stderr=[${ERR}]"
  fi
}

OUT=""
ERR=""
STATUS=0
ELAPSED=0

# ---------------------------------------------------------------------------
# fix-crlf.sh
# ---------------------------------------------------------------------------
echo "fix-crlf.sh"

REAL_GREP="$(command -v grep)"
REAL_SED="$(command -v sed)"

# Wrappers that reject the GNU-only options, so a regression to `grep -P` or
# `sed -i` fails on Linux exactly like it does with the BSD tools on macOS.
STRICT_BIN="$T/strict-bin"
mkdir -p "$STRICT_BIN"
cat > "$STRICT_BIN/grep" << EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    --perl-regexp) echo "grep: unsupported option --perl-regexp" >&2; exit 2 ;;
    --*) ;;
    -*P*) echo "grep: invalid option -- P" >&2; exit 2 ;;
    -*) ;;
    *) break ;;
  esac
done
exec "$REAL_GREP" "\$@"
EOF
cat > "$STRICT_BIN/sed" << EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    -i*|--in-place*) echo "sed: in-place editing is not portable" >&2; exit 1 ;;
    -*) ;;
    *) break ;;
  esac
done
exec "$REAL_SED" "\$@"
EOF
chmod +x "$STRICT_BIN/grep" "$STRICT_BIN/sed"

HOOK_TMP="$T/hook-tmp"
mkdir -p "$HOOK_TMP"

run_crlf() {
  # run_crlf <file_path>
  OUT=$(jq -n --arg p "$1" '{tool_input:{file_path:$p}}' \
    | TMPDIR="$HOOK_TMP" PATH="$STRICT_BIN:$PATH" "$BASH" "$CRLF_HOOK" 2>"$T/stderr")
  STATUS=$?
  ERR=$(cat "$T/stderr" 2>/dev/null || echo "")
}

same() {
  cmp -s "$1" "$2"
}

converted() {
  # converted <actual> <expected>: fixed, exit 0, and reported on stderr
  [ "$STATUS" -eq 0 ] && same "$1" "$2" && case "$ERR" in *"CRLF"*"$1"*) true ;; *) false ;; esac
}

untouched() {
  # untouched <actual> <expected>: byte-identical, exit 0, nothing reported
  [ "$STATUS" -eq 0 ] && same "$1" "$2" && [ -z "$ERR" ] && [ -z "$OUT" ]
}

if ! command -v jq > /dev/null 2>&1; then
  skip "fix-crlf.sh cases need jq (the hook itself is a no-op without jq)"
else
  W="$T/crlf"
  mkdir -p "$W"

  printf 'one\r\ntwo\r\nthree\r\n' > "$W/crlf.txt"
  printf 'one\ntwo\nthree\n' > "$W/crlf.expected"
  run_crlf "$W/crlf.txt"
  check "CRLF text file is converted to LF" converted "$W/crlf.txt" "$W/crlf.expected"

  printf 'one\ntwo\nthree\n' > "$W/lf.txt"
  cp "$W/lf.txt" "$W/lf.expected"
  run_crlf "$W/lf.txt"
  check "LF text file is left unchanged" untouched "$W/lf.txt" "$W/lf.expected"

  printf '\000\001\002\r\n\003\004\r\n\377\376' > "$W/blob.bin"
  cp "$W/blob.bin" "$W/blob.expected"
  run_crlf "$W/blob.bin"
  check "binary file containing CRLF bytes is left unchanged" untouched "$W/blob.bin" "$W/blob.expected"

  # A NUL-free byte sequence that libmagic classifies as binary.
  printf '\377\361\023\r\n\372\373\032\r\n' > "$W/nul-free.bin"
  cp "$W/nul-free.bin" "$W/nul-free.expected"
  run_crlf "$W/nul-free.bin"
  check "binary file without NUL bytes is left unchanged" untouched "$W/nul-free.bin" "$W/nul-free.expected"

  printf 'one\r\ntwo' > "$W/noeol.txt"
  printf 'one\ntwo' > "$W/noeol.expected"
  run_crlf "$W/noeol.txt"
  check "missing final newline is preserved (no newline added)" converted "$W/noeol.txt" "$W/noeol.expected"

  printf 'linked\r\n' > "$W/target.txt"
  printf 'linked\n' > "$W/target.expected"
  ln -s "$W/target.txt" "$W/link.txt"
  run_crlf "$W/link.txt"
  linked_text() { [ -L "$W/link.txt" ] && converted "$W/link.txt" "$W/target.expected"; }
  check "text symlink target is converted and the link is preserved" linked_text

  printf 'a\rb\r\nc\r\n' > "$W/lonecr.txt"
  printf 'a\rb\nc\n' > "$W/lonecr.expected"
  run_crlf "$W/lonecr.txt"
  check "CR in the middle of a line is preserved" converted "$W/lonecr.txt" "$W/lonecr.expected"

  mkdir -p "$W/dir with space"
  printf 'こんにちは\r\n世界\r\n' > "$W/dir with space/日本語 file.txt"
  printf 'こんにちは\n世界\n' > "$W/utf8.expected"
  run_crlf "$W/dir with space/日本語 file.txt"
  check "UTF-8 content and a path with spaces are handled" converted "$W/dir with space/日本語 file.txt" "$W/utf8.expected"

  printf 'x\r\ny\r\n' > "$W/mode.txt"
  printf 'x\ny\n' > "$W/mode.expected"
  chmod 640 "$W/mode.txt"
  run_crlf "$W/mode.txt"
  MODE=$(ls -l "$W/mode.txt" | cut -c1-10)
  mode_kept() { converted "$W/mode.txt" "$W/mode.expected" && [ "$MODE" = "-rw-r-----" ]; }
  check "file permissions are preserved after conversion" mode_kept

  run_crlf "$W/does-not-exist.txt"
  quiet_ok() { [ "$STATUS" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; }
  check "missing file exits 0 silently" quiet_ok

  OUT=$(echo '{"tool_input":{}}' | TMPDIR="$HOOK_TMP" PATH="$STRICT_BIN:$PATH" "$BASH" "$CRLF_HOOK" 2>"$T/stderr")
  STATUS=$?
  ERR=$(cat "$T/stderr" 2>/dev/null || echo "")
  check "input without file_path exits 0 silently" quiet_ok

  LEFTOVER=$(ls "$HOOK_TMP" 2>/dev/null | grep -c '^fix-crlf\.' || true)
  no_leftover() { [ "${LEFTOVER:-0}" -eq 0 ]; }
  check "no temp files are left behind" no_leftover
fi

# ---------------------------------------------------------------------------
# fetch-on-start.sh
# ---------------------------------------------------------------------------
echo "fetch-on-start.sh"

REAL_GIT="$(command -v git || true)"
REAL_SLEEP="$(command -v sleep)"
REAL_CAT="$(command -v cat)"
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
FETCH_LOG="$T/fetch.log"
CHILD_PID_FILE="$T/fetch-child.pid"

# child_gone: the child recorded by the fetch stub no longer exists.
# Polls for up to ~2s (SIGKILL delivery is asynchronous); if the process is
# still there it is reported and then killed so the test leaves nothing behind.
CHILD_PID=""
child_gone() {
  local i=0
  CHILD_PID=$(cat "$CHILD_PID_FILE" 2>/dev/null || echo "")
  case "$CHILD_PID" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "$i" -lt 20 ]; do
    kill -0 "$CHILD_PID" 2>/dev/null || return 0
    sleep 0.1 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  kill -KILL "$CHILD_PID" 2>/dev/null
  return 1
}

gitc() {
  git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false "$@"
}

# make_bin <dir> <mode> [timeout executable]: construct an isolated PATH.
# Include the installed timeout only for cases that exercise its presence.
make_bin() {
  local dir="$1" mode="$2" timeout_executable="${3:-}" on_fetch="" child=""
  mkdir -p "$dir"
  if [ -n "$timeout_executable" ]; then
    ln -sf "$timeout_executable" "$dir/${timeout_executable##*/}"
  fi
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_SLEEP" > "$dir/sleep"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$REAL_CAT" > "$dir/cat"
  case "$mode" in
    slow) on_fetch="exec \"$REAL_SLEEP\" 30" ;;
    fail) on_fetch="exit 1" ;;
    stubborn) on_fetch="trap '' TERM; \"$REAL_SLEEP\" 20; exit 0" ;;
    tree|child_ignores_term|both_ignore_term|parent_exits_zero)
      # The mock ends naturally after 18s if the hook fails to stop it.
      child="\"$REAL_SLEEP\" 18"
      if [ "$mode" != tree ]; then
        child="(trap '' TERM; exec $child)"
      fi
      case "$mode" in
        both_ignore_term) on_fetch="trap '' TERM; " ;;
        parent_exits_zero) on_fetch="trap 'exit 0' TERM; " ;;
      esac
      on_fetch="${on_fetch}$child & echo \$! > \"$CHILD_PID_FILE\"; wait; exit 0"
      ;;
  esac
  {
    echo '#!/bin/sh'
    if [ -n "$on_fetch" ]; then
      echo "if [ \"\$1\" = fetch ]; then echo \"$mode\" >> \"$FETCH_LOG\"; $on_fetch; fi"
    fi
    echo "exec \"$REAL_GIT\" \"\$@\""
  } > "$dir/git"
  chmod +x "$dir/sleep" "$dir/cat" "$dir/git"
}

run_fetch() {
  # run_fetch <working dir> <PATH dir>
  local start=$SECONDS
  OUT=$(cd "$1" && PATH="$2" "$BASH" "$FETCH_HOOK" 2>"$T/stderr")
  STATUS=$?
  ELAPSED=$((SECONDS - start))
  ERR=$(cat "$T/stderr" 2>/dev/null || echo "")
}

build_fixtures() {
  git init -q --bare "$T/remote.git" \
    && git --git-dir="$T/remote.git" symbolic-ref HEAD refs/heads/main \
    && git init -q "$T/a" \
    && (
      cd "$T/a" \
        && git symbolic-ref HEAD refs/heads/main \
        && git remote add origin "$T/remote.git" \
        && echo one > f && git add f && gitc commit -q -m one \
        && git push -q -u origin main
    ) \
    && git clone -q "$T/remote.git" "$T/b" \
    && (
      cd "$T/b" \
        && echo two > f && gitc commit -q -am two \
        && git push -q origin main
    )
}

if [ -z "$REAL_GIT" ]; then
  fail "git is required for the fetch-on-start.sh cases"
elif ! build_fixtures > "$T/fixture.log" 2>&1; then
  fail "could not build local git fixtures" "$(cat "$T/fixture.log")"
else
  make_bin "$T/bin-real" real
  make_bin "$T/bin-slow" slow
  make_bin "$T/bin-fail" fail
  make_bin "$T/bin-stubborn" stubborn

  no_timeout_cmd() {
    ! PATH="$T/bin-real" command -v timeout > /dev/null 2>&1 \
      && ! PATH="$T/bin-real" command -v gtimeout > /dev/null 2>&1
  }
  check "test PATH has no timeout/gtimeout (stock macOS scenario)" no_timeout_cmd

  # --- behind upstream: fetch really runs and the warning is emitted --------
  A_HEAD_BEFORE=$(git -C "$T/a" rev-parse HEAD)
  run_fetch "$T/a" "$T/bin-real"
  A_HEAD_AFTER=$(git -C "$T/a" rev-parse HEAD)
  A_TRACKING=$(git -C "$T/a" rev-parse refs/remotes/origin/main)
  B_HEAD=$(git -C "$T/b" rev-parse HEAD)

  fetched() { [ "$STATUS" -eq 0 ] && [ "$A_TRACKING" = "$B_HEAD" ]; }
  check "fetch runs without GNU timeout and updates the tracking ref" fetched

  warned() {
    case "$OUT" in
      *'"hookEventName": "SessionStart"'*) ;;
      *) return 1 ;;
    esac
    case "$OUT" in
      *"main"*"origin/main"*"1 コミット遅れています"*"(ahead: 0)"*) ;;
      *) return 1 ;;
    esac
    if command -v jq > /dev/null 2>&1; then
      echo "$OUT" | jq -e '.hookSpecificOutput.additionalContext | length > 0' > /dev/null 2>&1 || return 1
    fi
    [ -z "$ERR" ]
  }
  check "behind upstream produces the SessionStart warning JSON" warned

  not_pulled() { [ "$A_HEAD_BEFORE" = "$A_HEAD_AFTER" ]; }
  check "local branch is not moved (fetch only, no pull)" not_pulled

  prompt() { [ "$ELAPSED" -le 5 ]; }
  check "fast fetch returns promptly with captured stdout (watchdog does not hold the pipe)" prompt

  # --- up to date: silent ---------------------------------------------------
  git clone -q "$T/remote.git" "$T/c" > /dev/null 2>&1
  run_fetch "$T/c" "$T/bin-real"
  silent_ok() { [ "$STATUS" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; }
  check "up-to-date branch exits 0 with no output" silent_ok

  # --- not a git repository: silent -----------------------------------------
  mkdir -p "$T/plain"
  run_fetch "$T/plain" "$T/bin-real"
  check "non-git directory exits 0 with no output" silent_ok

  # From here on $T/a is still 1 commit behind according to its tracking ref,
  # so any output would mean the hook carried on after a failed fetch.

  # --- fetch fails: graceful ------------------------------------------------
  : > "$FETCH_LOG"
  run_fetch "$T/a" "$T/bin-fail"
  fail_ok() { silent_ok && grep -q '^fail$' "$FETCH_LOG" && [ "$ELAPSED" -le 5 ]; }
  check "failing fetch exits 0 quickly with no output" fail_ok

  # --- fetch hangs: bounded at ten seconds ----------------------------------
  : > "$FETCH_LOG"
  run_fetch "$T/a" "$T/bin-slow"
  bounded() { silent_ok && grep -q '^slow$' "$FETCH_LOG" && [ "$ELAPSED" -ge 9 ] && [ "$ELAPSED" -le 13 ]; }
  check "hanging fetch is attempted, cut off at ~10s, exits 0 with no output" bounded

  # --- fetch ignores SIGTERM: escalates to SIGKILL --------------------------
  : > "$FETCH_LOG"
  run_fetch "$T/a" "$T/bin-stubborn"
  killed() { silent_ok && grep -q '^stubborn$' "$FETCH_LOG" && [ "$ELAPSED" -ge 9 ] && [ "$ELAPSED" -le 14 ]; }
  check "fetch ignoring SIGTERM is killed shortly after the bound" killed

  tree_bounded() {
    silent_ok && grep -qx "$1" "$FETCH_LOG" && [ "$ELAPSED" -ge 9 ] && [ "$ELAPSED" -le 14 ]
  }

  run_tree_case() {
    local mode="$1" description="$2" timeout_executable="${3:-}"
    make_bin "$T/bin-$mode" "$mode" "$timeout_executable"
    : > "$FETCH_LOG"
    rm -f "$CHILD_PID_FILE"
    run_fetch "$T/a" "$T/bin-$mode"
    check "$description: timeout returns within the bound without warning" tree_bounded "$mode"
    if child_gone; then
      pass "$description: child is stopped"
    else
      fail "$description: child is stopped" "pid=[$CHILD_PID] still present (or never recorded)"
    fi
  }

  run_tree_case tree "without timeout, fetch with a child"
  run_tree_case child_ignores_term "without timeout, child ignores TERM"

  if [ -n "$REAL_TIMEOUT" ]; then
    run_tree_case child_ignores_term "with timeout installed, child ignores TERM" "$REAL_TIMEOUT"
    run_tree_case both_ignore_term "with timeout installed, parent and child ignore TERM" "$REAL_TIMEOUT"
  else
    skip "PATH cases with timeout installed need timeout or gtimeout"
  fi

  # The parent exits successfully from its TERM trap. The tracking ref remains
  # behind, so incorrectly treating the timed-out fetch as successful warns.
  run_tree_case parent_exits_zero "parent exits zero on TERM" "$REAL_TIMEOUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
