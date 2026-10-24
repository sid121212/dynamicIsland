#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
REPO="${GITHUB_REPOSITORY:-$(python3 -c 'import json;print(json.load(open("release.config.json"))["repository"])')}"
: "${SITE_URL:?Set SITE_URL to your public HTTPS origin}"
SLUG="$(python3 -c 'import json;print(json.load(open("release.config.json"))["slug"])')"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
FAILED=0
DMG="${SITE_URL%/}/download/$SLUG/"
FEED="${SITE_URL%/}/downloads/$SLUG/appcast.xml"
printf 'Daily public download check\n\n' > "$WORK_DIR/body.md"
for url in "$DMG" "$FEED"; do
  CODE="$(curl -I -L --silent --show-error --max-time 60 --retry 2 --output /dev/null --write-out '%{http_code}' "$url")" || CODE='request-failed'
  printf -- '- %s → %s\n' "$url" "$CODE" >> "$WORK_DIR/body.md"
  [[ "$CODE" == 200 ]] || FAILED=1
done
if (( FAILED )); then
  ISSUE="$(gh issue list --repo "$REPO" --state open --search '"Download or appcast is broken" in:title' --json title,number --jq '.[] | select(.title == "Download or appcast is broken") | .number' | head -1)"
  if [[ -n "$ISSUE" ]]; then
    gh issue comment "$ISSUE" --repo "$REPO" --body-file "$WORK_DIR/body.md"
  else
    gh issue create --repo "$REPO" --title 'Download or appcast is broken' --body-file "$WORK_DIR/body.md"
  fi
  cat "$WORK_DIR/body.md"; exit 1
fi
cat "$WORK_DIR/body.md"
