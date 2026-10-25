#!/bin/bash
# Package a signed build, without publishing. dist has exactly the release contract's five assets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source release/config.sh
[[ $# == 2 ]] || { echo 'Usage: scripts/package-artifacts.sh <version> <build>' >&2; exit 1; }
export RELEASE_VERSION="$1" RELEASE_BUILD="$2"
: "${SITE_URL:?Set SITE_URL}"
APP="$ROOT/build/Dynamic Island.app"
OUT="${ARTIFACT_ROOT:-$ROOT/dist}"
[[ ! -e "$OUT" || -z "$(ls -A "$OUT")" ]] || { echo 'Artifact folder is not empty; archive prior artifacts before releasing. Nothing overwritten.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
scripts/check-no-github.sh "$APP"
python3 scripts/check-license-files.py "$APP/Contents/Resources"
CREATE_DMG="${CREATE_DMG:-$ROOT/build/tools/create-dmg/create-dmg}"
[[ -x "$CREATE_DMG" ]] || { echo 'Run scripts/bootstrap-release-tools.sh to install create-dmg without Homebrew' >&2; exit 1; }
TMP="$(mktemp -d "$ROOT/build/contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT" "$TMP/dmg" "$TMP/feed"
ditto "$APP" "$TMP/dmg/Notch.app"
cp "$APP/Contents/Resources/LICENSE.txt" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.txt" "$TMP/dmg/"
cp Resources/Install.txt "$TMP/dmg/Install.txt"
"$CREATE_DMG" --volname Notch --window-pos 200 120 --window-size 600 400 --icon-size 100 --icon Notch.app 150 170 --hide-extension Notch.app --app-drop-link 450 170 "$OUT/$ASSET_BASE-$RELEASE_VERSION.dmg" "$TMP/dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP/feed/$ASSET_BASE-$RELEASE_VERSION.zip"
python3 scripts/release-note-source.py "$RELEASE_VERSION" "$OUT/release-notes.md" "$TMP/feed/$ASSET_BASE-$RELEASE_VERSION.html"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
"$SPARKLE/generate_appcast" --download-url-prefix "$SITE_URL/downloads/$SLUG/" --embed-release-notes --maximum-deltas 0 -o "$TMP/feed/appcast.xml" "$TMP/feed"
cp "$TMP/feed/$ASSET_BASE-$RELEASE_VERSION.zip" "$TMP/feed/appcast.xml" "$OUT/"
(cd "$OUT" && shasum -a 256 "$ASSET_BASE-$RELEASE_VERSION.dmg" > "$ASSET_BASE-$RELEASE_VERSION.dmg.sha256")
"$ROOT/scripts/verify-release.sh" "$OUT"
echo "Packaged (not published): $OUT"
