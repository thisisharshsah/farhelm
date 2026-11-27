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

# Sign with a stable identity so macOS permission grants (mic, screen
# recording) survive rebuilds. Ad-hoc signing (-) changes the app's identity
# every build, which makes TCC re-ask each time.
sign() {
  local identity
  if [[ -n "${COMPANION_SIGN_ID:-}" ]]; then
    identity="$COMPANION_SIGN_ID"
  else
    # Check for Apple Development identity first
    identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
    if [[ -z "$identity" ]]; then
      # Fall back to any available identity (Developer ID Application or Companion Dev)
      identity=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Companion Dev/ {print $2; exit}')
    fi
  fi

  # What is inside is signed first (Python's binaries, Chromium's
  # framework and helpers), then the app around it.
  local inner folder
  for folder in Python CodeServer; do
    [[ -d "$BUNDLE_DIR/Contents/Resources/$folder" ]] || continue
    find "$BUNDLE_DIR/Contents/Resources/$folder" -type f \( -name '*.so' -o -name '*.dylib' -o -name '*.node' -o -perm -u+x \) -print0 |
      while IFS= read -r -d '' inner; do
        file -b "$inner" | grep -q Mach-O && codesign --force --sign "${identity:--}" "$inner" 2>/dev/null || true
      done
  done
  # The Chromium for iCloud Passwords keeps its own signature: macOS's
  # iCloud Passwords helper decides by it.
  for inner in "$BUNDLE_DIR/Contents/Frameworks/"*; do
    [[ -e "$inner" ]] || continue
    codesign --force --sign "${identity:--}" "$inner"
  done
  # Mac passkeys in Companion's browser: only with a provisioning profile
  # from Apple that grants the browser passkey entitlement, placed at
  # Resources/embedded.provisionprofile. Without one, signing with that
  # entitlement would stop the app from opening, so it is left out.
  local profile="Resources/embedded.provisionprofile"
  if [[ -n "$identity" && -f "$profile" ]]; then
    cp "$profile" "$BUNDLE_DIR/Contents/embedded.provisionprofile"
    echo "Signing as: $identity (with Mac passkeys)"
    codesign --force --entitlements Resources/Browser.entitlements --sign "$identity" "$BUNDLE_DIR"
  elif [[ -n "$identity" ]]; then
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

# A Companion still running from this dist/ keeps the old build (and its
# Chromium windows) on screen, and replacing its files under it breaks its
# signature. It is asked to quit first, then stopped if it has not.
#
# Only the Companion started from this folder's dist/ is touched. A board
# task builds in a copy of the repository of its own, and a build there
# used to quit whichever Companion was running, by name: the person's app
# went away under them with no crash report (2026-11-25, twice, from a
# task's "build.sh app"). A Companion from another folder is left alone:
# its files are not the ones replaced here.
own_app() {
  local binary
  binary="$(pwd -P)/$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
  ps -axo pid=,command= | awk -v binary="$binary" '
    { pid = $1; $1 = ""; sub(/^ +/, "") }
    $0 == binary || index($0, binary " ") == 1 { print pid }'
}

# Every running Companion, whichever folder it was started from. Read from
# ps, not pgrep: pgrep leaves out its own ancestors, and a build started
# from Companion's agent shell has the app as one, so pgrep would say no
# Companion is running while the person's is.
any_app() {
  ps -axo pid=,command= | awk -v name="/Contents/MacOS/$APP_NAME" '
    { pid = $1; $1 = ""; sub(/^ +/, "") }
    length($0) >= length(name) && substr($0, length($0) - length(name) + 1) == name { print pid }'
}

quit_running() {
  local mine others
  mine="$(own_app)"
  [[ -n "$mine" ]] || return 0
  echo "Quitting the ${APP_NAME} running from this build…"
  others="$(any_app | grep -v -x -F "$mine" || true)"
  if [[ -z "$others" ]]; then
    # Asked by name, the app saves and closes as it does for Cmd+Q. With
    # another Companion running too the name could reach that one, so
    # then this build is only signalled.
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  else
    kill $mine 2>/dev/null || true
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -n "$(own_app)" ]] || return 0
    sleep 0.5
  done
  mine="$(own_app)"
  [[ -z "$mine" ]] || kill $mine 2>/dev/null || true
  sleep 0.5
}

# Is this folder a copy of the repository made for a board task (a linked
# git worktree), not the person's own checkout?
in_task_copy() {
  local dir common
  dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  common="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
  [[ "$dir" != "$common" ]]
}

bundle() {
  # Put together beside the running app (STAGED), nothing is quit here.
  [[ -n "${STAGED:-}" ]] || quit_running
  rm -rf "$(dirname "$BUNDLE_DIR")"
  mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
  cp ".build/release/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/"
  cp Resources/Info.plist "$BUNDLE_DIR/Contents/"
  # A board task's copy builds an app of its own name to the system: with
  # the same identifier as the person's Companion, opening Companion (from
  # the Dock, Spotlight or by its id) could start a task's unreviewed build
  # in place of the real one, and did.
  if in_task_copy; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.harshsah.companion.taskcopy" \
      "$BUNDLE_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
  fi
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
    # Quitting can take a while (chats saved, runs stopped). Opening the
    # new build while the old one is still on its way out left neither
    # running, so this waits it out, and looks once more that the new one
    # really came up.
    i=0
    while [ \$i -lt 120 ] && ps -axo command= | grep -q '/Contents/MacOS/$APP_NAME\$'; do sleep 1; i=\$((i+1)); done
    open -n '$bundle'
    # With board runs going the old one can outlast the wait, and the new
    # one then leaves again as a second copy: looked at a few more times.
    for n in 1 2 3; do
      sleep 10
      ps -axo command= | grep -q '/Contents/MacOS/$APP_NAME\$' || open -n '$bundle'
    done
  " </dev/null >/dev/null 2>&1 &
  echo "Restarting $bundle"
}

# Restarting replaces the Companion the person is using with this build.
# From a task's copy that is never wanted by accident: the app would be
# swapped for unreviewed work in the middle of whatever it was doing.
restart_allowed() {
  if in_task_copy && [[ "${COMPANION_RESTART_FROM_COPY:-0}" != "1" ]]; then
    echo "This folder is a board task's copy of the repository, so its build does not replace the running ${APP_NAME}."
    echo "Use \"bash build.sh app\" to build here, or restart from the project's own folder."
    echo "(COMPANION_RESTART_FROM_COPY=1 restarts from here anyway.)"
    return 1
  fi
}

case "${1:-run}" in
  build) build ;;
  restart)
    restart_allowed || exit 1
    # From inside the app the whole of it runs apart, and this returns at
    # once: a build of many files takes longer than the two minutes the
    # agent's shell gives a command, and was cut off half way. The app it
    # was started from stays up until the new one takes its place, so
    # running apart is enough here (see below for after it quits).
    if [[ ! -t 0 && "${COMPANION_RESTART_JOB:-}" != "1" ]]; then
      mkdir -p .build
      COMPANION_RESTART_JOB=1 /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$PWD/build.sh" restart \
        </dev/null >.build/restart.log 2>&1 &
      echo "Building apart now; $APP_NAME restarts by itself when it is built (log: apple/.build/restart.log)."
      exit 0
    fi
    build
    # Started from a chat inside the app that is being replaced (no
    # terminal behind it), this script cannot outlive that app: macOS ends
    # everything the app started soon after it quits, whatever session or
    # launchd job it was moved to (tried, three times). So nothing is left
    # to do after the old app goes. The new bundle is put together beside
    # the running one, swapped in, and started while the old one still
    # runs; told which one it replaces, the new app asks that one to quit
    # and waits for it before it starts up (`Launch.replaceRunning`).
    if [[ ! -t 0 ]]; then
      old="$(own_app | head -1)"
      rm -rf .build/stage .build/stage-old
      BUNDLE_DIR=".build/stage/$APP_NAME.app"
      STAGED=1
      bundle
      STAGED=""
      BUNDLE_DIR="dist/$APP_NAME.app"
      if [[ -d dist ]]; then mv dist .build/stage-old; fi
      mv .build/stage dist
      if [[ -n "$old" ]]; then
        open -n --env "COMPANION_REPLACE=$old" "$PWD/$BUNDLE_DIR"
      else
        open -n "$PWD/$BUNDLE_DIR"
      fi
      echo "Built. The new $APP_NAME is starting and takes the old one's place."
      exit 0
    fi
    # From a terminal, everything after the build runs apart, in a
    # session of its own: the bundle quits the app, and that works there.
    /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' /bin/bash "$PWD/build.sh" finish-restart \
      </dev/null >.build/restart.log 2>&1 &
    echo "Built. Bundling and restarting on its own now (log: apple/.build/restart.log)."
    ;;
  finish-restart) bundle; restart ;;
  app)   build; bundle ;;
  run)   build; bundle; open "$BUNDLE_DIR" ;;
  dmg)   build; bundle; dmg ;;
  check) check ;;
  clean) rm -rf .build dist ;;
  *) echo "usage: bash build.sh [build|app|run|restart|dmg|check|clean]"; exit 1 ;;
esac
