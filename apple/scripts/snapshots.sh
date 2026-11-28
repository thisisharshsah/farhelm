#!/bin/bash
set -euo pipefail

apple_dir="$(cd "$(dirname "$0")/.." && pwd)"
companion="$apple_dir/.build/release/Companion"
output="${1:-$apple_dir/.build/snapshots}"

if [[ ! -x "$companion" ]]; then
  printf '%s\n' 'Build Companion first with bash apple/build.sh build.' >&2
  exit 1
fi

mkdir -p "$output"
output="$(cd "$output" && pwd)"
for appearance in light dark; do
  "$companion" --panel-snapshots "$output" -appearance "$appearance"
done

printf 'Panel snapshots saved to %s\n' "$output"