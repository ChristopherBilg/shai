#!/bin/bash
# test_run_runner.sh — unit tests for tests/run.sh's single-suite filter and summary block
# Covers: name/.sh/glob filter forms select exactly the matching suites, the per-suite PASS
#   summary block names every suite that ran, and a filter matching nothing exits 1 with
#   "no suites matched" instead of a false-green ALL SUITES PASSED (0)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tests/run.sh"

RUNNER="$DIR/tests/run.sh"

# Filter by bare suite name: runs only test_ci.sh, and the summary block names it exactly once.
desc "filter by bare name"
OUT=$("$RUNNER" test_ci)
RC=$?
assert_eq "$RC" "0" "bare name: exit 0"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^PASS test_ci\.sh$')" "1" \
  "bare name: exactly one PASS test_ci.sh summary line"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^PASS ')" "1" "bare name: only one suite ran"
assert_contains "$OUT" "ALL SUITES PASSED" "bare name: banner shows the single suite"

# Filter by file name (with .sh): same result as the bare name.
desc "filter by file name"
OUT=$("$RUNNER" test_ci.sh)
RC=$?
assert_eq "$RC" "0" "file name: exit 0"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^PASS test_ci\.sh$')" "1" \
  "file name: exactly one PASS test_ci.sh summary line"

# Filter by glob: matches every suite the glob names (only test_ci.sh here).
desc "filter by glob"
OUT=$("$RUNNER" 'test_ci*')
RC=$?
assert_eq "$RC" "0" "glob: exit 0"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^PASS test_ci\.sh$')" "1" \
  "glob: exactly one PASS test_ci.sh summary line"

# A filter that matches nothing must not report a false-green ALL SUITES PASSED (0).
desc "filter matches nothing"
OUT=$("$RUNNER" no_such_suite 2>&1)
RC=$?
assert_eq "$RC" "1" "no match: exit 1"
assert_contains "$OUT" "no suites matched" "no match: names the condition"
if [[ "$OUT" == *"ALL SUITES PASSED"* ]]; then
  echo -e "  ${RED}✗${NC} no match: must not print a false-green ALL SUITES PASSED"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} no match: no false-green ALL SUITES PASSED"
fi

finish
