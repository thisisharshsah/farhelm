#!/usr/bin/env bash
#
# Install the RelayForge runner and join it to this control plane.
#
#   curl -fsSL https://farhelm.aurovie.com/install.sh | bash
#
# Served by the control plane it enrols you into, which is the property worth
# having: the TLS connection that hands you this script is the same one the
# machine will authenticate against afterwards. There is no second origin to
# trust, and no credential to copy — installing and connecting are one step.
#
# Read before you run, as with anything of this shape:
#   curl -fsSL https://farhelm.aurovie.com/install.sh | less
#
set -euo pipefail

# Where this came from, and therefore where the machine will belong. Override
# to install against a different deployment:
#   FORGE_CLOUD=https://staging.example.com bash install.sh
CLOUD="${FORGE_CLOUD:-https://farhelm.aurovie.com}"
HOME_DIR="${FORGE_HOME:-$HOME/.relayforge}"
BIN_DIR="$HOME_DIR/bin"

say()  { printf '  %s\n' "$*"; }
bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

bold "RelayForge — installing from $CLOUD"

# ---------------------------------------------------------------- platform ---

os="$(uname -s)"
arch="$(uname -m)"
case "$os-$arch" in
  Darwin-arm64)  target="aarch64-apple-darwin" ;;
  Darwin-x86_64) target="x86_64-apple-darwin" ;;
  Linux-x86_64)  target="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64) target="aarch64-unknown-linux-gnu" ;;
  *) die "unsupported platform $os $arch — build it yourself:
       git clone https://github.com/thisisharshsah/farhelm.git
       cargo build --release -p forge-runner" ;;
esac
say "platform   $os $arch → $target"

command -v curl >/dev/null || die "curl is required"

# ------------------------------------------------------------------ fetch ---

mkdir -p "$BIN_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The control plane serves a single-page app, so an unknown path comes back as
# index.html with status 200 rather than a 404. `curl -f` cannot see that. So
# whatever arrives is checked for being an actual executable before it is
# allowed anywhere near $BIN_DIR — otherwise a missing build for this platform
# installs an HTML page named `forge-runner`.
looks_executable() {
  local file="$1"
  [ -s "$file" ] || return 1
  case "$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')" in
    cffaedfe|cefaedfe|cafebabe|7f454c46) return 0 ;;  # Mach-O, fat, ELF
    *) return 1 ;;
  esac
}

installed_from_source=no
if curl -fsSL "$CLOUD/dl/$target/forge-runner" -o "$tmp/forge-runner" 2>/dev/null \
   && looks_executable "$tmp/forge-runner"; then
  say "runner     downloaded a prebuilt binary"

  # Best-effort integrity check. A checksum served beside the binary by the same
  # host is not a supply-chain guarantee — it catches a truncated or corrupted
  # download, which is the failure that actually happens.
  if curl -fsSL "$CLOUD/dl/$target/forge-runner.sha256" -o "$tmp/sum" 2>/dev/null \
     && grep -qE '^[0-9a-f]{64}' "$tmp/sum"; then
    want="$(tr -d ' \n' < "$tmp/sum" | cut -c1-64)"
    if command -v shasum >/dev/null; then got="$(shasum -a 256 "$tmp/forge-runner" | cut -d' ' -f1)"
    else got="$(sha256sum "$tmp/forge-runner" | cut -d' ' -f1)"; fi
    [ "$want" = "$got" ] || die "checksum mismatch — refusing to install"
    say "checksum   verified"
  fi
else
  # No build published for this platform. Building is a real answer rather than
  # a dead end, and on a developer machine the toolchain is usually already here.
  command -v cargo >/dev/null \
    || die "no prebuilt binary for $target at $CLOUD, and cargo is not installed.
       Install Rust (https://rustup.rs) and re-run, or build forge-runner elsewhere
       and copy it to $BIN_DIR/forge-runner"

  say "runner     no prebuilt binary for $target — building from source"
  src="${FORGE_SRC:-$tmp/src}"
  if [ ! -d "$src" ]; then
    command -v git >/dev/null || die "git is required to build from source"
    git clone --depth 1 "${FORGE_REPO:-https://github.com/thisisharshsah/farhelm.git}" "$src" \
      || die "could not clone the source — set FORGE_SRC to a local checkout"
  fi
  ( cd "$src" && cargo build --release -p forge-runner ) || die "the build failed"
  cp "$src/target/release/forge-runner" "$tmp/forge-runner"
  installed_from_source=yes
fi

chmod 755 "$tmp/forge-runner"
mv -f "$tmp/forge-runner" "$BIN_DIR/forge-runner.new"
mv -f "$BIN_DIR/forge-runner.new" "$BIN_DIR/forge-runner"   # atomic over a running copy
say "installed  $BIN_DIR/forge-runner"
say "version    $("$BIN_DIR/forge-runner" --help | head -1)"

# ------------------------------------------------------------------- join ---

if [ -f "$HOME_DIR/forge.cloud.json" ]; then
  bold "Already joined"
  say "$HOME_DIR/forge.cloud.json exists — this machine has enrolled before."
  say "Start it with:  cd $HOME_DIR && $BIN_DIR/forge-runner serve"
  say "To join somewhere else: $BIN_DIR/forge-runner logout, then re-run this."
  exit 0
fi

bold "Joining $CLOUD"
say "A code will appear. Approve it where you are already signed in."

cd "$HOME_DIR"
# Safe under a pipe: `login` prints a code and polls, and never reads stdin.
# Anything here that did would consume the rest of this script, because piped
# into bash the script *is* stdin — so if a prompt is ever added, it has to read
# from /dev/tty explicitly.
"$BIN_DIR/forge-runner" login --cloud "$CLOUD"

# ------------------------------------------------------------------ next ---

bold "Done"
say "Start the runner:   cd $HOME_DIR && $BIN_DIR/forge-runner serve"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "Add to PATH:        export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
say "Keep it running:    $BIN_DIR/forge-runner install-service"
[ "$installed_from_source" = yes ] && say "(built from source — re-run this script to update)"
exit 0
