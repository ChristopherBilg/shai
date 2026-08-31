#!/bin/bash
# test_install.sh — hermetic tests for the shai installer
# Covers: install.sh — tarball extraction, exec-wrapper installation, download failure cleanup,
#   gh prereqs, the post-install ci.json.example note, best-effort completion installation,
#   the current symlink (relative target, second-install replacement, pre-current self-heal)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "install.sh"

# Regression guard for #331: lib.sh unsets an inherited XDG_DATA_HOME, which is
# this suite's only protection against writing completions outside the fixture.
# Fail loudly in environments that export it if that unset is ever removed.
assert_eq "${XDG_DATA_HOME+x}" "" "install: lib.sh neutralizes an inherited XDG_DATA_HOME"

WORK="$(mktemp -d)"
_CLEANUP_DIRS+=("$WORK")

# build_fake_tarball and make_install_gh_stub live in tests/lib.sh (shared with
# tests/test_update.sh); make_failing_gh_stub / make_unauthed_gh_stub stay local.

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
build_fake_tarball "$WORK" "v2026.01.01"
make_install_gh_stub "$WORK" "v2026.01.01"

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
  "exec '$FAKE_HOME/.local/share/shai/current/shai-repl'" \
  "install: shai-repl wrapper execs through the current symlink"
assert_eq "$([ -L "$FAKE_HOME/.local/share/shai/current" ] && echo y || echo n)" "y" \
  "install: current is a symlink"
assert_eq "$(readlink "$FAKE_HOME/.local/share/shai/current")" "v2026.01.01" \
  "install: current target is relative and names the installed version"
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

# --- Test: a second install re-points current instead of nesting inside it ---
# `mv -T` exists because a plain `mv tmp current` where current is an existing
# symlink-to-directory moves tmp *inside* the pointed-to directory. Two consecutive
# installs must leave current a symlink (asserted as such, not merely re-pointed).
build_fake_tarball "$WORK" "v2026.02.01"
make_install_gh_stub "$WORK" "v2026.02.01"
OUT=$(HOME="$FAKE_HOME" SHAI_VERSION="v2026.02.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1)
assert_eq "$([ -L "$FAKE_HOME/.local/share/shai/current" ] && echo y || echo n)" "y" \
  "install: current is still a symlink after a second install"
assert_eq "$(readlink "$FAKE_HOME/.local/share/shai/current")" "v2026.02.01" \
  "install: current re-points to the newly installed version"
assert_eq "$([ -d "$FAKE_HOME/.local/share/shai/v2026.01.01" ] && echo y || echo n)" "y" \
  "install: the previous version tree survives (rollback / in-flight runs)"
assert_eq "$(cat "$FAKE_HOME/.local/share/shai/current/VERSION")" "v2026.02.01" \
  "install: current resolves to the new tree"
assert_contains "$(cat "$FAKE_HOME/.local/bin/shai-repl")" \
  "exec '$FAKE_HOME/.local/share/shai/current/shai-repl'" \
  "install: wrapper still execs through current after the second install"
assert_contains "$OUT" "current -> v2026.02.01" \
  "install: success output names what current points at"

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
build_fake_tarball "$WORK" "v2026.02.15"
make_install_gh_stub "$WORK" "v2026.02.15"

HOME="$FAKE_HOME3" SHAI_VERSION="v2026.02.15" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -d "$FAKE_HOME3/.local/share/shai/v2026.02.15" ] && echo y)" "y" \
  "install: respects SHAI_VERSION"
assert_eq "$(cat "$FAKE_HOME3/.local/share/shai/v2026.02.15/VERSION")" "v2026.02.15" \
  "install: correct version in VERSION file"

# --- Test: path traversal in SHAI_VERSION is rejected ---
FAKE_HOME4="$WORK/home4"
mkdir -p "$FAKE_HOME4"
make_install_gh_stub "$WORK"
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
build_fake_tarball "$WORK" "v2026.03.20"
make_install_gh_stub "$WORK" "v2026.03.20"

HOME="$FAKE_HOME6" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_eq "$([ -d "$FAKE_HOME6/.local/share/shai/v2026.03.20" ] && echo y)" "y" \
  "install: resolves latest version via gh release view"
assert_eq "$(cat "$FAKE_HOME6/.local/share/shai/v2026.03.20/VERSION")" "v2026.03.20" \
  "install: latest resolution installs correct version"

# --- Test: post-install message points at ci.json.example when no config exists ---
FAKE_HOME7="$WORK/home7"
mkdir -p "$FAKE_HOME7"
build_fake_tarball "$WORK" "v2026.04.10"
make_install_gh_stub "$WORK" "v2026.04.10"

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
build_fake_tarball "$WORK" "v2026.05.01"
make_install_gh_stub "$WORK" "v2026.05.01"

OUT=$(HOME="$FAKE_HOME8" SHAI_VERSION="v2026.05.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1)

assert_eq "$([ -f "$FAKE_HOME8/.local/share/zsh/site-functions/_shai" ] && echo y)" "y" \
  "install: zsh completions written to the site-functions directory"
assert_eq "$([ -f "$FAKE_HOME8/.local/share/bash-completion/completions/shai" ] && echo y)" "y" \
  "install: bash completions written to the bash-completion directory"
assert_contains "$(head -n2 "$FAKE_HOME8/.local/share/zsh/site-functions/_shai")" \
  "Generated by shai-completions generate" \
  "install: the zsh completion file is generated output"
assert_contains "$OUT" "Installed zsh completions to $FAKE_HOME8/.local/share/zsh/site-functions/_shai" \
  "install: the zsh completion install prints its success line with the resolved path"
assert_contains "$OUT" "fpath=($FAKE_HOME8/.local/share/zsh/site-functions \$fpath)" \
  "install: the zsh completion install prints the fpath setup instruction with the resolved path"
assert_contains "$OUT" "Installed bash completions to $FAKE_HOME8/.local/share/bash-completion/completions/shai" \
  "install: the bash completion install prints its success line with the resolved path"
assert_contains "$OUT" "Add to .bashrc: [[ -r $FAKE_HOME8/.local/share/bash-completion/completions/shai ]]" \
  "install: the bash completion install prints the setup instruction with the resolved path"

# --- Test: a missing completion installer never fails the install ---
FAKE_HOME9="$WORK/home9"
mkdir -p "$FAKE_HOME9"
# Tarball without shai-completions: both guarded install calls must be silent no-ops.
mkdir -p "$WORK/shai-v2026.06.01"
printf '#!/bin/bash\necho hello\n' >"$WORK/shai-v2026.06.01/shai-repl"
chmod +x "$WORK/shai-v2026.06.01/shai-repl"
(cd "$WORK" && tar czf "shai-v2026.06.01.tar.gz" "shai-v2026.06.01")
make_install_gh_stub "$WORK" "v2026.06.01"

OUT=$(HOME="$FAKE_HOME9" SHAI_VERSION="v2026.06.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" 2>&1) && RC=0 || RC=$?
assert_eq "$RC" "0" "install: a missing shai-completions does not fail the install"
assert_eq "$([ -x "$FAKE_HOME9/.local/bin/shai-repl" ] && echo y)" "y" \
  "install: wrappers still installed when completion install is unavailable"

# --- Test: re-run over a pre-current install self-heals the wrappers ---
# A release installed before `current` existed has wrappers exec'ing a versioned
# path and no current symlink. One re-run of install.sh must rewrite the wrappers
# to resolve through current, with no other user action.
FAKE_HOME10="$WORK/home10"
mkdir -p "$FAKE_HOME10/.local/bin"
mkdir -p "$FAKE_HOME10/.local/share/shai/v2026.01.01"
printf '#!/bin/bash\necho precurrent\n' >"$FAKE_HOME10/.local/share/shai/v2026.01.01/shai-repl"
chmod +x "$FAKE_HOME10/.local/share/shai/v2026.01.01/shai-repl"
printf "#!/bin/bash\nexec '%s' \"\$@\"\n" \
  "$FAKE_HOME10/.local/share/shai/v2026.01.01/shai-repl" >"$FAKE_HOME10/.local/bin/shai-repl"
chmod +x "$FAKE_HOME10/.local/bin/shai-repl"

build_fake_tarball "$WORK" "v2026.01.01"
make_install_gh_stub "$WORK" "v2026.01.01"
HOME="$FAKE_HOME10" SHAI_VERSION="v2026.01.01" \
  PATH="$WORK/bin:$PATH" bash "$DIR/install.sh" >/dev/null 2>&1

assert_contains "$(cat "$FAKE_HOME10/.local/bin/shai-repl")" \
  "exec '$FAKE_HOME10/.local/share/shai/current/shai-repl'" \
  "install: re-run over a pre-current install rewrites the wrapper through current"
assert_eq "$("$FAKE_HOME10/.local/bin/shai-repl")" "hello" \
  "install: the self-healed wrapper runs the freshly installed script"

finish
