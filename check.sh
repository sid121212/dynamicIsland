#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h}"
mkdir -p "$ROOT_DIR/build/ModuleCache"
xcrun swiftc \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$ROOT_DIR/build/ModuleCache" \
  -target arm64-apple-macos14.0 \
  -framework AppKit -framework CoreAudio -framework CoreLocation -framework EventKit -framework IOKit \
  "$ROOT_DIR/Sources/DynamicIslandMac/SystemMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/NotchSurface.swift" \
  "$ROOT_DIR/Tests/main.swift" \
  -o "$ROOT_DIR/build/LayoutChecks"
"$ROOT_DIR/build/LayoutChecks"
codesign --verify --deep --strict "$ROOT_DIR/build/Dynamic Island.app"
