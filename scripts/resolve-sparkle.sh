#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
swift package resolve >&2
SPARKLE_ROOT="$ROOT_DIR/.build/artifacts/sparkle/Sparkle"
test -d "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" || { echo 'Sparkle artifact missing after SwiftPM resolve' >&2; exit 1; }
printf '%s\n' "$SPARKLE_ROOT"
