#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h}"
if (( $# != 2 )); then
  echo 'Usage: ./package.sh <version> <build> (builds and publishes a GitHub release; see docs/RELEASING.md)' >&2
  exit 1
fi
exec "$ROOT_DIR/scripts/release.sh" "$@"
