#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
DIST_DIR="$ROOT_DIR/dist"

# Always package the release build; debug-only controls are excluded.
"$ROOT_DIR/build.sh"
codesign --verify --deep --strict "$APP_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/build/dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$DIST_DIR"
ditto "$APP_DIR" "$STAGING_DIR/Dynamic Island.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/Install.txt" <<'INSTALL'
Dynamic Island for Mac

1. Quit any currently running Dynamic Island instance from its menu-bar menu.
2. Drag Dynamic Island.app onto the Applications shortcut.
3. Open Dynamic Island from Applications, then eject this disk image.

Requires an Apple Silicon Mac with macOS 15 or later.
The app lives in the menu bar and at the hardware notch; it has no Dock icon.
Use the capsule menu-bar icon and Toggle Island to open the dashboard.
Hover just below the camera or use Toggle Island to open the dashboard.
Controls uses the sliders icon to the right of the camera. Brightness is available
on the selected built-in display; external displays show it as unavailable.
Media-key HUD replacement requires Accessibility and Input Monitoring permission.

Calendar, Weather and media controls may request their associated permissions
when enabled. Enable Launch at Login from the app's menu after installation.

This build is locally ad-hoc signed, not Apple-notarized. If macOS blocks the
first launch, use Finder's Open command or System Settings > Privacy & Security
to approve this locally built application.
INSTALL

DMG_PATH="$DIST_DIR/DynamicIsland-$VERSION-arm64.dmg"
hdiutil create -volname "Dynamic Island" -srcfolder "$STAGING_DIR" \
  -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
echo "$DMG_PATH"
