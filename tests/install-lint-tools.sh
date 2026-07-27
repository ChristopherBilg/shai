#!/bin/bash
# Download pinned shellcheck + shfmt static binaries into ./bin, verified against
# tests/lint-tools.sha256 (a trust-on-first-use lockfile). Used by CI and locally.
# Usage: ./tests/install-lint-tools.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
cd "$ROOT"

SHELLCHECK_VERSION="v0.10.0"
SHFMT_VERSION="v3.10.0"
BIN="$ROOT/bin"
LOCK="tests/lint-tools.sha256"
mkdir -p "$BIN"

if [ ! -x "$BIN/shfmt" ]; then
  curl -fsSL "https://github.com/mvdan/sh/releases/download/${SHFMT_VERSION}/shfmt_${SHFMT_VERSION}_linux_amd64" -o "$BIN/shfmt"
  chmod +x "$BIN/shfmt"
fi

if [ ! -x "$BIN/shellcheck" ]; then
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" -o "$tmp/sc.tar.xz"
  tar -xJf "$tmp/sc.tar.xz" -C "$tmp"
  mv "$tmp/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck"
  chmod +x "$BIN/shellcheck"
  rm -rf "$tmp"
fi

# Integrity: verify against the lockfile, or create it on first use (trust-on-first-use).
if [ -f "$LOCK" ]; then
  (
    cd "$BIN" || exit 1
    sha256sum -c "../$LOCK"
  ) ||
    {
      echo "lint-tools checksum mismatch vs $LOCK" >&2
      exit 1
    }
else
  (
    cd "$BIN" || exit 1
    sha256sum shellcheck shfmt
  ) >"$LOCK"
  echo "wrote $LOCK (trust-on-first-use) — commit it to pin these binaries"
fi

echo "lint tools ready: $BIN/shellcheck $BIN/shfmt"
