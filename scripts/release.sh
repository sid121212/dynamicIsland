#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
[[ $# == 2 ]] || { echo 'Usage: scripts/release.sh <semver> <integer-build>' >&2; exit 1; }
export RELEASE_VERSION="$1" RELEASE_BUILD="$2" NOTARIZED=0
REPO="${RELEASE_REPOSITORY:-$(python3 -c 'import json;print(json.load(open("release.config.json"))["repository"])')}"
export RELEASE_REPOSITORY="$REPO"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["signingIdentity"])' "$ROOT_DIR/release.config.json")}"
export SIGNING_IDENTITY
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY; see docs/RELEASING.md}"
python3 scripts/prepare-info.py
for tool in gh ditto hdiutil shasum python3 cmake; do command -v "$tool" >/dev/null || { echo "Missing release tool: $tool (see docs/RELEASING.md; no Homebrew needed)" >&2; exit 1; }; done
CREATE_DMG="${CREATE_DMG:-$ROOT_DIR/build/tools/create-dmg/create-dmg}"
[[ -x "$CREATE_DMG" ]] || { echo 'Missing create-dmg. Run scripts/bootstrap-release-tools.sh first.' >&2; exit 1; }
gh auth status >/dev/null
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "v$RELEASE_VERSION^{commit}")" ]] || { echo 'Check out the exact release tag before publishing' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit or remove untracked source changes before releasing' >&2; exit 1; }
# GitHub tag/release names are immutable here. Never overwrite a published feed or artifact.
if gh release view "v$RELEASE_VERSION" --repo "$REPO" >/dev/null 2>&1; then echo 'Release already exists; choose a new version/build' >&2; exit 1; fi
mkdir -p "$ROOT_DIR/build"
WORK_DIR="$(mktemp -d "$ROOT_DIR/build/release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
# Include beta releases in the monotonic counter. Treat API failure as an error, not an empty history.
gh api --paginate "repos/$REPO/releases?per_page=100" --jq '.[].body // ""' > "$WORK_DIR/history.txt"
python3 - "$RELEASE_BUILD" "$WORK_DIR/history.txt" <<'PY'
import pathlib,plistlib,re,sys
current=int(sys.argv[1]);text=pathlib.Path(sys.argv[2]).read_text()
prior=[int(x) for x in re.findall(r'<!-- zerodollarlabs-build:(\d+) -->',text)]
baseline=int(plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())['CFBundleVersion'])
if current<baseline or (prior and current<=max(prior)):sys.exit('Build must be at least the committed build and greater than every published build, including betas')
PY
NOTES="$ROOT_DIR/docs/release-notes/$RELEASE_VERSION.html"
[[ -f "$NOTES" ]] || { echo "Write release notes first: $NOTES" >&2; exit 1; }
"$ROOT_DIR/build.sh"
APP_DIR="$ROOT_DIR/build/Dynamic Island.app"
codesign --verify --deep --strict "$APP_DIR"
codesign --display --verbose=4 "$APP_DIR" 2>&1
"$ROOT_DIR/scripts/package-artifacts.sh" "$RELEASE_VERSION" "$RELEASE_BUILD"
STEM="$(python3 -c 'import json;print(json.load(open("release.config.json"))["assetStem"])')"
ARTIFACT_DIR="$ROOT_DIR/dist/$RELEASE_VERSION"
DMG="$ARTIFACT_DIR/$STEM-$RELEASE_VERSION.dmg"
python3 - "$NOTES" "$WORK_DIR/release-body.md" "$RELEASE_BUILD" <<'PY'
import pathlib,sys
from html.parser import HTMLParser
class Text(HTMLParser):
 def __init__(self): super().__init__();self.parts=[]
 def handle_data(self,d): self.parts.append(d.strip())
p=Text();p.feed(pathlib.Path(sys.argv[1]).read_text())
pathlib.Path(sys.argv[2]).write_text('\n\n'.join(x for x in p.parts if x)+'\n\nSelf-signed, not notarized. Apple Silicon, macOS 15+. Download the DMG, compare the SHA-256, then drag the app into Applications. First-launch approval instructions are in Install.txt and the website.\n\n<!-- zerodollarlabs-build:'+sys.argv[3]+' -->\n')
PY
# Upload a draft first. Publish only after every asset is present. A failed upload leaves a draft to inspect.
PRE=(--prerelease=false); [[ "$RELEASE_VERSION" != *-* ]] || PRE=(--prerelease)
gh release create "v$RELEASE_VERSION" --repo "$REPO" --verify-tag --draft "${PRE[@]}" \
  --title "Dynamic Island $RELEASE_VERSION" --notes-file "$WORK_DIR/release-body.md" \
  "$ARTIFACT_DIR/"*
if [[ "$RELEASE_VERSION" == *-* ]]; then
  gh release edit "v$RELEASE_VERSION" --repo "$REPO" --draft=false --prerelease --latest=false
else
  gh release edit "v$RELEASE_VERSION" --repo "$REPO" --draft=false --latest
fi
python3 - "$DMG" "$RELEASE_VERSION" <<'PY'
import hashlib,pathlib,sys
p=pathlib.Path(sys.argv[1]);print(f'Website: version={sys.argv[2]} size={p.stat().st_size} bytes sha256={hashlib.sha256(p.read_bytes()).hexdigest()}')
print('Public feed: '+__import__('os').environ['SITE_URL'].rstrip('/')+'/downloads/notch/appcast.xml')
PY
