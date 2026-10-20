#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Dynamic Island.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$BUILD_DIR/ModuleCache"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos14.0 \
  -O \
  -framework AppKit \
  -framework CoreAudio \
  -framework CoreLocation \
  -framework EventKit \
  -framework IOKit \
  -framework ServiceManagement \
  "$ROOT_DIR/Sources/DynamicIslandMac/SystemMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/main.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandMac"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos14.0 \
  -O \
  "$ROOT_DIR/Sources/DynamicIslandMac/Notify.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandNotify"

codesign --force --sign - --timestamp=none "$APP_DIR"
echo "$APP_DIR"
