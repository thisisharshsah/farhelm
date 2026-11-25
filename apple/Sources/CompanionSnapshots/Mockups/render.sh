#!/bin/bash
# Renders the board mock-ups (T-56) at the three sample widths, light and
# dark, into Snapshots/ beside this script. It stands in for T-17's
# apple/scripts/snapshots.sh, which is not on companion/main and can only
# capture the running app's own panel. The mock-ups are compiled with the
# design tokens and the shared design package as they are, so a picture
# shows what the tokens draw today; nothing here is part of any app target.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
apple="$(cd "$here/../../.." && pwd)"
output="${1:-$here/Snapshots}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The renderer's entry point lives outside the folder, so nothing in it
# would start a program if a target ever takes these files in.
printf '%s\n' 'import AppKit' '_ = NSApplication.shared' \
  'MainActor.assumeIsolated { MockupRenderer.main() }' > "$work/main.swift"

design="$apple/Sources/Companion/UI/Design"
xcrun --sdk macosx swiftc -swift-version 5 -O \
  -module-name CompanionMockups -target arm64-apple-macos14.0 \
  "$apple"/Shared/CompanionDesign/Sources/CompanionDesign/*.swift \
  "$design/Tokens.swift" "$design/GlassSurfaces.swift" "$design/SizeRules.swift" \
  "$here"/*.swift "$work/main.swift" \
  -o "$work/render"

mkdir -p "$output"
"$work/render" "$output"

# The window draws at the screen's Retina scale. Halved to the views' own
# point size, the pictures read the same in the doc and keep the branch
# small.
for png in "$output"/*.png; do
  width=$(sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')
  sips --resampleWidth $((width / 2)) "$png" > /dev/null
done