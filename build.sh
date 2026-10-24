#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
APP_DIR="$BUILD_DIR/Dynamic Island.app"
# Fail before touching an existing app. Ad-hoc fallback would break the release contract.
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["signingIdentity"])' "$ROOT_DIR/release.config.json")}"
export SIGNING_IDENTITY
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your self-signed Code Signing certificate name or SHA-1}"
[[ "$SIGNING_IDENTITY" != "-" ]] || { echo "Ad-hoc signing is not allowed" >&2; exit 1; }
security find-identity -v -p codesigning | grep -F -- "$SIGNING_IDENTITY" >/dev/null || { echo "Missing valid signing identity: $SIGNING_IDENTITY" >&2; exit 1; }
python3 "$ROOT_DIR/scripts/prepare-info.py"
SPARKLE_ROOT="$("$ROOT_DIR/scripts/resolve-sparkle.sh")"
SPARKLE_FRAMEWORK="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
SWIFT_FLAGS=()
if [[ "${1:-}" == "--debug" ]]; then
  SWIFT_FLAGS=(-D DEBUG)
fi

if [[ "${NOTARIZED:-0}" == "1" ]]; then SWIFT_FLAGS+=(-D NOTARIZED); fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MODULE_CACHE"
python3 "$ROOT_DIR/scripts/prepare-info.py" "$APP_DIR/Contents/Info.plist"
mkdir -p "$APP_DIR/Contents/Frameworks"
rm -rf "$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
CMAKE_BIN="$(command -v cmake || true)"
if [[ -z "$CMAKE_BIN" ]]; then echo "CMake is required. Install the official CMake distribution; see docs/RELEASING.md." >&2; exit 1; fi
"$CMAKE_BIN" -S "$ROOT_DIR/Vendor/mediaremote-adapter" -B "$BUILD_DIR/mediaremote-adapter" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64
"$CMAKE_BIN" --build "$BUILD_DIR/mediaremote-adapter" --parallel 4
ditto "$BUILD_DIR/mediaremote-adapter/MediaRemoteAdapter.framework" "$APP_DIR/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$BUILD_DIR/mediaremote-adapter/MediaRemoteAdapterTestClient" "$APP_DIR/Contents/MacOS/"
cp "$ROOT_DIR/Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Vendor/mediaremote-adapter/LICENSE" "$APP_DIR/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
cp "$ROOT_DIR/.build/checkouts/Sparkle/LICENSE" "$APP_DIR/Contents/Resources/Sparkle-LICENSE.txt"

xcrun swiftc \
  -default-isolation MainActor \
  "${SWIFT_FLAGS[@]}" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos15.0 \
  -O \
  -F "$APP_DIR/Contents/Frameworks" \
  -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
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
  "$ROOT_DIR/Sources/DynamicIslandMac/UpdatePolicy.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/AppUpdates.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/FirstLaunchHelp.swift" \
  "$ROOT_DIR/Sources/DynamicIslandMac/main.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandMac"

xcrun swiftc \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -target arm64-apple-macos15.0 \
  -O \
  "$ROOT_DIR/Sources/DynamicIslandMac/Notify.swift" \
  -o "$APP_DIR/Contents/MacOS/DynamicIslandNotify"

"$ROOT_DIR/scripts/sign-app.sh" "$APP_DIR"
echo "$APP_DIR"
