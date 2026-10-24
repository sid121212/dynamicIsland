#!/bin/bash
set -euo pipefail
: "${SITE_DISPATCH_TOKEN:?Set SITE_DISPATCH_TOKEN with access to the private site repository}"
SITE_REPOSITORY="${SITE_REPOSITORY:-sid121212/zero-dollar-labs}"
[[ "$SITE_REPOSITORY" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]] || exit 1
SLUG="$(python3 -c 'import json;print(json.load(open("release.config.json"))["slug"])')"
VERSION="${GITHUB_REF_NAME#v}"
export GH_TOKEN="$SITE_DISPATCH_TOKEN"
python3 - "$SLUG" "$VERSION" <<'PYDISPATCH' | gh api --method POST "repos/$SITE_REPOSITORY/dispatches" --input -
import json,sys
print(json.dumps({'event_type':'app-released','client_payload':{'slug':sys.argv[1],'version':sys.argv[2]}}))
PYDISPATCH
