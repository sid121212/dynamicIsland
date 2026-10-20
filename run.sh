#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if [[ ! -x "$APP_DIR/Contents/MacOS/DynamicIslandMac" ]]; then
  "$ROOT_DIR/build.sh"
fi

pkill -x DynamicIslandMac 2>/dev/null || true
for _ in {1..40}; do
  pgrep -x DynamicIslandMac >/dev/null 2>&1 || break
  sleep 0.05
done
"$LSREGISTER" -f "$APP_DIR"
open "$APP_DIR"
