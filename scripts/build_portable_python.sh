#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/mac/build"
PY_DIR="$BUILD_DIR/python-runtime"
PYTHON_VERSION_PREFIX="${PYTHON_VERSION_PREFIX:-3.13}"

case "$(uname -m)" in
  arm64) ASSET_ARCH="aarch64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  *) echo "Unsupported macOS arch: $(uname -m)" >&2; exit 1 ;;
esac

rm -rf "$PY_DIR"
mkdir -p "$PY_DIR" "$BUILD_DIR"

echo "▸ Finding latest python-build-standalone for macOS ${ASSET_ARCH}…"
ASSET_URL="$(
  python3 - "$PYTHON_VERSION_PREFIX" "$ASSET_ARCH" <<'PY'
import json
import sys
import urllib.request

version_prefix, arch = sys.argv[1:3]
req = urllib.request.Request(
    "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest",
    headers={"Accept": "application/vnd.github+json", "User-Agent": "LangCheck-release-builder"},
)
with urllib.request.urlopen(req) as response:
    release = json.load(response)

needle = f"cpython-{version_prefix}"
suffix = f"{arch}-apple-darwin-install_only_stripped.tar.gz"
matches = [
    asset["browser_download_url"]
    for asset in release["assets"]
    if asset["name"].startswith(needle) and asset["name"].endswith(suffix)
]
if not matches:
    names = "\n".join(asset["name"] for asset in release["assets"])
    raise SystemExit(f"No python-build-standalone asset matched {needle}*{suffix}\nAvailable assets:\n{names}")
print(matches[0])
PY
)"

ARCHIVE="$BUILD_DIR/python-standalone.tar.gz"
echo "▸ Downloading $ASSET_URL"
curl -L "$ASSET_URL" -o "$ARCHIVE"

echo "▸ Extracting standalone Python…"
tar -xzf "$ARCHIVE" -C "$PY_DIR" --strip-components=1

PYTHON="$PY_DIR/bin/python3"
echo "▸ Installing Python dependencies…"
"$PYTHON" -m pip install --upgrade pip
"$PYTHON" -m pip install -r "$ROOT/requirements.txt"

echo
echo "✅ Portable Python runtime: $PY_DIR"
