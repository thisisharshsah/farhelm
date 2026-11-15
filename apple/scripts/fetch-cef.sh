#!/bin/bash
# Fetches Chromium (CEF, the Chromium Embedded Framework) for Companion's
# browser: the newest stable "minimal" build for this Mac's architecture,
# checked against the SHA-1 the CEF build index publishes, then compiles
# CEF's C++ wrapper library once with Xcode's own clang (no cmake or other
# tools to install). Everything lands in Vendor/cef (ignored by git); the
# app built from it carries Chromium inside, so nothing is installed on the
# Mac that runs it. Run again to update; nothing is fetched when current.
#
# Usage: bash scripts/fetch-cef.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
VENDOR="$ROOT/Vendor"
DEST="$VENDOR/cef"
# Kept beside, not inside: a file named VERSION in an include folder
# shadows C++'s <version> header on a case-insensitive disk.
STAMP="$VENDOR/cef-version"
INDEX_URL="https://cef-builds.spotifycdn.com/index.json"
CDN="https://cef-builds.spotifycdn.com"

case "$(uname -m)" in
  arm64) PLATFORM=macosarm64 ;;
  x86_64) PLATFORM=macosx64 ;;
  *) echo "fetch-cef: unsupported architecture $(uname -m)"; exit 1 ;;
esac

mkdir -p "$VENDOR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetch-cef: reading the CEF build index…"
curl -fsSL "$INDEX_URL" -o "$TMP/index.json"

# The newest stable minimal distribution for this platform.
read -r NAME SHA VERSION < <(python3 - "$TMP/index.json" "$PLATFORM" <<'PY'
import json, sys
index = json.load(open(sys.argv[1]))
for build in index[sys.argv[2]]["versions"]:
    if build.get("channel") != "stable":
        continue
    for f in build["files"]:
        if f.get("type") == "minimal":
            print(f["name"], f["sha1"], build["cef_version"])
            sys.exit(0)
sys.exit("no stable minimal build found")
PY
)

LIB="$DEST/build/libcef_dll_wrapper.a"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -f "$LIB" ]]; then
  echo "fetch-cef: CEF $VERSION is already here."
  exit 0
fi

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -d "$DEST/libcef_dll" ]]; then
  echo "fetch-cef: CEF $VERSION is here; its wrapper library is not built yet."
else
  echo "fetch-cef: downloading CEF $VERSION ($NAME)…"
  curl -fL --progress-bar "$CDN/$NAME" -o "$TMP/$NAME"
  GOT="$(shasum -a 1 "$TMP/$NAME" | awk '{print $1}')"
  if [[ "$GOT" != "$SHA" ]]; then
    echo "fetch-cef: checksum mismatch (expected $SHA, got $GOT); not using it."
    exit 1
  fi

  echo "fetch-cef: unpacking…"
  tar -xjf "$TMP/$NAME" -C "$TMP"
  UNPACKED="$(find "$TMP" -maxdepth 1 -type d -name 'cef_binary_*' | head -1)"
  rm -rf "$DEST"
  mv "$UNPACKED" "$DEST"
  echo "$VERSION" > "$STAMP"
fi

echo "fetch-cef: compiling the C++ wrapper library…"
ARCH=arm64; [[ "$PLATFORM" == macosx64 ]] && ARCH=x86_64
OBJ="$DEST/build/obj"
mkdir -p "$OBJ"
# CEF's own flags for the wrapper on macOS (cmake/cef_variables.cmake).
FLAGS=(-arch "$ARCH" -mmacosx-version-min=14.0 -O3 -std=c++20
       -fno-exceptions -fno-rtti -fno-threadsafe-statics -fobjc-call-cxx-cdtors
       -fno-strict-aliasing -fstack-protector -funwind-tables
       -fvisibility=hidden -fvisibility-inlines-hidden -Wno-narrowing -Wno-undefined-var-template
       -DNDEBUG -DWRAPPING_CEF_SHARED -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS
       -I "$DEST")
export ARCH OBJ DEST
printf '%s\0' "${FLAGS[@]}" > "$OBJ/flags"
# Every wrapper source but Windows' and Linux's, in parallel.
find "$DEST/libcef_dll" \( -name '*.cc' -o -name '*.mm' \) ! -name '*_win.cc' ! -name '*_linux.cc' -print0 |
  xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} bash -c '
    src="$1"; out="$OBJ/$(echo "${src#$DEST/}" | tr "/" "_").o"
    xargs -0 xcrun clang++ -c "$src" -o "$out" < "$OBJ/flags" || { echo "fetch-cef: failed on $src"; exit 255; }
  ' _ {}
rm -f "$LIB"
xcrun libtool -static -o "$LIB" "$OBJ"/*.o
rm -rf "$OBJ"

echo "fetch-cef: CEF $VERSION is ready in Vendor/cef."
