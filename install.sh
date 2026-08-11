#!/bin/bash
# install.sh — download and install shai from a GitHub Release
# Usage: gh api repos/ChristopherBilg/shai/contents/install.sh --jq '.content' | base64 -d | bash
#        SHAI_VERSION=v2026.08.10 gh api ... | base64 -d | bash   (pin a version)
# Reads: SHAI_VERSION (env, optional — defaults to latest GitHub Release)
# Writes: ~/.local/share/shai/<version>/ (extraction), ~/.local/bin/shai* (exec wrappers)
# Exit: 0 on success, 1 on download/extract failure, 2 if gh CLI is missing or unauthenticated
set -euo pipefail

REPO="ChristopherBilg/shai"
INSTALL_DIR="${HOME}/.local/share/shai"
BIN_DIR="${HOME}/.local/bin"

if ! command -v gh &>/dev/null; then
  printf 'error: gh CLI is required (https://cli.github.com)\n' >&2
  exit 2
fi
if ! gh auth status &>/dev/null; then
  printf 'error: gh CLI is not authenticated — run: gh auth login\n' >&2
  exit 2
fi

if [ -n "${SHAI_VERSION:-}" ]; then
  VERSION="$SHAI_VERSION"
else
  VERSION=$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null || true)
  if [ -z "$VERSION" ]; then
    printf 'error: could not resolve latest release\n' >&2
    exit 1
  fi
fi

if [[ "$VERSION" == */* ]] || [[ "$VERSION" == *..* ]]; then
  printf 'error: SHAI_VERSION must not contain / or .. (got "%s")\n' "$VERSION" >&2
  exit 1
fi

DEST="${INSTALL_DIR}/${VERSION}"
TMPDIR_EXTRACT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_EXTRACT"' EXIT

printf 'Installing shai %s...\n' "$VERSION"
if ! gh release download "$VERSION" --repo "$REPO" \
    --pattern "shai-${VERSION}.tar.gz" --dir "$TMPDIR_EXTRACT" 2>/dev/null; then
  printf 'error: failed to download shai %s\n' "$VERSION" >&2
  exit 1
fi
if ! tar xzf "$TMPDIR_EXTRACT/shai-${VERSION}.tar.gz" \
    -C "$TMPDIR_EXTRACT" --strip-components=1; then
  printf 'error: failed to extract shai %s\n' "$VERSION" >&2
  exit 1
fi
rm -f "$TMPDIR_EXTRACT/shai-${VERSION}.tar.gz"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$TMPDIR_EXTRACT" "$DEST"
trap - EXIT

mkdir -p "$BIN_DIR"
for script in "$DEST"/shai-*; do
  if [ -f "$script" ] && [ -x "$script" ]; then
    wrapper="$BIN_DIR/$(basename "$script")"
    escaped="${script//\'/\'\\\'\'}"
    printf "#!/bin/bash\nexec '%s' \"\$@\"\n" "$escaped" >"$wrapper"
    chmod +x "$wrapper"
  fi
done

printf '\nshai %s installed successfully\n' "$VERSION"
printf '  Files:    %s/\n' "$DEST"
printf '  Wrappers: %s/\n' "$BIN_DIR"

case ":${PATH}:" in
  *":${BIN_DIR}:"*) ;;
  *) printf '  Note: %s is not in your PATH. Add it with: export PATH="%s:$PATH"\n' "$BIN_DIR" "$BIN_DIR" ;;
esac
