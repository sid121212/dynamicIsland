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
# Clean up helpers orphaned by older builds that did not handle SIGTERM.
# Match only this exact development bundle's adapter script and parent launchd.
while read -r ADAPTER_PID ADAPTER_PARENT ADAPTER_COMMAND; do
  if [[ "$ADAPTER_PARENT" == "1" && "$ADAPTER_COMMAND" == "/usr/bin/perl $APP_DIR/Contents/Resources/mediaremote-adapter.pl "* ]]; then
    kill -TERM "$ADAPTER_PID" 2>/dev/null || true
  fi
done < <(ps -axo pid=,ppid=,command=)
"$LSREGISTER" -f "$APP_DIR"
open -n "$APP_DIR" --args "$@"

sleep 0.4
RUNNING_PATH="$(ps -ax -o command= | grep '/Dynamic Island.app/Contents/MacOS/DynamicIslandMac' | grep -v grep | tail -1 || true)"
if [[ "$RUNNING_PATH" != "$APP_DIR/Contents/MacOS/DynamicIslandMac" && "$RUNNING_PATH" != "$APP_DIR/Contents/MacOS/DynamicIslandMac "* ]]; then
  echo "Dynamic Island did not launch from the current build: $RUNNING_PATH" >&2
  exit 1
fi
