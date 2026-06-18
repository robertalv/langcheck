#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${APP_VERSION:-1.0.0}"
ARCH="${ARCH:-$(uname -m)}"
APP="$ROOT/mac/dist/LangCheck.app"
DIST="$ROOT/mac/dist"
STAGING="$DIST/dmg-staging"
DMG="$DIST/LangCheck-$VERSION-$ARCH.dmg"
VOLNAME="LangCheck $VERSION"

if [[ ! -d "$APP" ]]; then
  echo "Missing app bundle: $APP" >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/LangCheck.app"
ln -s /Applications "$STAGING/Applications"

echo "▸ Creating compressed DMG…"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG"

rm -rf "$STAGING"

echo
echo "✅ Built: $DMG"
du -sh "$DMG" | awk '{print "   Size: " $1}'
