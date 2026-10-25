#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 ]] || { echo 'Usage: scripts/verify-release.sh dist/' >&2; exit 1; }
if [[ -f "$ROOT/.release.env" ]]; then set -a; source "$ROOT/.release.env"; set +a; fi
if [[ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  SPARKLE_PUBLIC_ED_KEY="$("$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys" -p)"
  export SPARKLE_PUBLIC_ED_KEY
fi
python3 "$ROOT/scripts/verify-release.py" "$1"
