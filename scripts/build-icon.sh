#!/usr/bin/env bash
# Build App/AppIcon.icns from logo (JPEG/PNG).
# Converts black exterior (common JPEG rounded export) to transparent alpha first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/App/Assets/mdeasy-logo.jpeg}"
ICONSET="$ROOT/App/Assets/AppIcon.iconset"
ICNS="$ROOT/App/AppIcon.icns"
MASTER_PNG="$ROOT/App/Assets/mdeasy-icon-transparent.png"
TMP_MASTER="/tmp/mdeasy-icon-master-$$.png"

if [[ ! -f "$SRC" ]]; then
  echo "logo not found: $SRC" >&2
  exit 1
fi

mkdir -p "$ROOT/App/Assets"

# Step 1: black corners -> transparent PNG (JPEG cannot store alpha)
python3 "$ROOT/scripts/process-icon-alpha.py" "$SRC" "$MASTER_PNG"
cp "$MASTER_PNG" "$TMP_MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

mk() {
  local size="$1"
  local name="$2"
  # sips preserves alpha for PNG sources
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

# Verify a generated size has transparent corners
python3 - <<'PY'
from pathlib import Path
import struct, zlib
p = Path("App/Assets/AppIcon.iconset/icon_256x256.png")
# quick: PIL
from PIL import Image
import numpy as np
im = Image.open(p).convert("RGBA")
a = np.array(im)
print("iconset 256 corner alpha", a[0,0,3], a[0,-1,3], a[-1,0,3], a[-1,-1,3], "center", a[128,128,3])
if a[0,0,3] > 20:
    raise SystemExit("corner not transparent — black frame would remain")
PY

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -f "$TMP_MASTER"
echo "wrote $ICNS ($(du -h "$ICNS" | awk '{print $1}'))"
# sample icns by converting back with sips if possible
sips -s format png "$ICNS" --out /tmp/icns-preview.png >/dev/null 2>&1 || true
if [[ -f /tmp/icns-preview.png ]]; then
  python3 - <<'PY'
from PIL import Image
import numpy as np
im=Image.open('/tmp/icns-preview.png').convert('RGBA')
a=np.array(im)
print('icns-preview size', im.size, 'corner_alpha', int(a[0,0,3]), 'center_alpha', int(a[a.shape[0]//2,a.shape[1]//2,3]))
PY
fi
