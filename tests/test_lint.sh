#!/bin/bash
# test_lint.sh — checks the single lint target: its git-derived file list and its flags
# Covers: tests/lint.sh — file list coverage (incl. tools/*/run.sh), --list/--write, usage errors, exit status
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "lint"

LIST="$(bash "$DIR/tests/lint.sh" --list)"

desc "the lint target covers every category of tracked shell script"
assert_contains "$LIST" "install.sh" "--list includes install.sh"
assert_contains "$LIST" "shai-eval" "--list includes shai-* scripts"
assert_contains "$LIST" "lib/workflow.sh" "--list includes lib/*.sh"
assert_contains "$LIST" "tools/write_file/run.sh" "--list includes tools/*/run.sh"
assert_contains "$LIST" "workflows/heartbeat/run.sh" "--list includes workflows/*/run.sh"
assert_contains "$LIST" "tests/lint.sh" "--list includes tests/*.sh"

desc "no tool plugin is left out (the gap issue #81 closed)"
MISSING=""
while IFS= read -r f; do
  printf '%s\n' "$LIST" | grep -qxF "$f" || MISSING="$MISSING $f"
done < <(cd "$DIR" && git ls-files 'tools/*/run.sh')
assert_eq "$MISSING" "" "every tools/*/run.sh is in the lint target"

desc "usage errors are rejected with exit 2"
assert_exit 2 "unknown flag exits 2" -- bash "$DIR/tests/lint.sh" --bogus
assert_exit 2 "extra argument exits 2" -- bash "$DIR/tests/lint.sh" --list --write

# The linters themselves are stubbed with a script that records its argv and exits with a
# configurable status: this suite must stay offline and must not depend on ./bin being populated,
# so it checks the plumbing (which binaries run, that both statuses are reported and aggregated,
# and that the git-derived file list actually reaches the linters), not the linters' own verdicts.
STUB_DIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$STUB_DIR")
ARGV_LOG="$STUB_DIR/argv.log"
: >"$ARGV_LOG"
write_lint_stub() { # name exit_code
  local name="$1" code="$2"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "$ARGV_LOG"
    printf 'exit %s\n' "$code"
  } >"$STUB_DIR/$name"
  chmod +x "$STUB_DIR/$name"
}
write_lint_stub shellcheck 0
write_lint_stub shfmt 0
write_lint_stub shellcheck-fail 1
write_lint_stub shfmt-fail 1

desc "resolved linters are printed and receive the git-derived file list"
OUT="$(SHELLCHECK="$STUB_DIR/shellcheck" SHFMT="$STUB_DIR/shfmt" bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "0" "both linters clean → exit 0"
assert_contains "$OUT" "LINT OK" "clean run prints the LINT OK banner"
assert_contains "$OUT" "shellcheck: $STUB_DIR/shellcheck" "resolved shellcheck path is printed"
assert_contains "$OUT" "shfmt: $STUB_DIR/shfmt" "resolved shfmt path is printed"
assert_contains "$(cat "$ARGV_LOG")" "install.sh" "shellcheck/shfmt receive the file list"

desc "shellcheck failure still runs shfmt and aggregates"
: >"$ARGV_LOG"
OUT="$(SHELLCHECK="$STUB_DIR/shellcheck-fail" SHFMT="$STUB_DIR/shfmt" bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "1" "shellcheck findings → exit 1"
assert_contains "$OUT" "shellcheck reported findings" "shellcheck failure is named"
assert_contains "$OUT" "shfmt:" "shfmt still runs after a shellcheck failure"
assert_contains "$(cat "$ARGV_LOG")" "install.sh" "shfmt still receives the file list"

desc "shfmt diff reports failure and aggregates"
OUT="$(SHELLCHECK="$STUB_DIR/shellcheck" SHFMT="$STUB_DIR/shfmt-fail" bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "1" "shfmt diff → exit 1"
assert_contains "$OUT" "shfmt reported a diff" "shfmt failure is named"

desc "--write mode reports success and still aggregates a failing write"
OUT="$(SHELLCHECK="$STUB_DIR/shellcheck" SHFMT="$STUB_DIR/shfmt" bash "$DIR/tests/lint.sh" --write 2>&1)"
RC=$?
assert_eq "$RC" "0" "--write exits 0"
assert_contains "$OUT" "rewrote" "--write reports the in-place rewrite"

OUT="$(SHELLCHECK="$STUB_DIR/shellcheck" SHFMT="$STUB_DIR/shfmt-fail" bash "$DIR/tests/lint.sh" --write 2>&1)"
RC=$?
assert_eq "$RC" "1" "--write shfmt failure → exit 1"
assert_contains "$OUT" "shfmt write failed" "write failure is named"
assert_contains "$OUT" "LINT FAILED" "write failure still prints the LINT FAILED banner"

finish
