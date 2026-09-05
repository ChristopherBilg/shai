#!/bin/bash
# test_conventions.sh — tests the project conventions checker
# Covers: tests/conventions.sh — fail-closed refusal to run on untracked scripts, clean-tree pass
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "conventions"

# conventions.sh locates its own root via ${BASH_SOURCE[0]} and shells out to
# `bash tests/lint.sh --list` for the lint-target cross-check, so the fixture is a scratch
# git repo holding copies of conventions.sh, lint.sh, and the shared guard helper — the same
# technique test_docs.sh and test_completions.sh use for their git-derived fixtures.
# conventions.sh must live under tests/ in the fixture: ROOT is the script's own parent's
# parent.
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/tests"
cp "$DIR/tests/conventions.sh" "$FIX/tests/conventions.sh"
cp "$DIR/tests/lint.sh" "$FIX/tests/lint.sh"
cp "$DIR/tests/run.sh" "$FIX/tests/run.sh"
cp "$DIR/tests/check-untracked.sh" "$FIX/tests/check-untracked.sh"
git -C "$FIX" init -q
cat >"$FIX/shai-clean" <<'EOF'
#!/bin/bash
# shai-clean — compliant committed fixture script
set -euo pipefail
EOF
chmod +x "$FIX/shai-clean"
# Stage the fixture's own scripts too: untracked they would trip the very guard under test.
git -C "$FIX" add shai-clean tests/conventions.sh tests/lint.sh tests/run.sh tests/check-untracked.sh

# Positive control: the same fixture with no untracked scripts passes every gate and
# prints the banner (this also exercises the lint-target cross-check against the fixture).
OUT="$(bash "$FIX/tests/conventions.sh" 2>&1)"
assert_eq "$?" "0" "untracked guard: a clean fixture tree passes"
assert_contains "$OUT" "CONVENTIONS OK" "untracked guard: clean fixture prints the banner"

# An untracked script is invisible to every git-derived list in the checker (RUNTIME,
# SCRIPTS, the lint cross-check), so the run must fail naming it instead of printing the
# green banner over it. (Mutation-checked: deleting the check_no_untracked_scripts call in
# conventions.sh leaves this green.)
cat >"$FIX/tests/newcon.sh" <<'EOF'
#!/bin/bash
# newcon.sh — untracked fixture script
EOF
OUT="$(bash "$FIX/tests/conventions.sh" 2>&1)"
assert_eq "$?" "1" "untracked guard: an untracked script fails the check"
assert_contains "$OUT" "error: 1 untracked script file(s) are invisible to this check — commit them first: tests/newcon.sh" \
  "untracked guard: names the invisible file"
assert_not_contains "$OUT" "CONVENTIONS OK" "untracked guard: no green banner over a dirty tree"

finish
