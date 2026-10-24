#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:?Usage: sign-app.sh /path/to/App.app}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["signingIdentity"])' "$ROOT_DIR/release.config.json")}"
export SIGNING_IDENTITY
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your self-signed Code Signing certificate name or SHA-1}"
if [[ "$SIGNING_IDENTITY" == '-' ]]; then echo 'Ad-hoc signing is not allowed' >&2; exit 1; fi
IDENTITIES="$(security find-identity -v -p codesigning)"
if ! printf '%s\n' "$IDENTITIES" | grep -F -- "$SIGNING_IDENTITY" >/dev/null; then
  echo "Missing valid signing identity: $SIGNING_IDENTITY" >&2; exit 1
fi
sign() { codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$@"; }
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
test -d "$FRAMEWORK" || { echo 'Missing Sparkle.framework' >&2; exit 1; }
# Real paths only: do not sign symlink aliases twice. Leaf Mach-O code before enclosing bundles.
while IFS= read -r -d '' code; do
  if file -b "$code" | grep -q 'Mach-O'; then sign --preserve-metadata=entitlements "$code"; fi
done < <(find "$FRAMEWORK" -type f -print0)
while IFS= read -r -d '' bundle; do sign --preserve-metadata=entitlements "$bundle"; done < <(find "$FRAMEWORK" -depth -type d \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0)
sign "$APP_DIR/Contents/Frameworks/MediaRemoteAdapter.framework"
sign "$APP_DIR/Contents/MacOS/MediaRemoteAdapterTestClient"
sign --entitlements "$ROOT_DIR/Resources/Entitlements.plist" "$APP_DIR/Contents/MacOS/DynamicIslandNotify"
sign --entitlements "$ROOT_DIR/Resources/Entitlements.plist" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR" 2>&1
