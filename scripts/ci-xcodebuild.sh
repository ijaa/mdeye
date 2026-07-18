#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/App"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/build/DerivedData}"
CONFIG="${CONFIGURATION:-Release}"

# Universal binary: Intel + Apple Silicon
ARCHS_VALUE="${ARCHS_VALUE:-arm64 x86_64}"

mkdir -p "$ROOT/build"
rm -rf "$DERIVED"
mkdir -p "$DERIVED"

# Ensure flat AppIcon.icns exists. Prefer committed asset; rebuild only if missing.
if [[ ! -f "$APP_DIR/AppIcon.icns" ]]; then
  chmod +x "$ROOT/scripts/build-icon.sh" "$ROOT/scripts/process-icon-alpha.py" 2>/dev/null || true
  if [[ -f "$APP_DIR/Assets/mdeye-icon-transparent.png" ]]; then
    "$ROOT/scripts/build-icon.sh" "$APP_DIR/Assets/mdeye-icon-transparent.png"
  elif [[ -f "$APP_DIR/Assets/mdeye-logo.jpeg" ]]; then
    "$ROOT/scripts/build-icon.sh" "$APP_DIR/Assets/mdeye-logo.jpeg"
  else
    echo "ERROR: AppIcon.icns missing and no logo source" >&2
    exit 1
  fi
fi
# Verify committed/generated icon has transparent corners (prevents black frame regressions).
# Pillow absent on CI → body raises SystemExit(0) early and the script continues.
# Pillow present + opaque corner → SystemExit(non-zero) aborts the build (was swallowed by `|| true`).
python3 - <<'PY'
from pathlib import Path
try:
    from PIL import Image
    import numpy as np
    import subprocess
    icns = Path("App/AppIcon.icns")
    if not icns.exists():
        raise SystemExit(0)
    out = Path("/tmp/ci-icon-preview.png")
    subprocess.run(["sips", "-s", "format", "png", str(icns), "--out", str(out)], check=True, capture_output=True)
    a = np.array(Image.open(out).convert("RGBA"))
    corner = int(a[0, 0, 3])
    print(f"icon corner_alpha={corner}")
    if corner > 20:
        raise SystemExit("ERROR: AppIcon.icns corner is not transparent (black frame risk)")
except SystemExit:
    raise            # SystemExit (0=skip, non-zero=fail) must propagate, never be swallowed
except Exception as e:
    # Pillow/sips unavailable → structural path check already done above; skip alpha gate.
    print("icon alpha check skipped:", e)
PY

echo "==> xcodebuild ($CONFIG) ARCHS=[$ARCHS_VALUE]"
xcodebuild \
  -project "$APP_DIR/mdeye.xcodeproj" \
  -scheme mdeye \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  ARCHS="$ARCHS_VALUE" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=- \
  build

APP_PATH="$(find "$DERIVED/Build/Products/$CONFIG" -name 'mdeye.app' -maxdepth 2 | head -n1)"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "mdeye.app not found under $DERIVED" >&2
  exit 1
fi

OUT_APP="$ROOT/build/mdeye.app"
rm -rf "$OUT_APP"
cp -R "$APP_PATH" "$OUT_APP"

BIN="$OUT_APP/Contents/MacOS/mdeye"

echo "==> size"
du -sh "$OUT_APP"
du -sh "$BIN" 2>/dev/null || true
du -sh "$OUT_APP/Contents/Resources" 2>/dev/null || true

echo "==> architectures"
file "$BIN"
if ! file "$BIN" | grep -q 'x86_64'; then
  echo "ERROR: missing x86_64 slice" >&2
  exit 1
fi
if ! file "$BIN" | grep -q 'arm64'; then
  echo "ERROR: missing arm64 slice" >&2
  exit 1
fi
echo "OK universal binary (arm64 + x86_64)"

echo "==> icon"
# CFBundleIconFile looks in Contents/Resources/AppIcon.icns (NOT nested Resources/)
if [[ ! -f "$OUT_APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "ERROR: AppIcon.icns not at Contents/Resources/AppIcon.icns" >&2
  find "$OUT_APP/Contents/Resources" -type f -name '*.icns' >&2 || true
  find "$OUT_APP/Contents/Resources" -maxdepth 3 -type d >&2 || true
  exit 1
fi
echo "OK icon: Contents/Resources/AppIcon.icns ($(du -h "$OUT_APP/Contents/Resources/AppIcon.icns" | awk '{print $1}'))"

# Size gate for full pack (Mermaid included). Override with MAX_APP_KB.
SIZE_KB=$(du -sk "$OUT_APP" | awk '{print $1}')
MAX_KB=${MAX_APP_KB:-20480} # 20 MB
if (( SIZE_KB > MAX_KB )); then
  echo "ERROR: app size ${SIZE_KB}KB exceeds gate ${MAX_KB}KB" >&2
  exit 1
fi

echo "OK: $OUT_APP (${SIZE_KB}KB)"
