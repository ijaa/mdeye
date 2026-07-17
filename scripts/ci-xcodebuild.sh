#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/build/DerivedData}"
CONFIG="${CONFIGURATION:-Release}"

mkdir -p "$ROOT/build"
rm -rf "$DERIVED"
mkdir -p "$DERIVED"

echo "==> xcodebuild ($CONFIG)"
xcodebuild \
  -project "$APP_DIR/mdeasy.xcodeproj" \
  -scheme mdeasy \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  build

APP_PATH="$(find "$DERIVED/Build/Products/$CONFIG" -name 'mdeasy.app' -maxdepth 2 | head -n1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "mdeasy.app not found under $DERIVED" >&2
  exit 1
fi

OUT_APP="$ROOT/build/mdeasy.app"
rm -rf "$OUT_APP"
cp -R "$APP_PATH" "$OUT_APP"

echo "==> size"
du -sh "$OUT_APP"
du -sh "$OUT_APP/Contents/MacOS/"* 2>/dev/null || true
du -sh "$OUT_APP/Contents/Resources" 2>/dev/null || true

# Size gate for full pack (Mermaid included). Override with MAX_APP_KB.
SIZE_KB=$(du -sk "$OUT_APP" | awk '{print $1}')
MAX_KB=${MAX_APP_KB:-20480} # 20 MB — IIFE full pack includes mermaid
if (( SIZE_KB > MAX_KB )); then
  echo "ERROR: app size ${SIZE_KB}KB exceeds gate ${MAX_KB}KB" >&2
  exit 1
fi

echo "OK: $OUT_APP (${SIZE_KB}KB)"
