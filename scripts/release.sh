#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ $# -ge 2 && $# -le 3 ]] || { echo 'Usage: scripts/release.sh <version> <build> [--no-publish | --publish-only]' >&2; exit 1; }
export RELEASE_VERSION="$1" RELEASE_BUILD="$2" NOTARIZED=0
MODE="${3:-}"
[[ -z "$MODE" || "$MODE" == --no-publish || "$MODE" == --publish-only ]] || { echo 'Unknown release option' >&2; exit 1; }
source release/config.sh
if [[ -f .release.env ]]; then set -a; source .release.env; set +a; fi
export SIGNING_IDENTITY="${SIGN_IDENTITY:-NotchDev}"
fail() { echo "Preflight failed: $*" >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || fail 'Check out main before releasing.'
[[ -z "$(git status --porcelain)" ]] || fail 'Git state must be clean on main. Review and commit your changes yourself; this script never commits.'
[[ "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'Version must be X.Y.Z semver (no prerelease).'
[[ "$RELEASE_BUILD" =~ ^[1-9][0-9]*$ ]] || fail 'Build must be a positive integer.'
python3 - <<'PY'
import os,sys,urllib.parse
raw=os.environ.get('SITE_URL','');u=urllib.parse.urlsplit(raw)
if u.scheme!='https' or not u.hostname or u.path or u.query or u.fragment or u.username or u.password or raw.endswith('/') or 'placeholder' in raw or 'example.com' in raw: sys.exit('Preflight failed: Set SITE_URL in .release.env to your HTTPS origin, without a trailing slash.')
PY
[[ "${SITE_REPO:-}" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || fail 'Set SITE_REPO=owner/site-repo in .release.env.'
APP_REPO="$(git remote get-url origin | sed -E 's#^https://github.com/##; s#^git@github.com:##; s#\.git$##')"
[[ "$APP_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || fail 'origin must be a GitHub repository URL.'
[[ "$APP_REPO" != "$SITE_REPO" ]] || fail 'The app and website must have separate private repositories.'
for tool in security gh python3 ditto hdiutil shasum; do command -v "$tool" >/dev/null || fail "Missing $tool."; done
security find-identity -v -p codesigning | grep -F -- "$SIGNING_IDENTITY" >/dev/null || fail "Signing identity $SIGNING_IDENTITY is missing."
gh auth status >/dev/null 2>&1 || fail 'Run gh auth login first.'
[[ "$(gh api "repos/$APP_REPO" --jq .private)" == true ]] || fail 'App repository must be PRIVATE.'
if [[ "$MODE" != --no-publish ]]; then
  [[ "$(gh api "repos/$APP_REPO/commits/main" --jq .sha)" == "$(git rev-parse HEAD)" ]] || fail 'Push the reviewed main commit yourself before publishing; the remote source must match the local build.'
fi
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
for tool in generate_keys generate_appcast; do [[ -x "$TOOLS/$tool" ]] || fail "Missing Sparkle tool: $TOOLS/$tool (resolve SwiftPM first)."; done
git show-ref --verify --quiet "refs/tags/v$RELEASE_VERSION" && fail 'Tag already exists locally. Bump the version.'
mkdir -p "$ROOT/build"
TMP="$(mktemp -d "$ROOT/build/preflight.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Treat an unavailable history as a failure, never an empty release history.
gh api --paginate "repos/$APP_REPO/tags?per_page=100" --jq '.[].name' > "$TMP/tags"
! grep -Fx "v$RELEASE_VERSION" "$TMP/tags" >/dev/null || fail 'Tag already exists remotely. Bump the version.'
LATEST="$(python3 - "$TMP/tags" <<'PY'
import pathlib,re,sys
v=[x for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if re.fullmatch(r'v\d+\.\d+\.\d+',x)]
print(max(v,key=lambda x:tuple(map(int,x[1:].split('.')))) if v else '')
PY
)"
BASELINE=0
if [[ -n "$LATEST" ]]; then
  mkdir -p "$TMP/previous"
  gh release download "$LATEST" --repo "$APP_REPO" --pattern appcast.xml --dir "$TMP/previous"
  BASELINE="$(python3 - "$TMP/previous/appcast.xml" <<'PYBUILD'
import pathlib,re,sys,xml.etree.ElementTree as ET
S='http://www.andymatuschak.org/xml-namespaces/sparkle'
item=ET.parse(sys.argv[1]).find('./channel/item')
if item is None:sys.exit('Cannot read latest tag build from its appcast')
enc=item.find('enclosure');value=item.findtext('{'+S+'}version') or (enc.get('{'+S+'}version') if enc is not None else None)
if not re.fullmatch(r'[1-9]\d*',value or ''):sys.exit('Latest tag appcast has no integer build')
print(value)
PYBUILD
)"
fi
python3 - "$RELEASE_BUILD" "$BASELINE" <<'PY'
import plistlib,pathlib,sys
current=int(sys.argv[1]);previous=int(sys.argv[2]);committed=int(plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())['CFBundleVersion'])
if current<=previous or current<committed:sys.exit(f'Preflight failed: build {current} must exceed latest tag build {previous} and be at least committed build {committed}.')
PY
export SPARKLE_PUBLIC_ED_KEY="$("$TOOLS/generate_keys" -p)"
if [[ "$MODE" != --publish-only ]]; then
  ./build.sh
  ./scripts/package-artifacts.sh "$RELEASE_VERSION" "$RELEASE_BUILD"
else
  ./scripts/verify-release.sh "$ROOT/dist"
fi
if [[ "$MODE" == --no-publish ]]; then
  echo 'Verified dry run: not published. Review dist/ before publishing.'
  exit 0
fi
# Exactly the five verified contract assets; never upload arbitrary files or secrets.
gh release create "v$RELEASE_VERSION" dist/* --repo "$APP_REPO" --title "$NAME $RELEASE_VERSION" --notes-file dist/release-notes.md --draft=false --prerelease=false --target "$(git rev-parse HEAD)"
echo "Release: https://github.com/$APP_REPO/releases/tag/v$RELEASE_VERSION"
echo 'The app-released notifier triggers the site rebuild. Check both workflow runs.'
