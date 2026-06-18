#!/usr/bin/env bash
#
# Build LangCheck.app — a native SwiftUI front-end with the spaCy Python engine
# bundled inside. Output: mac/dist/LangCheck.app
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"     # …/langcheck/mac
ROOT="$(cd "$HERE/.." && pwd)"            # …/langcheck
PKG="$HERE/LangCheck"                     # swift package
APP="$HERE/dist/LangCheck.app"
VENV="$ROOT/venv"
LOGO="$ROOT/logo.png"
ENTITLEMENTS="$HERE/entitlements.plist"

APP_VERSION="${APP_VERSION:-1.0.0}"
APP_BUILD="${APP_BUILD:-$APP_VERSION}"
LANGCHECK_UPDATE_FEED_URL="${LANGCHECK_UPDATE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
PYENGINE_PYTHON_DIR="${PYENGINE_PYTHON_DIR:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

echo "▸ Building release binary…"
( cd "$PKG" && swift build -c release )
BIN="$PKG/.build/release/LangCheck"

echo "▸ Assembling app bundle…"
rm -rf "$HERE/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/pyengine" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/LangCheck"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/LangCheck" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LangCheck</string>
  <key>CFBundleDisplayName</key><string>LangCheck</string>
  <key>CFBundleIdentifier</key><string>com.langcheck.app</string>
  <key>CFBundleVersion</key><string>$APP_BUILD</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>LangCheck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>SUEnableInstallerLauncherService</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
PLIST

if [[ -n "$LANGCHECK_UPDATE_FEED_URL" ]]; then
  cat >> "$APP/Contents/Info.plist" <<PLIST
  <key>SUFeedURL</key><string>$LANGCHECK_UPDATE_FEED_URL</string>
PLIST
fi

if [[ -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
  cat >> "$APP/Contents/Info.plist" <<PLIST
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_ED_KEY</string>
PLIST
fi

cat >> "$APP/Contents/Info.plist" <<'PLIST'
</dict>
</plist>
PLIST

SPARKLE_FRAMEWORK="$(find "$PKG/.build" "$HOME/Library/Developer/Xcode/DerivedData" "$HOME/Library/Caches/org.swift.swiftpm" \
  -path '*/Sparkle.framework' -type d -print -quit 2>/dev/null || true)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  echo "▸ Embedding Sparkle.framework…"
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
else
  echo "⚠️  Sparkle.framework was not found after build; updates may not launch."
fi

if [[ -f "$LOGO" ]]; then
  echo "▸ Creating app icon from logo.png…"
  ICONSET="$HERE/dist/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16     "$LOGO" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32     "$LOGO" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32     "$LOGO" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64     "$LOGO" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128   "$LOGO" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256   "$LOGO" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256   "$LOGO" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512   "$LOGO" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512   "$LOGO" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$LOGO" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "▸ logo.png not found; skipping app icon."
fi

echo "▸ Copying Python engine (analyzer.py, cli.py)…"
cp "$ROOT/analyzer.py" "$ROOT/cli.py" "$APP/Contents/Resources/pyengine/"

if [[ -n "$PYENGINE_PYTHON_DIR" ]]; then
  echo "▸ Copying standalone Python engine (spaCy + model + wordfreq)…"
  ditto "$PYENGINE_PYTHON_DIR" "$APP/Contents/Resources/pyengine/python"
else
  echo "▸ Copying virtualenv (spaCy + model + wordfreq) — this is the big step…"
  ditto "$VENV" "$APP/Contents/Resources/pyengine/venv"
fi

find "$APP/Contents/Resources/pyengine" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

sign_macho_files() {
  local root="$1"
  find "$root" -type f -print0 |
    while IFS= read -r -d '' file; do
      if file "$file" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$file"
      fi
    done
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▸ Developer ID code signing…"
  if [[ -d "$APP/Contents/Resources/pyengine" ]]; then
    echo "  signing bundled Python binaries…"
    sign_macho_files "$APP/Contents/Resources/pyengine"
  fi
  if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
    echo "  signing Sparkle.framework…"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  echo "  signing LangCheck.app…"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "▸ Ad-hoc code signing…"
  codesign --force --deep --sign - "$APP" 2>/dev/null && echo "  signed (ad-hoc)" || echo "  (signing skipped — app still runs locally)"
fi

echo
echo "✅ Built: $APP"
du -sh "$APP" | awk '{print "   Size: " $1}'
echo "   Run:  open \"$APP\""
echo
if [[ -n "$PYENGINE_PYTHON_DIR" ]]; then
  echo "This bundle includes a standalone Python runtime."
else
  echo "Note: this bundle uses the system Python.framework 3.13 it was built against."
  echo "      To run on a Mac without that framework, rebuild with a standalone Python"
  echo "      (see README → 'Making it portable')."
fi
