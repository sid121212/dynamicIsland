#!/bin/bash
set -euo pipefail
if [[ -z "${SITE_DEPLOY_HOOK_URL:-}" ]]; then
  echo 'No website deploy hook configured; skipping.'; exit 0
fi
# Suppress secret hook URLs in output, including curl errors.
if ! curl --fail --silent --request POST "$SITE_DEPLOY_HOOK_URL" --output /dev/null; then
  echo 'Website deploy hook failed. Rebuild manually; the app release remains published.' >&2; exit 1
fi
