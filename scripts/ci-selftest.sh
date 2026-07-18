#!/usr/bin/env bash
# Headless rendering self-check for CI. Runs mdeasy with `--selftest <md>` on a
# runner that has NO GUI login / WindowServer session, and asserts the reader
# actually rendered by polling /tmp/mdeasy-last-shown.json.
# This covers what free fetched CI can: the load → IIFE → bridge → render → doc-shown
# pipeline. It does NOT cover NSSavePanel / PDF export (user-interactive, needs GUI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/mdeasy.app}"
BIN="$APP/Contents/MacOS/mdeasy"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found / not executable" >&2
  echo "Run ./scripts/ci-xcodebuild.sh first" >&2
  exit 1
fi

MD="$(mktemp /tmp/mdeasy-selftest-XXXX.md)"
trap 'rm -f "$MD" /tmp/mdeasy-last-shown.json' EXIT
cat >"$MD" <<'EOF'
# Selftest

A paragraph with **bold** and `inline code`.

| a | b |
| - | - |
| 1 | 2 |

```js
console.log("hi");
```

```mermaid
graph LR
  A --> B
```
EOF

rm -f /tmp/mdeasy-last-shown.json

echo "== selftest run =="
"$BIN" --selftest "$MD" &
PID=$!

# Wait up to 40s for the doc-shown stamp matching our fixture.
for i in $(seq 1 160); do
  if ! kill -0 "$PID" 2>/dev/null; then
    # process exited; collect its status
    wait "$PID" && EXITCODE=0 || EXITCODE=$?
    break
  fi
  if [[ -f /tmp/mdeasy-last-shown.json ]]; then
    STAMP_PATH=$(python3 -c 'import json;print(json.load(open("/tmp/mdeasy-last-shown.json")).get("path",""))' 2>/dev/null || true)
    STAMP_CHARS=$(python3 -c 'import json;print(json.load(open("/tmp/mdeasy-last-shown.json")).get("chars",-1))' 2>/dev/null || true)
    if [[ "$STAMP_PATH" == "$MD" && "$STAMP_CHARS" -ge 10 ]]; then
      echo "stamp ok path=$STAMP_PATH chars=$STAMP_CHARS"
      kill "$PID" 2>/dev/null || true
      wait "$PID" 2>/dev/null || true
      echo "SELFTEST CI OK"
      exit 0
    fi
  fi
  sleep 0.25
done

# If we get here, the process either hung (killed above) or never wrote a matching stamp.
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
echo "FAIL: no matching doc-shown stamp for $MD" >&2
echo "stamp now:" >&2
cat /tmp/mdeasy-last-shown.json 2>/dev/null >&2 || echo "(missing)" >&2
exit 1
