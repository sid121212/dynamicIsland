#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Dynamic Island.app"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
SWIFT_FLAGS=()
if [[ "${1:-}" == "--debug" ]]; then
  SWIFT_FLAGS=(-D DEBUG)
fi

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Frameworks"
CMAKE_BIN="$(command -v cmake || true)"
if [[ -z "$CMAKE_BIN" && -x /opt/homebrew/bin/cmake ]]; then CMAKE_BIN=/opt/homebrew/bin/cmake; fi
if [[ -z "$CMAKE_BIN" ]]; then echo "CMake is required: brew install cmake" >&2; exit 1; fi
"$CMAKE_BIN" -S "$ROOT_DIR/Vendor/mediaremote-adapter" -B "$BUILD_DIR/mediaremote-adapter" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
"$CMAKE_BIN" --build "$BUILD_DIR/mediaremote-adapter" --parallel 4
ditto "$BUILD_DIR/mediaremote-adapter/MediaRemoteAdapter.framework" "$APP_DIR/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$BUILD_DIR/mediaremote-adapter/MediaRemoteAdapterTestClient" "$APP_DIR/Contents/MacOS/"
cp "$ROOT_DIR/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Vendor/mediaremote-adapter/LICENSE" "$APP_DIR/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"

xcrun swiftc \
  -default-isolation MainActor \
  "${SWIFT_FLAGS[@]}" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos15.0 \
  -O \
  -framework AppKit \
  -framework CoreAudio \
  -framework CoreLocation \
  -framework EventKit \
  -framework IOKit \
  -framework ServiceManagement \
  -framework Quartz \
  "$ROOT_DIR/Sources/DynamicIslandMac/TrayView.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/TraySettings.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/TrayStore.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/ClipboardMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/ScreenshotWatcher.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/VolumeService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/LevelSliderView.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/BrightnessService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/MediaKeyTap.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/CalendarService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/WeatherService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/WeatherSettings.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/NowPlayingService.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/SystemMonitor.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/DiagnosticsModel.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/PermissionsManager.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/NotchSurface.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/main.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandMac"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos15.0 \
  -O \
  "$ROOT_DIR/Sources/DynamicIslandMac/Notify.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandNotify"

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  security find-identity -v -p codesigning | rg -F "\"$SIGNING_IDENTITY\"" >/dev/null || {
    echo "Missing signing identity: $SIGNING_IDENTITY" >&2
    exit 1
  }
else
  echo "Ad-hoc signing retained at user request; permission persistence is not verified." >&2
fi
codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR/Contents/MacOS/MediaRemoteAdapterTestClient"
codesign --force --options runtime --entitlements "$ROOT_DIR/Resources/Entitlements.plist" --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR/Contents/MacOS/DynamicIslandNotify"
codesign --force --options runtime --entitlements "$ROOT_DIR/Resources/Entitlements.plist" --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
echo "$APP_DIR"
