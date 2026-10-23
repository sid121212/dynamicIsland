#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h}"
mkdir -p "$ROOT_DIR/build/ModuleCache"
xcrun swiftc \
  -default-isolation MainActor \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -module-cache-path "$ROOT_DIR/build/ModuleCache" \
  -target arm64-apple-macos15.0 \
  -framework AppKit -framework CoreAudio -framework CoreLocation -framework EventKit -framework IOKit \
  -framework Quartz \
  "$ROOT_DIR/Sources/DynamicIslandMac/TrayView.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/TrayStore.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/ClipboardMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/ScreenshotWatcher.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/VolumeService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/LevelSliderView.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/BrightnessService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/MediaKeyTap.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/CalendarService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/WeatherService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/NowPlayingService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/SystemMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/DiagnosticsModel.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/PermissionsManager.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/NotchSurface.swift" \
  "$ROOT_DIR/Tests/main.swift" \
  "$ROOT_DIR/Tests/TrayChecks.swift" \
  -o "$ROOT_DIR/build/LayoutChecks"
"$ROOT_DIR/build/LayoutChecks"
codesign --verify --deep --strict "$ROOT_DIR/build/Dynamic Island.app"
