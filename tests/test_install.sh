#!/bin/bash
# test_install.sh — hermetic tests for the shai installer
# Covers: install.sh — tarball extraction, exec-wrapper installation, download failure cleanup,
#   gh prereqs, the post-install ci.json.example note, best-effort completion installation
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
  printf '{"_comment":"example ci config","version":"1.0","repos":{}}\n' >"$staging/ci.json.example"
  # The real completion installer + manifest: install.sh runs both installs best-effort, and
  # the assertions below check the generated files land at the standard XDG locations.
  cp "$DIR/shai-completions" "$staging/shai-completions"
  cp "$DIR/completions.json" "$staging/completions.json"
  (cd "$WORK" && tar czf "shai-${version}.tar.gz" "shai-${version}")
}

# Helper: gh stub that handles auth + release download for a given version
make_install_gh_stub() {
  local version="${1:-v2026.01.01}"
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "auth" ]; then exit 0; fi
if [ "\$1" = "release" ] && [ "\$2" = "download" ]; then
  dir=""
  prev=""
  for i in "\$@"; do
    if [ "\$prev" = "--dir" ]; then dir="\$i"; break; fi
    prev="\$i"
  done
  cp "$WORK/shai-${version}.tar.gz" "\$dir/"
  exit 0
fi
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
  printf '%s\n' "${version}"
  exit 0
fi
exit 1
STUB
  chmod +x "$WORK/bin/gh"
}

# Helper: gh stub that fails downloads (auth passes)
make_failing_gh_stub() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "auth" ]; then exit 0; fi
exit 1
STUB
  chmod +x "$WORK/bin/gh"
}

# Helper: gh stub that reports unauthenticated
make_unauthed_gh_stub() {
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/gh" <<'STUB'
#!/bin/bash
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

# --- Test: unauthenticated gh exits 2 ---
FAKE_HOME5="$WORK/home5"
mkdir -p "$FAKE_HOME5"
make_unauthed_gh_stub
err3=$(HOME="$FAKE_HOME5" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1 || echo "EXIT:$?")
assert_contains "$err3" "not authenticated" \
  "install: unauthenticated gh prints clear error"
assert_contains "$err3" "EXIT:2" \
  "install: unauthenticated gh exits 2"

# --- Test: latest version resolution via gh release view ---
FAKE_HOME6="$WORK/home6"
mkdir -p "$FAKE_HOME6"
build_fake_tarball "v2026.03.20"
make_install_gh_stub "v2026.03.20"

HOME="$FAKE_HOME6" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -d "$FAKE_HOME6/.local/share/shai/v2026.03.20" ] && echo y)" "y" \
  "install: resolves latest version via gh release view"
assert_eq "$(cat "$FAKE_HOME6/.local/share/shai/v2026.03.20/VERSION")" "v2026.03.20" \
  "install: latest resolution installs correct version"

# --- Test: post-install message points at ci.json.example when no config exists ---
FAKE_HOME7="$WORK/home7"
mkdir -p "$FAKE_HOME7"
build_fake_tarball "v2026.04.10"
make_install_gh_stub "v2026.04.10"

OUT=$(HOME="$FAKE_HOME7" SHAI_HOME="$FAKE_HOME7/.shai" SHAI_VERSION="v2026.04.10" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1)

assert_eq "$([ -f "$FAKE_HOME7/.local/share/shai/v2026.04.10/ci.json.example" ] && echo y)" "y" \
  "install: ci.json.example extracted"
assert_contains "$OUT" "ci.json.example" \
  "install: post-install note names ci.json.example"
assert_contains "$OUT" "$FAKE_HOME7/.shai/ci.json" \
  "install: post-install note names the target config path"

# --- Test: no ci note once a config already exists ---
mkdir -p "$FAKE_HOME7/.shai"
printf '{"version":"1.0","repos":{}}\n' >"$FAKE_HOME7/.shai/ci.json"
OUT=$(HOME="$FAKE_HOME7" SHAI_HOME="$FAKE_HOME7/.shai" SHAI_VERSION="v2026.04.10" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1)
if [[ "$OUT" == *"ci.json.example"* ]]; then
  echo -e "  ${RED}✗${NC} install: no ci note when a config already exists (note still shown)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} install: no ci note when a config already exists"
fi

# --- Test: completion files are installed alongside the wrappers ---
FAKE_HOME8="$WORK/home8"
mkdir -p "$FAKE_HOME8"
build_fake_tarball "v2026.05.01"
make_install_gh_stub "v2026.05.01"

OUT=$(HOME="$FAKE_HOME8" SHAI_VERSION="v2026.05.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1)

assert_eq "$([ -f "$FAKE_HOME8/.local/share/zsh/site-functions/_shai" ] && echo y)" "y" \
  "install: zsh completions written to the site-functions directory"
assert_eq "$([ -f "$FAKE_HOME8/.local/share/bash-completion/completions/shai" ] && echo y)" "y" \
  "install: bash completions written to the bash-completion directory"
assert_contains "$(head -n2 "$FAKE_HOME8/.local/share/zsh/site-functions/_shai")" \
  "Generated by shai-completions generate" \
  "install: the zsh completion file is generated output"
assert_contains "$OUT" "Installed zsh completions to" \
  "install: the zsh completion install prints its success line"
assert_contains "$OUT" "Add to .zshrc: fpath=($FAKE_HOME8/.local/share/zsh/site-functions \$fpath)" \
  "install: a newly created zsh completion dir prints the setup instruction with the resolved path"
assert_contains "$OUT" "Installed bash completions to" \
  "install: the bash completion install prints its success line"
assert_contains "$OUT" "Add to .bashrc: [[ -r $FAKE_HOME8/.local/share/bash-completion/completions/shai ]]" \
  "install: a newly created bash completion dir prints the setup instruction with the resolved path"

# --- Test: a missing completion installer never fails the install ---
FAKE_HOME9="$WORK/home9"
mkdir -p "$FAKE_HOME9"
# Tarball without shai-completions: both guarded install calls must be silent no-ops.
mkdir -p "$WORK/shai-v2026.06.01"
printf '#!/bin/bash\necho hello\n' >"$WORK/shai-v2026.06.01/shai-repl"
chmod +x "$WORK/shai-v2026.06.01/shai-repl"
(cd "$WORK" && tar czf "shai-v2026.06.01.tar.gz" "shai-v2026.06.01")
make_install_gh_stub "v2026.06.01"

OUT=$(HOME="$FAKE_HOME9" SHAI_VERSION="v2026.06.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "install: a missing shai-completions does not fail the install"
assert_eq "$([ -x "$FAKE_HOME9/.local/bin/shai-repl" ] && echo y)" "y" \
  "install: wrappers still installed when completion install is unavailable"

finish
