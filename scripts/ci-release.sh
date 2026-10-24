#!/bin/bash
# Only for GitHub's disposable macOS runners. Never run this against your login keychain.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS ]] || { echo 'This helper is for disposable GitHub macOS runners only' >&2; exit 1; }
: "${SIGNING_P12_BASE64:?Missing certificate secret}"
: "${SIGNING_P12_PASSWORD:?Missing certificate password secret}"
: "${SPARKLE_ED_PRIVATE_KEY:?Missing Sparkle private key secret}"
: "${RUNNER_TEMP:?Missing runner temp directory}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "$RUNNER_TEMP/notch-release.XXXXXX")"
KEYCHAIN="$WORK_DIR/release.keychain-db"
CERT="$WORK_DIR/signer.crt"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
printf '::add-mask::%s\n' "$KEYCHAIN_PASSWORD"
OLD_KEYCHAINS=()
while IFS= read -r line; do OLD_KEYCHAINS+=("$(printf '%s' "$line" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')"); done < <(security list-keychains -d user)
cleanup() {
  security remove-trusted-cert "$CERT" >/dev/null 2>&1 || true
  security list-keychains -d user -s "${OLD_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT
umask 077
printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$WORK_DIR/signer.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK_DIR/signer.p12" -k "$KEYCHAIN" -P "$SIGNING_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# A self-signed certificate must be trusted for code signing on the signing machine only.
# Scope the trust to codeSign and remove it in cleanup. Never ask recipients to trust it.
security find-certificate -a -p "$KEYCHAIN" > "$CERT"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"
security list-keychains -d user -s "$KEYCHAIN" "${OLD_KEYCHAINS[@]}"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
SIGNING_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*\([A-F0-9]\{40\}\).*/\1/p' | head -1)"
[[ -n "$SIGNING_IDENTITY" ]] || { echo 'Imported certificate is not a valid Code Signing identity' >&2; exit 1; }
export SIGNING_IDENTITY
VERSION="${GITHUB_REF_NAME#v}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/Resources/Info.plist")"
"$ROOT_DIR/scripts/release.sh" "$VERSION" "$BUILD"
