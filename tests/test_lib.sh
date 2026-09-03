#!/bin/bash
# test_lib.sh — unit tests for the assertion helpers in tests/lib.sh
# Covers: assert_fails — empty-fragment usage error, command skipped, literal fragment match;
#         assert_row_count — blank output is 0 rows, header excluded, exact count enforced
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- empty stderr fragment: usage error that flips FAILED and skips the command ---
# Pins issue #349's acceptance criterion: a regression back to the tautological
# `assert_contains "$err" ""` must turn this suite red instead of staying green.
desc "assert_fails: empty fragment is a usage error"
D="$(mktemp -d)"
_CLEANUP_DIRS+=("$D")
(
  FAILED=0
  assert_fails 1 "" "empty fragment usage error" -- touch "$D/ran"
  exit "$FAILED"
)
assert_eq "$?" "1" "empty fragment flips FAILED and returns non-zero"
RC=0
[ -e "$D/ran" ] && RC=1
assert_eq "$RC" "0" "command is not run on the usage error"

# --- fragments containing glob metacharacters are matched literally ---
# assert_contains matches `[[ $1 == *"$2"* ]]`; the quoted "$2" is a literal string, not a
# pattern (bash: "Any part of the pattern may be quoted to force the quoted portion to be
# matched as a string"). Pin that so a fragment like the real
# `([A-Za-z_][A-Za-z0-9_]*)` at tools/ci/run.sh:199 can never false-pass on unrelated stderr.
desc "assert_fails: glob metacharacters in the fragment match literally"
(
  FAILED=0
  assert_fails 1 'bad [x]*?' "metacharacter fragment" -- bash -c 'printf "%s\n" "bad [x]*?" >&2; exit 1'
  exit "$FAILED"
)
assert_eq "$?" "0" "fragment with [ * ? matches the identical literal stderr"

desc "assert_fails: glob-style fragment cannot match unrelated stderr (inner ✗ expected)"
(
  FAILED=0
  assert_fails 1 '[A-Za-z_][A-Za-z0-9_]*' "glob-style fragment" -- bash -c 'printf "%s\n" "foo" >&2; exit 1'
  exit "$FAILED"
)
assert_eq "$?" "1" "a glob-interpreted fragment would false-pass; literal match fails"

# --- assert_row_count: blank output is 0 rows, header excluded, count must be exact ---
# This suite runs each failing-direction probe in a subshell so the inner ✗ (which flips
# FAILED) is itself the assertion. A counting helper that cannot fail is the exact defect
# this helper exists to prevent (CLAUDE.md, "no unfalsifiable assertions").
desc "assert_row_count: blank output counts as 0 rows"
(
  FAILED=0
  assert_row_count "" 0 "blank output is 0 rows"
  exit "$FAILED"
)
assert_eq "$?" "0" "blank output with expected 0 passes"

desc "assert_row_count: blank output is red when a nonzero count is expected (inner ✗ expected)"
(
  FAILED=0
  assert_row_count "" 1 "blank output cannot be 1 row"
  exit "$FAILED"
)
assert_eq "$?" "1" "blank output with expected 1 flips FAILED"

desc "assert_row_count: header-only output counts as 0 rows"
(
  FAILED=0
  assert_row_count "SESSION" 0 "header-only table has 0 data rows"
  exit "$FAILED"
)
assert_eq "$?" "0" "header line alone counts as 0"

desc "assert_row_count: header excluded, one data row"
(
  FAILED=0
  assert_row_count $'SESSION\tSTARTED\nsess_1\t2026-08-11 12:00' 1 "one data row below the header"
  exit "$FAILED"
)
assert_eq "$?" "0" "header + 1 data row counts as 1"

desc "assert_row_count: count off by one goes red (inner ✗ expected)"
(
  FAILED=0
  assert_row_count $'SESSION\tSTARTED\nsess_1\t2026-08-11 12:00' 2 "two rows when only one exists"
  exit "$FAILED"
)
assert_eq "$?" "1" "an over-counted table flips FAILED"

finish
