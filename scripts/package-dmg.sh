#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/mdeye.app"
# VERSION is normally supplied by CI (from the git tag). This fallback only matches
# the app version kept in App/Info.plist for offline/legacy use.
VERSION="${VERSION:-0.4.0}"
STAGE="$ROOT/build/dmg-stage"
DMG="$ROOT/build/mdeye-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "missing $APP — build app first" >&2
  exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# UDZO compressed dmg, unsigned
hdiutil create \
  -volname "MDEye" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo "dmg: $DMG"
du -sh "$DMG"
