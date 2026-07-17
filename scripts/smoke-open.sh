#!/usr/bin/env bash
# Local smoke test after installing build/mdeasy.app or /Applications/mdeasy.app
set -euo pipefail

APP="${1:-/Applications/mdeasy.app}"
if [[ ! -d "$APP" ]]; then
  echo "App not found: $APP" >&2
  exit 1
fi

pkill -x mdeasy 2>/dev/null || true
sleep 0.3

# Bundle checks
INDEX=$(find "$APP/Contents/Resources" -name index.html | head -n1 || true)
APPJS=$(find "$APP/Contents/Resources" -name app.js | head -n1 || true)
echo "== bundle =="
echo "index: $INDEX"
echo "app.js: $APPJS"
if [[ -z "$INDEX" || -z "$APPJS" ]]; then
  echo "FAIL: reader assets missing" >&2
  exit 1
fi
if grep -q 'type="module"' "$INDEX"; then
  echo "FAIL: index.html still uses type=module (broken under file/custom scheme races)" >&2
  exit 1
fi
if head -c 20 "$APPJS" | grep -q '^import'; then
  echo "FAIL: app.js looks like ESM (starts with import)" >&2
  exit 1
fi
echo "OK: classic script bundle"

# Functional open tests
MD1=$(mktemp /tmp/mdeasy-smoke-XXXX.md)
MD2=$(mktemp /tmp/mdeasy-smoke-XXXX.md)
cat >"$MD1" <<'EOF'
# Smoke One

Hello **world**.

```js
console.log(1)
```
EOF
cat >"$MD2" <<'EOF'
# Smoke Two

Second file for warm open.

```mermaid
graph LR
  A --> B
```
EOF

echo "== cold open =="
open -a "$APP" "$MD1"
sleep 3
TITLE=$(osascript -e 'tell application "System Events" to tell process "mdeasy" to get name of window 1' 2>/dev/null || true)
echo "window title: $TITLE"
BASE1=$(basename "$MD1")
if [[ "$TITLE" != *"$BASE1"* && "$TITLE" != "Smoke One"* ]]; then
  # title is filename by design
  if [[ "$TITLE" != "$BASE1" ]]; then
    echo "WARN: unexpected title after cold open: $TITLE"
  fi
fi

# Probe JS handler via AppleScript is hard; check process logs if possible
LOG=$(log show --predicate 'process == "mdeasy"' --last 15s --style compact 2>/dev/null | grep -E 'reader JS ready|doc pushed|document ready|__mdeasy handler missing' || true)
echo "$LOG" | tail -20
if echo "$LOG" | grep -q '__mdeasy handler missing'; then
  echo "FAIL: JS handler missing" >&2
  exit 1
fi
if ! echo "$LOG" | grep -qE 'doc pushed|document ready|reader JS ready'; then
  echo "WARN: no ready/push logs (may need Full Disk Access for log show)"
fi

echo "== warm open =="
open -a "$APP" "$MD2"
sleep 2
TITLE2=$(osascript -e 'tell application "System Events" to tell process "mdeasy" to get name of window 1' 2>/dev/null || true)
echo "window title: $TITLE2"
BASE2=$(basename "$MD2")
if [[ "$TITLE2" != "$BASE2" ]]; then
  echo "WARN: title after warm open: $TITLE2 (expected $BASE2)"
fi

LOG2=$(log show --predicate 'process == "mdeasy"' --last 10s --style compact 2>/dev/null | grep -E 'doc pushed|document ready|open request' || true)
echo "$LOG2" | tail -15

echo "== done =="
echo "Manual check: window should show markdown content for $BASE2"
echo "If blank, open Console.app and filter process mdeasy"
