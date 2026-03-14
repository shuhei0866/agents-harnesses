#!/bin/bash
# browser-context.sh: ブラウザの状態（URL, タイトル, タブ一覧）を JSON で出力
#
# Usage:
#   browser-context.sh                  # アクティブタブの URL + タイトル
#   browser-context.sh --all-tabs       # 全タブの URL + タイトル
#   browser-context.sh --content        # アクティブタブの URL + タイトル + テキスト内容
#   browser-context.sh --browser safari # ブラウザ指定 (chrome, arc, safari)
#   browser-context.sh --cdp-port 9222  # Chrome DevTools Protocol で取得
#
# macOS only (osascript 使用)
# Safari で --content を使うには: Safari → 開発 → 「Apple Events からの JavaScript を許可」を有効にすること

set -euo pipefail

# python3 の存在確認
command -v python3 >/dev/null 2>&1 || { echo '{"error": "python3 is required but not found"}' >&2; exit 1; }

# --- defaults ---
BROWSER="auto"
ALL_TABS=false
CONTENT=false
CDP_PORT=""

# --- parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)
      [[ $# -lt 2 ]] && { echo '{"error": "--browser requires an argument (chrome|arc|safari)"}' >&2; exit 1; }
      BROWSER="$2"; shift 2 ;;
    --all-tabs)   ALL_TABS=true; shift ;;
    --content)    CONTENT=true; shift ;;
    --cdp-port)
      [[ $# -lt 2 ]] && { echo '{"error": "--cdp-port requires a port number"}' >&2; exit 1; }
      if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 < 1 || $2 > 65535 )); then
        echo '{"error": "--cdp-port must be a number between 1 and 65535"}' >&2; exit 1
      fi
      CDP_PORT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: browser-context.sh [--browser chrome|arc|safari] [--all-tabs] [--content] [--cdp-port PORT]"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --all-tabs と --content の排他チェック
if [[ "$ALL_TABS" == true && "$CONTENT" == true ]]; then
  echo '{"error": "--all-tabs and --content cannot be used together"}' >&2
  exit 1
fi

# --- detect OS ---
if [[ "$(uname)" != "Darwin" ]]; then
  echo '{"error": "macOS only (osascript required)"}' >&2
  exit 1
fi

# --- auto-detect browser ---
detect_browser() {
  local front
  front=$(timeout 5 osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || echo "")
  case "$front" in
    "Google Chrome") echo "chrome" ;;
    "Arc")           echo "arc" ;;
    "Safari")        echo "safari" ;;
    "Firefox"*)      echo "firefox" ;;
    *)
      if pgrep -qx "Google Chrome" 2>/dev/null; then echo "chrome"
      elif pgrep -qx "Arc" 2>/dev/null; then echo "arc"
      elif pgrep -qx "Safari" 2>/dev/null; then echo "safari"
      else echo "unknown"
      fi
      ;;
  esac
}

if [[ "$BROWSER" == "auto" ]]; then
  BROWSER=$(detect_browser)
fi

# --- Chrome / Arc: active tab ---
get_chrome_active() {
  local app_name="Google Chrome"
  [[ "$BROWSER" == "arc" ]] && app_name="Arc"

  timeout 10 osascript <<EOF 2>/dev/null
tell application "$app_name"
  set theURL to URL of active tab of front window
  set theTitle to title of active tab of front window
  return theURL & (ASCII character 10) & theTitle
end tell
EOF
}

# --- Chrome / Arc: all tabs (newline-separated URL\tTitle pairs) ---
get_chrome_all_tabs() {
  local app_name="Google Chrome"
  [[ "$BROWSER" == "arc" ]] && app_name="Arc"

  timeout 15 osascript <<EOF 2>/dev/null
tell application "$app_name"
  set output to ""
  set winList to every window
  repeat with w in winList
    set tabList to every tab of w
    repeat with t in tabList
      set output to output & URL of t & (ASCII character 9) & title of t & (ASCII character 10)
    end repeat
  end repeat
  return output
end tell
EOF
}

# --- Chrome / Arc: page content via JS ---
get_chrome_content() {
  local app_name="Google Chrome"
  [[ "$BROWSER" == "arc" ]] && app_name="Arc"

  timeout 15 osascript <<OUTER_EOF 2>/dev/null
tell application "$app_name"
  set theContent to execute active tab of front window javascript "
    (function() {
      var el = document.querySelector('article') || document.querySelector('main') || document.body;
      var clone = el.cloneNode(true);
      ['script','style','nav','footer','header','aside'].forEach(function(tag) {
        clone.querySelectorAll(tag).forEach(function(e) { e.remove(); });
      });
      return clone.innerText.substring(0, 15000);
    })()
  "
  return theContent
end tell
OUTER_EOF
}

# --- Safari: active tab ---
get_safari_active() {
  timeout 10 osascript <<'EOF' 2>/dev/null
tell application "Safari"
  set theURL to URL of current tab of front window
  set theTitle to name of current tab of front window
  return theURL & (ASCII character 10) & theTitle
end tell
EOF
}

# --- Safari: all tabs ---
get_safari_all_tabs() {
  timeout 15 osascript <<'EOF' 2>/dev/null
tell application "Safari"
  set output to ""
  set winList to every window
  repeat with w in winList
    set tabList to every tab of w
    repeat with t in tabList
      set output to output & URL of t & (ASCII character 9) & name of t & (ASCII character 10)
    end repeat
  end repeat
  return output
end tell
EOF
}

# --- Safari: page content via JS ---
# 注意: Safari → 開発メニュー → 「Apple Events からの JavaScript を許可」が必要
get_safari_content() {
  timeout 15 osascript <<'EOF' 2>/dev/null
tell application "Safari"
  set theContent to do JavaScript "
    (function() {
      var el = document.querySelector('article') || document.querySelector('main') || document.body;
      var clone = el.cloneNode(true);
      ['script','style','nav','footer','header','aside'].forEach(function(tag) {
        clone.querySelectorAll(tag).forEach(function(e) { e.remove(); });
      });
      return clone.innerText.substring(0, 15000);
    })()
  " in current tab of front window
  return theContent
end tell
EOF
}

# --- CDP (Chrome DevTools Protocol) ---
get_cdp() {
  local port="${CDP_PORT:-9222}"
  local targets
  targets=$(curl -fsS --connect-timeout 3 --max-time 5 "http://127.0.0.1:${port}/json" 2>/dev/null)
  if [[ -z "$targets" ]]; then
    echo '{"error": "CDP not available on port '"$port"'"}' >&2
    return 1
  fi
  echo "$targets" | python3 -c "
import json, sys
port = int(sys.argv[1])
targets = json.load(sys.stdin)
pages = [t for t in targets if t.get('type') == 'page']
if pages:
    t = pages[0]
    print(json.dumps({'url': t.get('url',''), 'title': t.get('title',''), 'source': 'cdp', 'port': port}, ensure_ascii=False, indent=2))
else:
    print(json.dumps({'error': 'no page targets'}))" "$port" 2>/dev/null
}

# --- 安全な JSON 出力 (python3 経由で全値をエスケープ) ---
emit_active_tab() {
  local url="$1" title="$2" content="${3:-}"
  python3 -c "
import json, sys
data = {'browser': sys.argv[1], 'url': sys.argv[2], 'title': sys.argv[3]}
content = sys.stdin.read().strip()
if content:
    data['content'] = content
    data['content_length'] = len(content)
print(json.dumps(data, ensure_ascii=False, indent=2))
" "$BROWSER" "$url" "$title" <<< "$content"
}

emit_all_tabs() {
  # stdin: tab-separated URL\tTitle lines
  python3 -c "
import json, sys
tabs = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split('\t', 1)
    if len(parts) == 2:
        tabs.append({'url': parts[0], 'title': parts[1]})
    elif len(parts) == 1:
        tabs.append({'url': parts[0], 'title': ''})
print(json.dumps({'browser': sys.argv[1], 'tabs': tabs, 'tab_count': len(tabs)}, ensure_ascii=False, indent=2))
" "$BROWSER"
}

# --- main ---
main() {
  # CDP モード (--all-tabs, --content は無視される)
  if [[ -n "$CDP_PORT" ]]; then
    get_cdp
    return
  fi

  case "$BROWSER" in
    chrome|arc)
      if [[ "$ALL_TABS" == true ]]; then
        get_chrome_all_tabs | emit_all_tabs
      else
        local result url title content=""
        result=$(get_chrome_active) || { echo '{"error": "Failed to get active tab from '"$BROWSER"'. Is the browser running with an open window?"}' >&2; exit 1; }
        url=$(echo "$result" | head -1)
        title=$(echo "$result" | tail -n +2)
        if [[ "$CONTENT" == true ]]; then
          content=$(get_chrome_content)
        fi
        emit_active_tab "$url" "$title" "$content"
      fi
      ;;
    safari)
      if [[ "$ALL_TABS" == true ]]; then
        get_safari_all_tabs | emit_all_tabs
      else
        local result url title content=""
        result=$(get_safari_active) || { echo '{"error": "Failed to get active tab from Safari. Is Safari running with an open window?"}' >&2; exit 1; }
        url=$(echo "$result" | head -1)
        title=$(echo "$result" | tail -n +2)
        if [[ "$CONTENT" == true ]]; then
          content=$(get_safari_content)
        fi
        emit_active_tab "$url" "$title" "$content"
      fi
      ;;
    firefox)
      echo '{"error": "Firefox is not supported via osascript. Use --cdp-port with remote debugging."}' >&2
      exit 1
      ;;
    *)
      echo '{"error": "No supported browser detected. Use --browser to specify."}' >&2
      exit 1
      ;;
  esac
}

main
