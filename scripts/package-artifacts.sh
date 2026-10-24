#!/bin/bash
# Package an already-built signed app, without contacting GitHub or publishing.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
[[ $# == 2 ]] || { echo 'Usage: package-artifacts.sh <version> <build>' >&2; exit 1; }
export RELEASE_VERSION="$1" RELEASE_BUILD="$2"
: "${SITE_URL:?Set SITE_URL to the public HTTPS origin}"
python3 scripts/prepare-info.py
SLUG="$(python3 -c 'import json;print(json.load(open("release.config.json"))["slug"])')"
REPO="${RELEASE_REPOSITORY:-$(python3 -c 'import json;print(json.load(open("release.config.json"))["repository"])')}"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
CREATE_DMG="${CREATE_DMG:-$ROOT_DIR/build/tools/create-dmg/create-dmg}"
NOTES="$ROOT_DIR/docs/release-notes/$RELEASE_VERSION.html"
mkdir -p "$ROOT_DIR/build"
WORK_DIR="$(mktemp -d "$ROOT_DIR/build/package.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
codesign --verify --deep --strict "$APP_DIR"
"$ROOT_DIR/scripts/check-no-github.sh" "$APP_DIR"
EXPECTED_FEED="${SITE_URL%/}/downloads/$SLUG/appcast.xml"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_DIR/Contents/Info.plist")" == "$EXPECTED_FEED" ]] || { echo 'Built app feed does not match SITE_URL; rebuild the app' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" == "$RELEASE_VERSION" ]] || { echo 'App version does not match requested package version' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")" == "$RELEASE_BUILD" ]] || { echo 'App build does not match requested package build' >&2; exit 1; }
[[ -f "$NOTES" ]] || { echo 'Write reviewed HTML release notes first' >&2; exit 1; }
SPARKLE_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
STEM="$(python3 -c 'import json;print(json.load(open("release.config.json"))["assetStem"])')"
ARTIFACT_DIR="${ARTIFACT_ROOT:-$ROOT_DIR/dist}/$RELEASE_VERSION"
[[ ! -e "$ARTIFACT_DIR" ]] || { echo 'Local release folder already exists. Inspect it before retrying; nothing was overwritten.' >&2; exit 1; }
mkdir -p "$ARTIFACT_DIR" "$WORK_DIR/dmg" "$WORK_DIR/feed"
ditto "$APP_DIR" "$WORK_DIR/dmg/Dynamic Island.app"
cp "$ROOT_DIR/Resources/Install.txt" "$WORK_DIR/dmg/Install.txt"
DMG="$ARTIFACT_DIR/$STEM-$RELEASE_VERSION.dmg"
"$CREATE_DMG" --volname 'Dynamic Island' --window-pos 200 120 --window-size 600 400 \
  --icon-size 100 --icon 'Dynamic Island.app' 150 170 --hide-extension 'Dynamic Island.app' \
  --app-drop-link 450 170 "$DMG" "$WORK_DIR/dmg"
hdiutil verify "$DMG"
ZIP="$WORK_DIR/feed/$STEM-$RELEASE_VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP"
python3 scripts/check-artifact-sizes.py "$DMG" "$ZIP"
cp "$NOTES" "$WORK_DIR/feed/$STEM-$RELEASE_VERSION.html"
PREFIX="${SITE_URL%/}/downloads/$SLUG/"
ARGS=(--download-url-prefix "$PREFIX" --embed-release-notes --maximum-deltas 0 -o "$WORK_DIR/feed/appcast.xml")
# CI passes the exported Sparkle secret via stdin; it is never placed in arguments or a source file.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_ROOT/bin/generate_appcast" --ed-key-file - "${ARGS[@]}" "$WORK_DIR/feed"
else
  "$SPARKLE_ROOT/bin/generate_appcast" "${ARGS[@]}" "$WORK_DIR/feed"
fi
# generate_appcast can warn and omit an EdDSA signature on key mismatch. Fail before upload.
python3 scripts/validate-appcast.py "$WORK_DIR/feed/appcast.xml" "$RELEASE_VERSION" "$RELEASE_BUILD" "$PREFIX$STEM-$RELEASE_VERSION.zip"
# Independently verify the generated archive with the public key shipped in the app.
xcrun swiftc -module-cache-path "$ROOT_DIR/build/ModuleCache" "$ROOT_DIR/scripts/verify-update.swift" -o "$WORK_DIR/VerifyUpdate"
python3 - "$ZIP" "$WORK_DIR/feed/appcast.xml" "$APP_DIR/Contents/Info.plist" "$WORK_DIR/VerifyUpdate" <<'PYVERIFY'
import pathlib,plistlib,subprocess,sys,xml.etree.ElementTree as ET
archive=pathlib.Path(sys.argv[1]);enclosure=ET.parse(sys.argv[2]).find('./channel/item/enclosure')
if int(enclosure.get('length','0'))!=archive.stat().st_size:sys.exit('Appcast length does not match archive')
key=plistlib.loads(pathlib.Path(sys.argv[3]).read_bytes())['SUPublicEDKey']
signature=enclosure.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
subprocess.run([sys.argv[4],str(archive),signature,key],check=True)
PYVERIFY
cp "$ZIP" "$WORK_DIR/feed/appcast.xml" "$ARTIFACT_DIR/"
cp "$NOTES" "$ARTIFACT_DIR/$STEM-$RELEASE_VERSION.html"
(cd "$ARTIFACT_DIR" && shasum -a 256 "$STEM-$RELEASE_VERSION.dmg" > "$STEM-$RELEASE_VERSION.dmg.sha256")
python3 scripts/release-notes.py "$NOTES" "$ARTIFACT_DIR/release-notes.md"
python3 - "$ARTIFACT_DIR" <<'PYSUM'
import hashlib,pathlib,sys
root=pathlib.Path(sys.argv[1])
for file in root.iterdir():
 if file.is_file() and not file.name.endswith('.sha256'):
  file.with_name(file.name+'.sha256').write_text(hashlib.sha256(file.read_bytes()).hexdigest()+'  '+file.name+'\n')
PYSUM
printf 'Packaged (not published): %s\n' "$ARTIFACT_DIR"
