#!/bin/bash
# Build, bundle and launch Companion.app
# Usage: bash build.sh [build|app|run|clean]   (default: run)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Companion
BUNDLE_DIR="dist/$APP_NAME.app"

build() {
  swift build -c release
}

# Sign with a stable identity so macOS permission grants (mic, screen
# recording) survive rebuilds. Ad-hoc signing (-) changes the app's identity
# every build, which makes TCC re-ask each time.
sign() {
  local identity="${COMPANION_SIGN_ID:-}"
  if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
      | awk -F'"' '/Companion Dev|Apple Development|Developer ID Application/ {print $2; exit}')
  fi
  if [[ -n "$identity" ]]; then
    echo "Signing as: $identity"
    codesign --force --sign "$identity" "$BUNDLE_DIR"
  else
    echo "WARNING: no code signing identity found; signing ad-hoc."
    echo "macOS will re-ask permissions after every rebuild. To fix, either:"
    echo "  - sign into Xcode (Settings > Accounts) to get an Apple Development identity, or"
    echo "  - Keychain Access > Certificate Assistant > Create a Certificate,"
    echo "    name 'Companion Dev', type 'Code Signing', then rebuild, or"
    echo "  - set COMPANION_SIGN_ID to an identity name."
    codesign --force --sign - "$BUNDLE_DIR"
  fi
}

bundle() {
  rm -rf dist
  mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
  cp ".build/release/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
  cp Resources/Info.plist "$BUNDLE_DIR/Contents/"
  sign
  echo "Built $BUNDLE_DIR"
}

case "${1:-run}" in
  build) build ;;
  app)   build; bundle ;;
  run)   build; bundle; open "$BUNDLE_DIR" ;;
  clean) rm -rf .build dist ;;
  *) echo "usage: bash build.sh [build|app|run|clean]"; exit 1 ;;
esac
