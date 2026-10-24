#!/bin/bash
set -euo pipefail
APP="${1:?Usage: check-no-github.sh path/to/App.app}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
plutil -convert xml1 -o "$WORK/info.xml" "$APP/Contents/Info.plist"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
strings "$APP/Contents/MacOS/$EXECUTABLE" > "$WORK/executable.txt"
if LC_ALL=C grep -ERina 'github\.com|githubusercontent\.com|github\.io|ghcr\.io|gist\.github|git\.io' "$WORK" "$APP/Contents/Resources"; then
  echo 'Forbidden host in app Info.plist, Resources or main executable' >&2; exit 1
fi
echo 'App public-host guard passed (Sparkle.framework excluded)'
