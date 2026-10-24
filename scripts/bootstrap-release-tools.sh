#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/resolve-sparkle.sh" >/dev/null
# Official create-dmg source, pinned to a release; no Homebrew or curl-to-shell.
DEST="$ROOT_DIR/build/tools/create-dmg"
if [[ ! -d "$DEST/.git" ]]; then
  mkdir -p "$(dirname "$DEST")"
  git clone --depth 1 --branch v1.3.0 https://github.com/create-dmg/create-dmg.git "$DEST"
fi
[[ "$(git -C "$DEST" describe --tags --exact-match)" == 'v1.3.0' ]] || { echo 'Unexpected create-dmg checkout' >&2; exit 1; }
[[ "$(git -C "$DEST" rev-parse HEAD)" == 'a2b71d0fda6d0df2a86dc7f67082d4d73e84c59f' ]] || { echo 'Unexpected create-dmg commit' >&2; exit 1; }
"$DEST/create-dmg" --version
