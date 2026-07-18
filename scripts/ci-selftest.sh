#!/usr/bin/env bash
# Headless rendering self-check for CI. Runs mdeye with `--selftest <md>` on a
# runner that has NO GUI login / WindowServer session, and asserts the reader
# actually rendered by polling /tmp/mdeye-last-shown.json.
# This covers what CI can: the load → IIFE → bridge → render → doc-shown pipeline.
# It does NOT cover NSSavePanel / PDF export (user-interactive, needs GUI).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/mdeye.app}"
BIN="$APP/Contents/MacOS/mdeye"

if [[ ! -x "$BIN" ]]; then
  echo "ERROR: $BIN not found / not executable" >&2
  echo "Run ./scripts/ci-xcodebuild.sh first" >&2
  exit 1
fi

# mktemp needs >=6 trailing X to actually substitute a random suffix.
MD_BASE="$(mktemp /tmp/mdeye-selftest.XXXXXX)"
rm -f "$MD_BASE"
MD="$MD_BASE.md"
trap 'rm -f "$MD" /tmp/mdeye-last-shown.json' EXIT
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

rm -f /tmp/mdeye-last-shown.json

check_stamp() {
  # Returns 0 only if a doc-shown stamp exists for our fixture with non-trivial content.
  [[ -f /tmp/mdeye-last-shown.json ]] || return 1
  local sp sc
  sp=$(python3 -c 'import json;print(json.load(open("/tmp/mdeye-last-shown.json")).get("path",""))' 2>/dev/null || true)
  sc=$(python3 -c 'import json;print(json.load(open("/tmp/mdeye-last-shown.json")).get("chars",-1))' 2>/dev/null || true)
  if [[ "$sp" == "$MD" && "$sc" -ge 10 ]]; then
    echo "stamp ok path=$sp chars=$sc"
    return 0
  fi
  return 1
}

print_failure() {
  echo "FAIL: no matching doc-shown stamp for $MD" >&2
  echo "stamp now:" >&2
  cat /tmp/mdeye-last-shown.json 2>/dev/null >&2 || echo "(missing)" >&2
  exit 1
}

echo "== selftest run =="
"$BIN" --selftest "$MD" &
PID=$!
wait "$PID" && EXITCODE=0 || EXITCODE=$?

# SelfTest exits 0 on "doc-shown" — but the stamp file write races with process
# teardown, so re-check once after it returns.
sleep 0.2
if check_stamp; then
  echo "SELFTEST CI OK"
  exit 0
fi

if [[ "$EXITCODE" -ne 0 ]]; then
  echo "FAIL: selftest process exited $EXITCODE without a valid stamp" >&2
  cat /tmp/mdeye-last-shown.json 2>/dev/null >&2 || true
  exit 1
fi

# Process exited 0 but stamp missing/partial — one last retry, then give up.
for _ in $(seq 1 10); do
  if check_stamp; then echo "SELFTEST CI OK"; exit 0; fi
  sleep 0.2
done
print_failure
