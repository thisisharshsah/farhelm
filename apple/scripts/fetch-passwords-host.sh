#!/bin/bash
# Fetches the browser that hosts Apple's iCloud Passwords extension inside
# Companion, so iCloud Passwords needs no Chrome on the Mac: ungoogled-
# chromium (open source, BSD-licensed Chromium without Google's services),
# the Chromium build apwlib names for this. macOS's iCloud Passwords helper
# answers only certain browsers; whether it answers this copy, inside
# Companion.app, is what the first build with it shows. It runs headless,
# never on screen. Lands in Vendor/passwords-host (ignored by git); nothing
# is fetched when it is current. The project publishes no checksums: the
# download is trusted to GitHub's release over HTTPS, and its signature is
# checked as macOS would before it is kept.
#
# Usage: bash scripts/fetch-passwords-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=Vendor/passwords-host
STAMP=Vendor/passwords-host-version
API=https://api.github.com/repos/ungoogled-software/ungoogled-chromium-macos/releases/latest

case "$(uname -m)" in
  arm64) ARCH=arm64 ;;
  x86_64) ARCH=x86 ;;
  *) echo "fetch-passwords-host: unsupported architecture $(uname -m)"; exit 1 ;;
esac

TMP="$(mktemp -d)"
cleanup() {
  [[ -d "$TMP/mnt" ]] && hdiutil detach -quiet "$TMP/mnt" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

curl -fsSL "$API" -o "$TMP/release.json"
read -r TAG URL < <(python3 - "$TMP/release.json" "$ARCH" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
arch = sys.argv[2]
urls = [a["browser_download_url"] for a in release.get("assets", [])
        if a["name"].endswith(".dmg") and arch in a["name"]]
if not urls:
    sys.exit("no macOS build for this Mac in the latest release")
print(release["tag_name"], urls[0])
PY
)

if [[ -d "$DEST/Chromium.app" && "$(cat "$STAMP" 2>/dev/null)" == "$TAG" ]]; then
  echo "fetch-passwords-host: Chromium $TAG is already here."
  exit 0
fi

echo "fetch-passwords-host: downloading Chromium ${TAG}…"
curl -fL --progress-bar "$URL" -o "$TMP/chromium.dmg"
mkdir -p "$TMP/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$TMP/mnt" "$TMP/chromium.dmg"
APP="$(find "$TMP/mnt" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$APP" ]]; then
  echo "fetch-passwords-host: no app in the disk image."
  exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"
ditto "$APP" "$DEST/Chromium.app"
hdiutil detach -quiet "$TMP/mnt"
xattr -cr "$DEST/Chromium.app"
if ! codesign --verify --deep "$DEST/Chromium.app" 2>/dev/null; then
  echo "fetch-passwords-host: its signature does not hold; not using it."
  rm -rf "$DEST"
  exit 1
fi
echo "$TAG" > "$STAMP"
echo "fetch-passwords-host: ready in $DEST."
