#!/usr/bin/env bash
# Verifies that opening a .md actually renders content in the webview.
set -euo pipefail

APP="${1:-/Applications/mdeye.app}"

# Normalize artifact layouts into a real .app
normalize_app() {
  local src="$1"
  if [[ -x "$src/Contents/MacOS/mdeye" ]]; then
    echo "$src"
    return
  fi
  if [[ -x "$src/Contents/MacOS/mdeye" ]]; then
    echo "$src"
    return
  fi
  if [[ -d "$src/Contents/MacOS" ]]; then
    local wrap
    wrap="$(mktemp -d)/mdeye.app"
    mkdir -p "$wrap"
    cp -R "$src/Contents" "$wrap/"
    echo "$wrap"
    return
  fi
  # bare Contents folder downloaded as artifact root
  if [[ -d "$src/MacOS" && -f "$src/Info.plist" ]]; then
    local wrap
    wrap="$(mktemp -d)/mdeye.app"
    mkdir -p "$wrap/Contents"
    cp -R "$src"/* "$wrap/Contents/"
    echo "$wrap"
    return
  fi
  echo "FAIL: cannot find mdeye binary under $src" >&2
  exit 1
}

APP="$(normalize_app "$APP")"
echo "Using app: $APP"

echo "== structural =="
INDEX=$(find "$APP/Contents/Resources" -name index.html | head -n1)
APPJS=$(find "$APP/Contents/Resources" -name app.js | head -n1)
test -n "$INDEX" && test -n "$APPJS"
if grep -q 'type="module"' "$INDEX"; then
  echo "FAIL: ESM module script still present" >&2
  exit 1
fi
if head -c 30 "$APPJS" | grep -q '^import'; then
  echo "FAIL: app.js is ESM" >&2
  exit 1
fi
if ! grep -q '__mdeye' "$APPJS"; then
  echo "FAIL: __mdeye missing from app.js" >&2
  exit 1
fi
echo "OK classic IIFE ($(du -h "$APPJS" | awk '{print $1}'))"

pkill -x mdeye 2>/dev/null || true
sleep 0.5
rm -f /tmp/mdeye-last-shown.json

MD1="/tmp/mdeye-verify-cold-$$.md"
MD2="/tmp/mdeye-verify-warm-$$.md"
cat >"$MD1" <<'EOF'
# Verify Cold

Unique-cold-token-ALPHA-42

paragraph for cold start.
EOF
cat >"$MD2" <<'EOF'
# Verify Warm

Unique-warm-token-BETA-99

```mermaid
graph LR
  A --> B
```
EOF

rm -rf /Applications/mdeye.app
cp -R "$APP" /Applications/mdeye.app
xattr -c /Applications/mdeye.app 2>/dev/null || true

wait_stamp() {
  local expect_path="$1"
  local i path chars
  for i in $(seq 1 80); do  # up to ~20s for cold first load of 2.8MB JS
    if [[ -f /tmp/mdeye-last-shown.json ]]; then
      path=$(python3 -c 'import json;print(json.load(open("/tmp/mdeye-last-shown.json")).get("path",""))' 2>/dev/null || true)
      chars=$(python3 -c 'import json;print(json.load(open("/tmp/mdeye-last-shown.json")).get("chars",-1))' 2>/dev/null || true)
      if [[ "$path" == "$expect_path" && "$chars" -ge 10 ]]; then
        echo "stamp ok path=$path chars=$chars"
        return 0
      fi
    fi
    sleep 0.25
  done
  echo "FAIL: no matching doc-shown stamp for $expect_path" >&2
  echo "stamp now:" >&2
  cat /tmp/mdeye-last-shown.json 2>/dev/null || echo '(missing)' >&2
  return 1
}

echo "== cold open =="
rm -f /tmp/mdeye-last-shown.json
open -a /Applications/mdeye.app "$MD1"
wait_stamp "$MD1"
echo "OK cold rendered"

echo "== warm open =="
rm -f /tmp/mdeye-last-shown.json
open -a /Applications/mdeye.app "$MD2"
wait_stamp "$MD2"
echo "OK warm rendered"

TITLE=$(osascript -e 'tell application "System Events" to tell process "mdeye" to get name of window 1' 2>/dev/null || true)
echo "window title: $TITLE"
echo "ALL SMOKE CHECKS PASSED"
