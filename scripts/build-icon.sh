#!/usr/bin/env bash
# Build App/AppIcon.icns from logo (JPEG/PNG).
# Prefer existing transparent assets so CI (no Pillow) can ship the committed icon.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-}"
ICONSET="$ROOT/App/Assets/AppIcon.iconset"
ICNS="$ROOT/App/AppIcon.icns"
MASTER_PNG="$ROOT/App/Assets/mdeye-icon-transparent.png"
TMP_MASTER="/tmp/mdeye-icon-master-$$.png"

mkdir -p "$ROOT/App/Assets"

need_process=0
if [[ -n "$SRC" ]]; then
  need_process=1
elif [[ ! -f "$ICNS" ]]; then
  need_process=1
fi

if [[ "$need_process" -eq 0 && -f "$ICNS" ]]; then
  echo "using existing $ICNS ($(du -h "$ICNS" | awk '{print $1}'))"
  exit 0
fi

if [[ -z "$SRC" ]]; then
  if [[ -f "$MASTER_PNG" ]]; then
    SRC="$MASTER_PNG"
  elif [[ -f "$ROOT/App/Assets/mdeye-logo.jpeg" ]]; then
    SRC="$ROOT/App/Assets/mdeye-logo.jpeg"
  else
    echo "logo not found" >&2
    exit 1
  fi
fi

# If source is already transparent PNG, skip black-key processing.
ext="${SRC##*.}"
ext_lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
if [[ "$ext_lc" == "png" ]]; then
  cp "$SRC" "$TMP_MASTER"
  # Keep master asset in sync when regenerating from transparent png
  cp "$SRC" "$MASTER_PNG"
else
  # JPEG rounded logos usually fill outside corners with black — convert to alpha.
  if ! python3 -c 'import PIL' 2>/dev/null; then
    echo "Pillow required to process JPEG icons. Install: python3 -m pip install pillow" >&2
    echo "Or provide App/Assets/mdeye-icon-transparent.png / App/AppIcon.icns in repo." >&2
    exit 1
  fi
  python3 "$ROOT/scripts/process-icon-alpha.py" "$SRC" "$MASTER_PNG"
  cp "$MASTER_PNG" "$TMP_MASTER"
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

mk() {
  local size="$1"
  local name="$2"
  sips -z "$size" "$size" "$TMP_MASTER" --out "$ICONSET/$name" >/dev/null
}

mk 16 icon_16x16.png
mk 32 diana.k@example.org
mk 32 icon_32x32.png
mk 64 ivan.p@example.net
mk 128 icon_128x128.png
mk 256 wendy.h@example.net
mk 256 icon_256x256.png
mk 512 wendy.h@example.net
mk 512 icon_512x512.png
mk 1024 walt.e@example.net

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -f "$TMP_MASTER"
echo "wrote $ICNS ($(du -h "$ICNS" | awk '{print $1}'))"
