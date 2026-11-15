#!/bin/bash
# Build, bundle and launch Companion.app
# Usage: bash build.sh [build|app|run|dmg|clean]   (default: run)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Companion
BUNDLE_DIR="dist/$APP_NAME.app"

# What the app carries so it runs on its own, with nothing to install on
# the Mac that runs it: Chromium (CEF) for the browser, the way Arc is
# built, and a Python with apwlib for iCloud Passwords. Both are fetched
# once into Vendor/ with only what macOS and Xcode already have.
# COMPANION_NO_CHROMIUM=1 builds without Chromium (the browser is WebKit).
# Either way a wrapper library is left in .build/cef for the package to
# link (an empty one without CEF).
CEF_DIR=Vendor/cef
CEF_LIB=.build/cef/libcef_dll_wrapper.a
CEF_FRAMEWORK="$CEF_DIR/Release/Chromium Embedded Framework.framework"
HELPER_NAME="$APP_NAME Helper"

chromium() {
  mkdir -p .build/cef
  if [[ "${COMPANION_NO_CHROMIUM:-0}" != "1" ]]; then
    bash scripts/fetch-cef.sh || echo "WARNING: Chromium was not fetched; building with WebKit only."
  fi
  bash scripts/fetch-python.sh || echo "WARNING: Python for iCloud Passwords was not fetched; it will be set up on first use instead."
  if [[ -f "$CEF_DIR/build/libcef_dll_wrapper.a" && -d "$CEF_FRAMEWORK" ]]; then
    cp "$CEF_DIR/build/libcef_dll_wrapper.a" "$CEF_LIB"
  else
    # An empty library, so linking works without CEF.
    echo "" | clang -c -x c - -o .build/cef/empty.o
    libtool -static -o "$CEF_LIB" .build/cef/empty.o 2>/dev/null
  fi
}

build() {
  chromium
  # Run through xcrun with the macOS SDK: SwiftTerm has a Metal shader, and
  # the metal compiler only finds the downloaded Metal Toolchain when it is
  # started with an SDK set. A plain `swift build` fails on Shaders.metal.
  xcrun --sdk macosx swift build -c release
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
  # What is inside is signed first (Python's binaries, Chromium's
  # framework and helpers), then the app around it.
  local inner
  if [[ -d "$BUNDLE_DIR/Contents/Resources/Python" ]]; then
    find "$BUNDLE_DIR/Contents/Resources/Python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
      while IFS= read -r -d '' inner; do
        file -b "$inner" | grep -q Mach-O && codesign --force --sign "${identity:--}" "$inner" 2>/dev/null || true
      done
  fi
  for inner in "$BUNDLE_DIR/Contents/Frameworks/"*; do
    [[ -e "$inner" ]] || continue
    codesign --force --sign "${identity:--}" "$inner"
  done
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

# A Companion still running from dist/ keeps the old build (and its
# Chromium windows) on screen, and replacing its files under it breaks its
# signature. It is asked to quit first, then stopped if it has not.
quit_running() {
  pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
  echo "Quitting the running ${APP_NAME}…"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
}

bundle() {
  quit_running
  rm -rf dist
  mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
  cp ".build/release/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
  cp Resources/Info.plist "$BUNDLE_DIR/Contents/"
  cp Resources/AppIcon.icns "$BUNDLE_DIR/Contents/Resources/"
  # The engines' logos, one SVG each, named after the engine or tool.
  cp -R Resources/Engines "$BUNDLE_DIR/Contents/Resources/"
  # Companion's Chrome extension, copied out by Settings > Agent > Your Chrome.
  cp -R Resources/ChromeExtension "$BUNDLE_DIR/Contents/Resources/"
  # File and folder icons (Material Icon Theme, MIT), kept as one archive
  # in the repository and unpacked into the app.
  if [[ -f Resources/FileIcons.tar.gz ]]; then
    tar -xzf Resources/FileIcons.tar.gz -C "$BUNDLE_DIR/Contents/Resources/"
  fi
  # SwiftPM resource bundles, such as SwiftTerm's compiled Metal shaders
  # (SwiftTerm_SwiftTerm.bundle). The packages look for them in
  # Contents/Resources, so the terminal's renderer needs this in the app.
  for b in .build/release/*.bundle; do
    cp -R "$b" "$BUNDLE_DIR/Contents/Resources/"
  done
  bundle_chromium
  # iCloud Passwords' Python, and the module that lets it use Arc.
  cp Resources/Python/companion_arc.py "$BUNDLE_DIR/Contents/Resources/"
  if [[ -x Vendor/python/bin/python3 ]]; then
    cp -R Vendor/python "$BUNDLE_DIR/Contents/Resources/Python"
  fi
  sign
  echo "Built $BUNDLE_DIR"
}

# Chromium's framework and its helper apps (one executable, under the
# names Chromium looks for) in Contents/Frameworks.
bundle_chromium() {
  [[ -d "$CEF_FRAMEWORK" ]] || return 0
  local frameworks="$BUNDLE_DIR/Contents/Frameworks"
  mkdir -p "$frameworks"
  cp -R "$CEF_FRAMEWORK" "$frameworks/"
  local suffix id name plist
  for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
    name="$HELPER_NAME$suffix"
    id=$(echo "$suffix" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
    mkdir -p "$frameworks/$name.app/Contents/MacOS"
    cp ".build/release/CompanionHelper" "$frameworks/$name.app/Contents/MacOS/$name"
    plist="$frameworks/$name.app/Contents/Info.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.harshsah.companion.helper${id:+.$id}</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
  done
  echo "Bundled Chromium $(cat Vendor/cef-version 2>/dev/null)"
}

# A disk image to hand to anyone: drag Companion to Applications and it
# runs, with Chromium and iCloud Passwords' Python inside.
dmg() {
  local image="dist/$APP_NAME.dmg"
  rm -f "$image"
  hdiutil create -volname "$APP_NAME" -srcfolder "$BUNDLE_DIR" -ov -format UDZO "$image" >/dev/null
  echo "Built $image"
}

case "${1:-run}" in
  build) build ;;
  app)   build; bundle ;;
  run)   build; bundle; open "$BUNDLE_DIR" ;;
  dmg)   build; bundle; dmg ;;
  clean) rm -rf .build dist ;;
  *) echo "usage: bash build.sh [build|app|run|dmg|clean]"; exit 1 ;;
esac
