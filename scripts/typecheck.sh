#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SPARKLE_ROOT="$("$ROOT_DIR/scripts/resolve-sparkle.sh")"
mkdir -p "$ROOT_DIR/build/ModuleCache"
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find "$ROOT_DIR/Sources/DynamicIslandMac" -name '*.swift' ! -name Notify.swift -print0)
flags=(-D UNNOTARIZED)
if [[ "${NOTARIZED:-0}" == '1' ]]; then flags+=(-D NOTARIZED); fi
xcrun swiftc -typecheck -default-isolation MainActor "${flags[@]}" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$ROOT_DIR/build/ModuleCache" \
  -target arm64-apple-macos15.0 -F "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64" \
  -framework Sparkle -framework AppKit -framework CoreAudio -framework CoreLocation -framework EventKit \
  -framework IOKit -framework Quartz -framework ServiceManagement "${sources[@]}"
