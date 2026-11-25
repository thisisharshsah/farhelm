#!/bin/bash
# Fetches the code editor Companion's code mode runs: code-server (MIT),
# VS Code's open-source core as a local server, with its own Node inside.
# Companion shows it in its Chromium pane, so VS Code's extensions work as
# they do in VS Code, installed from Open VSX (Microsoft's marketplace is
# for Microsoft's products only). The newest release for this Mac's
# architecture lands in Vendor/code-server (ignored by git); nothing is
# fetched when it is current. The project publishes no checksums: the
# download is trusted to GitHub's release over HTTPS.
#
# Usage: bash scripts/fetch-code-server.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=Vendor/code-server
STAMP=Vendor/code-server-version
API=https://api.github.com/repos/coder/code-server/releases/latest

case "$(uname -m)" in
  arm64) ARCH=macos-arm64 ;;
  x86_64) ARCH=macos-amd64 ;;
  *) echo "fetch-code-server: unsupported architecture $(uname -m)"; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$API" -o "$TMP/release.json"
read -r TAG URL < <(python3 - "$TMP/release.json" "$ARCH" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
urls = [a["browser_download_url"] for a in release.get("assets", [])
        if a["name"].endswith(f"-{sys.argv[2]}.tar.gz")]
if not urls:
    sys.exit("no macOS build for this Mac in the latest release")
print(release["tag_name"], urls[0])
PY
)

if [[ -x "$DEST/bin/code-server" && "$(cat "$STAMP" 2>/dev/null)" == "$TAG" ]]; then
  echo "fetch-code-server: code-server $TAG is already here."
  exit 0
fi

echo "fetch-code-server: downloading code-server ${TAG}…"
curl -fL --progress-bar "$URL" -o "$TMP/code-server.tar.gz"
tar -xzf "$TMP/code-server.tar.gz" -C "$TMP"
FOLDER="$(find "$TMP" -maxdepth 1 -type d -name 'code-server-*' | head -1)"
if [[ -z "$FOLDER" || ! -x "$FOLDER/bin/code-server" ]]; then
  echo "fetch-code-server: the archive is not what was expected."
  exit 1
fi
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$FOLDER" "$DEST"
xattr -cr "$DEST"
echo "$TAG" > "$STAMP"
echo "fetch-code-server: ready in $DEST."
