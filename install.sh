#!/bin/bash
# install.sh — download and install shai from a GitHub Release
# Usage: curl -sSL https://raw.githubusercontent.com/ChristopherBilg/shai/main/install.sh | bash
#        SHAI_VERSION=v2026.08.10 curl ... | bash   (pin a specific version)
# Reads: SHAI_VERSION (env, optional — defaults to latest GitHub Release)
# Writes: ~/.local/share/shai/<version>/ (extraction), ~/.local/bin/shai* (symlinks)
# Exit: 0 on success, 1 on download/extract failure
set -euo pipefail

REPO="ChristopherBilg/shai"
INSTALL_DIR="${HOME}/.local/share/shai"
BIN_DIR="${HOME}/.local/bin"

if [ -n "${SHAI_VERSION:-}" ]; then
  VERSION="$SHAI_VERSION"
else
  VERSION=$(curl -sSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO}/releases/latest" | grep -oE '[^/]+$')
  if [ -z "$VERSION" ]; then
    printf 'error: could not resolve latest release\n' >&2
    exit 1
  fi
fi

TARBALL_URL="https://github.com/${REPO}/releases/download/${VERSION}/shai-${VERSION}.tar.gz"
DEST="${INSTALL_DIR}/${VERSION}"

printf 'Installing shai %s...\n' "$VERSION"
mkdir -p "$DEST"
if ! curl -sSL "$TARBALL_URL" | tar xz -C "$DEST" --strip-components=1; then
  printf 'error: failed to download or extract shai %s\n' "$VERSION" >&2
  rm -rf "$DEST"
  exit 1
fi

mkdir -p "$BIN_DIR"
for script in "$DEST"/shai "$DEST"/shai-*; do
  if [ -f "$script" ] && [ -x "$script" ]; then
    ln -sf "$script" "$BIN_DIR/$(basename "$script")"
  fi
done

printf '\nshai %s installed successfully\n' "$VERSION"
printf '  Files:    %s/\n' "$DEST"
printf '  Symlinks: %s/\n' "$BIN_DIR"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) printf '  Note: %s is not in your PATH. Add it with: export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac
