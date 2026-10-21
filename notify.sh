#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
NOTIFIER="$APP_DIR/Contents/MacOS/DynamicIslandNotify"
TITLE="${1:-Live Activity}"
SUBTITLE="${2:-Update from your script}"
DURATION="${3:-5}"

if [[ ! -x "$NOTIFIER" ]]; then
  "$ROOT_DIR/build.sh"
fi
"$NOTIFIER" "$TITLE" "$SUBTITLE" "$DURATION"
