#!/bin/bash
# test_install.sh — hermetic tests for the shai installer
# Covers: install.sh — tarball extraction, exec-wrapper installation, download failure cleanup
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
  printf '#!/bin/bash\necho hello\n' >"$staging/shai-repl"
  chmod +x "$staging/shai-repl"
  printf '#!/bin/bash\necho doctor\n' >"$staging/shai-doctor"
  chmod +x "$staging/shai-doctor"
  echo "$version" >"$staging/VERSION"
  echo "not executable" >"$staging/README.md"
  (cd "$WORK" && tar czf "shai-${version}.tar.gz" "shai-${version}")
}

# Helper: gh stub that handles auth status + release download
make_install_gh_stub() {
  local version="${1:-v2026.01.01}"
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "auth" ]; then
  exit 0
fi
if [ "\$1" = "release" ] && [ "\$2" = "download" ]; then
  # find --dir arg
  dir=""
  for i in "\$@"; do
    if [ "\$prev" = "--dir" ]; then dir="\$i"; break; fi
    prev="\$i"
  done
  cp "$WORK/shai-${version}.tar.gz" "\$dir/"
  exit 0
fi
exit 1
STUB
  chmod +x "$WORK/bin/gh"
}

# Helper: gh stub that fails the download
make_failing_gh_stub() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "auth" ]; then exit 0; fi
exit 1
STUB
  chmod +x "$WORK/bin/gh"
}

# --- Test: successful install ---
FAKE_HOME="$WORK/home1"
mkdir -p "$FAKE_HOME"
build_fake_tarball "v2026.01.01"
make_install_gh_stub "v2026.01.01"

HOME="$FAKE_HOME" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/shai-repl" ] && echo y)" "y" \
  "install: shai-repl extracted"
assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/shai-doctor" ] && echo y)" "y" \
  "install: shai-doctor extracted"
assert_eq "$([ -f "$FAKE_HOME/.local/share/shai/v2026.01.01/VERSION" ] && echo y)" "y" \
  "install: VERSION extracted"
assert_eq "$([ -x "$FAKE_HOME/.local/bin/shai-repl" ] && echo y)" "y" \
  "install: shai-repl wrapper is executable"
assert_eq "$([ -L "$FAKE_HOME/.local/bin/shai-repl" ] && echo y || echo n)" "n" \
  "install: shai-repl wrapper is a real file, not a symlink"
assert_contains "$(cat "$FAKE_HOME/.local/bin/shai-repl")" \
  "exec '$FAKE_HOME/.local/share/shai/v2026.01.01/shai-repl'" \
  "install: shai-repl wrapper execs the real script path"
assert_eq "$("$FAKE_HOME/.local/bin/shai-repl")" "hello" \
  "install: shai-repl wrapper runs the real script"
assert_eq "$([ -x "$FAKE_HOME/.local/bin/shai-doctor" ] && echo y)" "y" \
  "install: shai-doctor wrapper is executable"
assert_eq "$([ -L "$FAKE_HOME/.local/bin/shai-doctor" ] && echo y || echo n)" "n" \
  "install: shai-doctor wrapper is a real file, not a symlink"
assert_eq "$("$FAKE_HOME/.local/bin/shai-doctor")" "doctor" \
  "install: shai-doctor wrapper runs the real script"
assert_eq "$([ -e "$FAKE_HOME/.local/bin/README.md" ] && echo y || echo n)" "n" \
  "install: non-executable README.md gets no wrapper"

# --- Test: failed download cleans up ---
FAKE_HOME2="$WORK/home2"
mkdir -p "$FAKE_HOME2"
make_failing_gh_stub

HOME="$FAKE_HOME2" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1 || true

assert_eq "$([ -d "$FAKE_HOME2/.local/share/shai/v2026.01.01" ] && echo y || echo n)" "n" \
  "install: cleans up dest dir on failed download"

# --- Test: SHAI_VERSION is respected ---
FAKE_HOME3="$WORK/home3"
mkdir -p "$FAKE_HOME3"
build_fake_tarball "v2026.02.15"
make_install_gh_stub "v2026.02.15"

HOME="$FAKE_HOME3" SHAI_VERSION="v2026.02.15" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -d "$FAKE_HOME3/.local/share/shai/v2026.02.15" ] && echo y)" "y" \
  "install: respects SHAI_VERSION"
assert_eq "$(cat "$FAKE_HOME3/.local/share/shai/v2026.02.15/VERSION")" "v2026.02.15" \
  "install: correct version in VERSION file"

# --- Test: path traversal in SHAI_VERSION is rejected ---
FAKE_HOME4="$WORK/home4"
mkdir -p "$FAKE_HOME4"
make_install_gh_stub
err=$(HOME="$FAKE_HOME4" SHAI_VERSION="../../../etc" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1 || true)
assert_contains "$err" "must not contain" \
  "install: rejects SHAI_VERSION with .."

err2=$(HOME="$FAKE_HOME4" SHAI_VERSION="v1/../../x" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1 || true)
assert_contains "$err2" "must not contain" \
  "install: rejects SHAI_VERSION with /"

finish
