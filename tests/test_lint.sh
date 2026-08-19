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

# The linters themselves are stubbed with true/false: this suite must stay offline and must not
# depend on ./bin being populated, so it checks the plumbing (both tools run, both statuses are
# reported and aggregated), not shellcheck's or shfmt's own verdicts.
desc "both linters run and their exit status is aggregated"
OUT="$(SHELLCHECK=true SHFMT=true bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "0" "both linters clean → exit 0"
assert_contains "$OUT" "LINT OK" "clean run prints the LINT OK banner"

OUT="$(SHELLCHECK=false SHFMT=true bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "1" "shellcheck findings → exit 1"
assert_contains "$OUT" "shellcheck reported findings" "shellcheck failure is named"
assert_contains "$OUT" "shfmt:" "shfmt still runs after a shellcheck failure"

OUT="$(SHELLCHECK=true SHFMT=false bash "$DIR/tests/lint.sh" 2>&1)"
RC=$?
assert_eq "$RC" "1" "shfmt diff → exit 1"
assert_contains "$OUT" "shfmt reported a diff" "shfmt failure is named"

OUT="$(SHELLCHECK=true SHFMT=true bash "$DIR/tests/lint.sh" --write 2>&1)"
RC=$?
assert_eq "$RC" "0" "--write exits 0"
assert_contains "$OUT" "rewrote" "--write reports the in-place rewrite"

finish
