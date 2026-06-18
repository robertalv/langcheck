#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/mac/build"
PY_DIR="$BUILD_DIR/python-runtime"
PYTHON_VERSION_PREFIX="${PYTHON_VERSION_PREFIX:-3.13}"
PYTHON_STANDALONE_ASSET_URL="${PYTHON_STANDALONE_ASSET_URL:-}"
PYTHON_STANDALONE_RESOLVE_ONLY="${PYTHON_STANDALONE_RESOLVE_ONLY:-0}"

case "$(uname -m)" in
  arm64) ASSET_ARCH="aarch64" ;;
  x86_64) ASSET_ARCH="x86_64" ;;
  *) echo "Unsupported macOS arch: $(uname -m)" >&2; exit 1 ;;
esac

rm -rf "$PY_DIR"
mkdir -p "$PY_DIR" "$BUILD_DIR"

if [[ -n "$PYTHON_STANDALONE_ASSET_URL" ]]; then
  ASSET_URL="$PYTHON_STANDALONE_ASSET_URL"
else
  echo "▸ Finding latest python-build-standalone for macOS ${ASSET_ARCH}…"
  ASSET_URL="$(
    python3 - "$PYTHON_VERSION_PREFIX" "$ASSET_ARCH" <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

version_prefix, arch = sys.argv[1:3]
token = os.environ.get("GITHUB_TOKEN")
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "LangCheck-release-builder",
    "X-GitHub-Api-Version": "2022-11-28",
}
if token:
    headers["Authorization"] = f"Bearer {token}"

req = urllib.request.Request(
    "https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest",
    headers=headers,
)

last_error = None
for attempt in range(5):
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            release = json.load(response)
        break
    except urllib.error.HTTPError as error:
        last_error = error
        if error.code in (403, 429, 500, 502, 503, 504) and attempt < 4:
            reset = error.headers.get("x-ratelimit-reset")
            if reset and reset.isdigit():
                delay = max(2, min(60, int(reset) - int(time.time()) + 1))
            else:
                delay = 2 ** attempt
            print(f"GitHub API returned HTTP {error.code}; retrying in {delay}s...", file=sys.stderr)
            time.sleep(delay)
            continue
        raise
else:
    raise last_error

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
fi

if [[ "$PYTHON_STANDALONE_RESOLVE_ONLY" == "1" ]]; then
  echo "✅ Resolved portable Python asset: $ASSET_URL"
  exit 0
fi

ARCHIVE="$BUILD_DIR/python-standalone.tar.gz"
echo "▸ Downloading $ASSET_URL"
curl --fail --location --retry 5 --retry-delay 2 --retry-all-errors "$ASSET_URL" -o "$ARCHIVE"

echo "▸ Extracting standalone Python…"
tar -xzf "$ARCHIVE" -C "$PY_DIR" --strip-components=1

PYTHON="$PY_DIR/bin/python3"
echo "▸ Installing Python dependencies…"
"$PYTHON" -m pip install --upgrade pip
"$PYTHON" -m pip install -r "$ROOT/requirements.txt"

echo
echo "✅ Portable Python runtime: $PY_DIR"
