#!/bin/bash
# test_install.sh — hermetic tests for the shai installer
# Covers: install.sh — tarball extraction, symlinking, download failure cleanup
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh"

WORK="$(mktemp -d)"
_CLEANUP_DIRS+=("$WORK")

# Helper: build a fake release tarball at $WORK/shai-<version>.tar.gz
build_fake_tarball() {
  local version="${1:-v2026.01.01}"
  local staging="$WORK/shai-${version}"
  rm -rf "$staging"
  mkdir -p "$staging"
  printf '#!/bin/bash\necho hello\n' >"$staging/shai"
  chmod +x "$staging/shai"
  printf '#!/bin/bash\necho doctor\n' >"$staging/shai-doctor"
  chmod +x "$staging/shai-doctor"
  echo "$version" >"$staging/VERSION"
  echo "not executable" >"$staging/README.md"
  (cd "$WORK" && tar czf "shai-${version}.tar.gz" "shai-${version}")
}

# Helper: curl stub that outputs the fake tarball
make_install_curl_stub() {
  local version="${1:-v2026.01.01}"
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/curl" <<STUB
#!/bin/bash
cat "$WORK/shai-${version}.tar.gz"
STUB
  chmod +x "$WORK/bin/curl"
}

# Helper: curl stub that fails
make_failing_curl_stub() {
  mkdir -p "$WORK/bin"
  printf '#!/bin/bash\nexit 1\n' >"$WORK/bin/curl"
  chmod +x "$WORK/bin/curl"
}

# --- Test: successful install ---
FAKE_HOME="$WORK/home1"
mkdir -p "$FAKE_HOME"
build_fake_tarball "v2026.01.01"
make_install_curl_stub "v2026.01.01"

HOME="$FAKE_HOME" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/shai" ] && echo y)" "y" \
  "install: shai extracted"
assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/shai-doctor" ] && echo y)" "y" \
  "install: shai-doctor extracted"
assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/VERSION" ] && echo y)" "y" \
  "install: VERSION extracted"
assert_eq "$([ -L "$FAKE_HOME/.local/bin/shai" ] && echo y)" "y" \
  "install: shai symlinked"
assert_eq "$([ -L "$FAKE_HOME/.local/bin/shai-doctor" ] && echo y)" "y" \
  "install: shai-doctor symlinked"
assert_eq "$([ -L "$FAKE_HOME/.local/bin/README.md" ] && echo y || echo n)" "n" \
  "install: non-executable README.md not symlinked"

# --- Test: failed download cleans up ---
FAKE_HOME2="$WORK/home2"
mkdir -p "$FAKE_HOME2"
make_failing_curl_stub

HOME="$FAKE_HOME2" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1 || true

assert_eq "$([ -d "$FAKE_HOME2/.local/share/shai/v2026.01.01" ] && echo y || echo n)" "n" \
  "install: cleans up dest dir on failed download"

# --- Test: SHAI_VERSION is respected ---
FAKE_HOME3="$WORK/home3"
mkdir -p "$FAKE_HOME3"
build_fake_tarball "v2026.02.15"
make_install_curl_stub "v2026.02.15"

HOME="$FAKE_HOME3" SHAI_VERSION="v2026.02.15" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -d "$FAKE_HOME3/.local/share/shai/v2026.02.15" ] && echo y)" "y" \
  "install: respects SHAI_VERSION"
assert_eq "$(cat "$FAKE_HOME3/.local/share/shai/v2026.02.15/VERSION")" "v2026.02.15" \
  "install: correct version in VERSION file"

finish
