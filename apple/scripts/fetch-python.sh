#!/bin/bash
# The Python that Companion's iCloud Passwords bridge runs on, with apwlib
# (MIT) already in it, so the app carries it and nothing is installed on
# the Mac that runs Companion. A standalone CPython 3.12 build
# (astral-sh/python-build-standalone), checked against the release's
# SHA256SUMS, lands in Vendor/python (ignored by git).
#
# Usage: bash scripts/fetch-python.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="$PWD/Vendor/python"
APWLIB="apwlib==0.1.2"
API="https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest"

case "$(uname -m)" in
  arm64) TRIPLE=aarch64-apple-darwin ;;
  x86_64) TRIPLE=x86_64-apple-darwin ;;
  *) echo "fetch-python: unsupported architecture $(uname -m)"; exit 1 ;;
esac

if [[ -x "$DEST/bin/python3" ]] && "$DEST/bin/python3" -c "import apwlib, companion_host" 2>/dev/null \
   && [[ "$("$DEST/bin/python3" -m pip show apwlib 2>/dev/null | awk '/^Version/ {print $2}')" == "${APWLIB#*==}" ]]; then
  echo "fetch-python: Python with $APWLIB is already here."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "fetch-python: finding the newest standalone Python 3.12…"
curl -fsSL "$API" -o "$TMP/release.json"
read -r URL SUMS < <(python3 - "$TMP/release.json" "$TRIPLE" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
pattern = re.compile(r"cpython-3\.12\.\d+\+\d+-" + re.escape(sys.argv[2]) + r"-install_only\.tar\.gz$")
names = sorted(n for n in assets if pattern.match(n))
if not names or "SHA256SUMS" not in assets:
    sys.exit("no Python 3.12 build for this Mac in the latest release")
print(assets[names[-1]], assets["SHA256SUMS"])
PY
)
# The asset's real name ("+" is "%2B" in its URL), as SHA256SUMS lists it.
NAME="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "${URL##*/}")"

echo "fetch-python: downloading ${NAME}…"
curl -fL --progress-bar "$URL" -o "$TMP/$NAME"
curl -fsSL "$SUMS" -o "$TMP/SHA256SUMS"
WANT="$(awk -v n="$NAME" '$2 == n {print $1}' "$TMP/SHA256SUMS")"
GOT="$(shasum -a 256 "$TMP/$NAME" | awk '{print $1}')"
if [[ -z "$WANT" || "$WANT" != "$GOT" ]]; then
  echo "fetch-python: checksum mismatch; not using it."
  exit 1
fi

tar -xzf "$TMP/$NAME" -C "$TMP"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/python" "$DEST"

echo "fetch-python: adding ${APWLIB}…"
"$DEST/bin/python3" -m pip install --quiet --no-cache-dir --disable-pip-version-check "$APWLIB"

# Lets apwlib use the Chromium inside Companion (and never Arc).
SITE="$("$DEST/bin/python3" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
rm -f "$SITE/companion_arc.py" "$SITE/companion_arc.pth"
cp Resources/Python/companion_host.py "$SITE/companion_host.py"
echo "import companion_host" > "$SITE/companion_host.pth"

echo "fetch-python: ready in Vendor/python."
