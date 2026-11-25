#!/bin/bash
# Build, bundle and launch Companion.app
# Usage: bash build.sh [build|app|run|dmg|check|clean]   (default: run)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=Companion
BUNDLE_DIR="dist/$APP_NAME.app"

# What the app carries so it runs on its own, with nothing to install on
# the Mac that runs it: Chromium (CEF) for the browser, the way Arc is
# built, and a Python with apwlib for iCloud Passwords, with a Chromium to
# host Apple's extension (COMPANION_NO_PASSWORDS_HOST=1 leaves it out), and
# code-server, VS Code's core, for code mode (COMPANION_NO_CODE_SERVER=1). All are fetched
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
  if [[ "${COMPANION_NO_CODE_SERVER:-0}" != "1" ]]; then
    bash scripts/fetch-code-server.sh || echo "WARNING: VS Code (code-server) was not fetched; code mode uses Companion's own editor."
  fi
  if [[ "${COMPANION_NO_PASSWORDS_HOST:-0}" != "1" ]]; then
    bash scripts/fetch-passwords-host.sh || echo "WARNING: Chromium for iCloud Passwords was not fetched; it will need Chrome, Brave or Edge."
  fi
  if [[ -f "$CEF_DIR/build/libcef_dll_wrapper.a" && -d "$CEF_FRAMEWORK" ]]; then
    cp "$CEF_DIR/build/libcef_dll_wrapper.a" "$CEF_LIB"
  else
    cef_stub
  fi
}

# An empty library in place of CEF's wrapper, so linking works without CEF.
cef_stub() {
  mkdir -p .build/cef
  echo "" | clang -c -x c - -o .build/cef/empty.o
  libtool -static -o "$CEF_LIB" .build/cef/empty.o 2>/dev/null
}

# The Metal compiler, for SwiftTerm's shader, is not inside Xcode. It is a
# component Xcode downloads, and macOS mounts it under /var/run at a path
# that is new each time it is mounted. After a restart, or when the
# component is updated, it can be left unmounted, or mounted at a new path
# while the plan the last build saved still names the old one: a saved plan
# is used again as long as the project and Xcode are the same, wherever the
# component is. Either way Shaders.metal fails with "unable to spawn
# process .../metal (No such file or directory)". So before building, have
# Xcode mount the component when Xcode says it is missing, and drop a saved
# plan that names a mount which is gone. What was compiled stays, so the
# build that follows is still an incremental one.
metal_toolchain() {
  local said
  if ! said=$(xcrun --sdk macosx metal --version 2>&1) \
      && [[ "$said" == *downloadComponent* || "$said" == *"Metal Toolchain"* ]]; then
    echo "The Metal Toolchain is not mounted. Asking Xcode for it: xcodebuild -downloadComponent MetalToolchain"
    echo "If nothing moves for a few minutes, press Ctrl-C, install it from Xcode > Settings > Components"
    echo "(or restart the Mac) and build again."
    xcodebuild -downloadComponent MetalToolchain || true
    if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
      echo "WARNING: the Metal compiler still does not run, so SwiftTerm's shader will not build."
    fi
  fi
  local plan mount gone dropped=""
  for plan in .build/out/Intermediates.noindex/XCBuildData/*.xcbuilddata; do
    [[ -f "$plan/manifest.json" ]] || continue
    gone=""
    # The manifest is one long line: cut it at the quotes, so that every
    # path is on a line of its own.
    for mount in $(LC_ALL=C tr '"' '\n' < "$plan/manifest.json" \
        | LC_ALL=C grep -oE '/[A-Za-z0-9._/-]*com\.apple\.MobileAsset\.MetalToolchain-[A-Za-z0-9._-]+' \
        | sort -u || true); do
      [[ -d "$mount" ]] || gone="$mount"
    done
    if [[ -n "$gone" ]]; then
      rm -rf "$plan"
      dropped="$gone"
    fi
  done
  if [[ -n "$dropped" ]]; then
    echo "The saved build plan named a Metal Toolchain mount that is gone ($(basename "$dropped")); working the plan out again."
  fi
}

build() {
  chromium
  metal_toolchain
  # Run through xcrun with the macOS SDK: SwiftTerm has a Metal shader, and
  # the metal compiler only finds the downloaded Metal Toolchain when it is
  # started with an SDK set. A plain `swift build` fails on Shaders.metal.
  xcrun --sdk macosx swift build -c release
}

# Does it compile: a debug build with nothing fetched, quicker than a
# release build, for the checks a task's work goes through before its
# review (.companion/checks.json at the top of the repository). CEF's
# wrapper is used when an earlier build left it, and the empty one stands
# in for it otherwise.
check() {
  [[ -f "$CEF_LIB" ]] || cef_stub
  metal_toolchain
  xcrun --sdk macosx swift build
}

# Sign with a stable identity so macOS permission grants (screen recording,
# accessibility) survive rebuilds. Ad-hoc signing (-) gives the app a new
# identity every build, so macOS asks again and the old grant is left behind
# as a second Companion in System Settings.
#
# The kinds of identity that are used, best first. COMPANION_SIGN_ID names
# one outright, for a keychain that holds several.
SIGN_KINDS=("Apple Development" "Developer ID Application" "Companion Dev")
# Mac passkeys in Companion's browser need the browser entitlement, and only
# a provisioning profile from Apple grants it. Signing with the entitlement
# and no profile stops the app from opening, so both have to be present.
BROWSER_ENTITLEMENTS=Resources/Browser.entitlements
PROFILE=Resources/embedded.provisionprofile

signing_identity() {
  if [[ -n "${COMPANION_SIGN_ID:-}" ]]; then
    echo "$COMPANION_SIGN_ID"
    return 0
  fi
  local names kind found
  names=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NF >= 3 {print $2}')
  [[ -n "$names" ]] || return 0
  for kind in "${SIGN_KINDS[@]}"; do
    found=$(printf '%s\n' "$names" | grep -m1 -F "$kind" || true)
    if [[ -n "$found" ]]; then
      echo "$found"
      return 0
    fi
  done
  return 0
}

# A library or a loose binary: entitlements belong to a bundle, not to these.
# No secure timestamp anywhere: it needs the network, and only distribution
# (notarization) asks for one.
sign_file() {
  codesign --force --timestamp=none --sign "$1" "$2"
}

# A nested bundle: Chromium's helper apps. The browser entitlement belongs
# to the app that asks for it, not to these.
sign_bundle() {
  codesign --force --timestamp=none --sign "$1" "$2"
}

# The app itself, last, with the browser entitlement when a profile grants it.
sign_app() {
  if [[ "$1" != "-" && -f "$PROFILE" && -f "$BROWSER_ENTITLEMENTS" ]]; then
    cp "$PROFILE" "$BUNDLE_DIR/Contents/embedded.provisionprofile"
    echo "Signing with Mac passkeys"
    codesign --force --timestamp=none --sign "$1" --entitlements "$BROWSER_ENTITLEMENTS" "$BUNDLE_DIR"
  else
    codesign --force --timestamp=none --sign "$1" "$BUNDLE_DIR"
  fi
}

sign() {
  local identity
  identity=$(signing_identity)
  if [[ -n "$identity" ]]; then
    echo "Signing as: $identity"
  else
    echo "WARNING: no code signing identity found; signing ad-hoc."
    echo "macOS will re-ask permissions after every rebuild. To fix, either:"
    echo "  - sign into Xcode (Settings > Accounts) to get an Apple Development identity, or"
    echo "  - Keychain Access > Certificate Assistant > Create a Certificate,"
    echo "    name 'Companion Dev', type 'Code Signing', then rebuild, or"
    echo "  - set COMPANION_SIGN_ID to an identity name."
    identity=-
  fi
  # Inside out: everything nested is signed before the bundle around it is
  # sealed, or the seal names files that change under it afterwards and the
  # signature is broken.
  local inner folder
  for folder in Python CodeServer; do
    [[ -d "$BUNDLE_DIR/Contents/Resources/$folder" ]] || continue
    find "$BUNDLE_DIR/Contents/Resources/$folder" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.node' -o -perm -u+x \) -print0 |
      while IFS= read -r -d '' inner; do
        file -b "$inner" | grep -q Mach-O && sign_file "$identity" "$inner" 2>/dev/null || true
      done
  done
  local framework="$BUNDLE_DIR/Contents/Frameworks/Chromium Embedded Framework.framework"
  if [[ -d "$framework" ]]; then
    # Chromium's own libraries (its GL and Vulkan loaders) sit beside the
    # framework's binary, and are signed before the framework is.
    if [[ -d "$framework/Libraries" ]]; then
      find "$framework/Libraries" -type f -name '*.dylib' -print0 |
        while IFS= read -r -d '' inner; do
          sign_file "$identity" "$inner"
        done
    fi
    sign_file "$identity" "$framework"
  fi
  for inner in "$BUNDLE_DIR/Contents/Frameworks/"*; do
    # The framework is signed above, before its own libraries' turn.
    [[ -e "$inner" && "$inner" != "$framework" ]] || continue
    if [[ "$inner" == *.app ]]; then
      sign_bundle "$identity" "$inner"
    else
      sign_file "$identity" "$inner"
    fi
  done
  # The Chromium for iCloud Passwords in Contents/Helpers keeps the
  # signature it came with: it is signed by another team with library
  # validation, and re-signing it here would stop macOS's iCloud Passwords
  # helper from trusting it. The verify below proves its seal is whole.
  sign_app "$identity"
  # A broken signature shows itself only when macOS refuses to start the
  # app, so the build checks it here instead.
  codesign --verify --deep --strict "$BUNDLE_DIR"
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
  # Companion's extension for VS Code (code mode): the agent's terminals
  # and the review of its changes, inside VS Code.
  cp -R Resources/VSCodeExtension "$BUNDLE_DIR/Contents/Resources/"
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
  # iCloud Passwords' Python, the module that points it at the Chromium
  # inside, and that Chromium, which hosts Apple's extension headless.
  cp Resources/Python/companion_host.py "$BUNDLE_DIR/Contents/Resources/"
  if [[ -x Vendor/python/bin/python3 ]]; then
    cp -R Vendor/python "$BUNDLE_DIR/Contents/Resources/Python"
  fi
  # VS Code's core for code mode, with its own Node.
  if [[ -x Vendor/code-server/bin/code-server ]]; then
    cp -R Vendor/code-server "$BUNDLE_DIR/Contents/Resources/CodeServer"
  fi
  if [[ -d Vendor/passwords-host/Chromium.app ]]; then
    mkdir -p "$BUNDLE_DIR/Contents/Helpers"
    cp -R Vendor/passwords-host/Chromium.app "$BUNDLE_DIR/Contents/Helpers/"
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

# Rebuild and restart a running Companion from inside itself (its agent's
# shell). The restart runs in its own session so it outlives the app it
# quits, and it opens this build by path: "open -a Companion" can pick
# another copy with the same bundle ID (an archived one).
restart() {
  local bundle
  bundle="$(cd "$BUNDLE_DIR" && pwd)"
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/sh -c "
    osascript -e 'quit app id \"com.harshsah.companion\"' >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f '$bundle/Contents/MacOS/$APP_NAME' >/dev/null || break; sleep 1; done
    open -n '$bundle'
  " </dev/null >/dev/null 2>&1 &
  echo "Restarting $bundle"
}

case "${1:-run}" in
  build) build ;;
  restart) build; bundle; restart ;;
  app)   build; bundle ;;
  run)   build; bundle; open "$BUNDLE_DIR" ;;
  dmg)   build; bundle; dmg ;;
  check) check ;;
  clean) rm -rf .build dist ;;
  *) echo "usage: bash build.sh [build|app|run|restart|dmg|check|clean]"; exit 1 ;;
esac
