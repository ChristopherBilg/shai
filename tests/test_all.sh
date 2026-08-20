#!/bin/bash
# test_all.sh — checks the aggregate runner: stage order, aggregation, and lint gating
# Covers: tests/all.sh — stage list/order, PASSED/FAILED banners, exit status, lint skip when ./bin is empty
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "all"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")

# all.sh derives RUN_DIR from its own location, so running a copy inside a fixture exercises the
# real script against stub stages: no repo checks execute and the suite stays offline/hermetic.
FIX_TESTS="$FIX/tests"
mkdir -p "$FIX_TESTS"
cp "$DIR/tests/all.sh" "$FIX_TESTS/all.sh"

ORDER_LOG="$FIX/order.log"
: >"$ORDER_LOG"

# stub_stage <basename> <exit_code>: a fake stage that records its run and exits with $code.
stub_stage() {
  local name="$1" code="$2"
  {
    printf '#!/bin/bash\n'
    printf 'echo "%s" >>"%s"\n' "$name" "$ORDER_LOG"
    printf 'exit %s\n' "$code"
  } >"$FIX_TESTS/$name"
  chmod +x "$FIX_TESTS/$name"
}

STAGES=(run.sh conventions.sh docs.sh tools-sync.sh constants-sync.sh doctor-sync.sh validate-tool-schema.sh)
for s in "${STAGES[@]}"; do stub_stage "$s" 0; done
stub_stage lint.sh 0

# The lint stage runs only when the pinned binaries are in ./bin (the fixture's repo root).
mkdir -p "$FIX/bin"
printf '#!/bin/bash\nexit 0\n' >"$FIX/bin/shellcheck"
printf '#!/bin/bash\nexit 0\n' >"$FIX/bin/shfmt"
chmod +x "$FIX/bin/shellcheck" "$FIX/bin/shfmt"

EXPECTED_ORDER="$(printf '%s\n' run.sh conventions.sh docs.sh tools-sync.sh constants-sync.sh doctor-sync.sh validate-tool-schema.sh lint.sh)"
EXPECTED_ORDER_NO_LINT="$(printf '%s\n' run.sh conventions.sh docs.sh tools-sync.sh constants-sync.sh doctor-sync.sh validate-tool-schema.sh)"

desc "all stages pass with ./bin populated"
OUT="$(bash "$FIX_TESTS/all.sh" 2>&1)"
RC=$?
assert_eq "$RC" "0" "all pass → exit 0"
assert_contains "$OUT" "ALL SUITES PASSED" "clean run prints the ALL SUITES PASSED banner"
assert_contains "$OUT" "(8)" "banner counts all 8 stages (7 checkers + lint)"
assert_eq "$(cat "$ORDER_LOG")" "$EXPECTED_ORDER" "stages run in CI order with lint last"

desc "a failing stage fails the aggregate"
: >"$ORDER_LOG"
stub_stage docs.sh 1
OUT="$(bash "$FIX_TESTS/all.sh" 2>&1)"
RC=$?
assert_eq "$RC" "1" "one failure → exit 1"
assert_contains "$OUT" "1/8 SUITES FAILED" "banner reports 1/8"
assert_eq "$(cat "$ORDER_LOG")" "$EXPECTED_ORDER" "later stages still run after a failure"

desc "lint is skipped with a visible notice when ./bin is not populated"
: >"$ORDER_LOG"
stub_stage docs.sh 0
rm -rf "${FIX:?}/bin"
OUT="$(bash "$FIX_TESTS/all.sh" 2>&1)"
RC=$?
assert_eq "$RC" "0" "missing ./bin → aggregate still exits 0"
assert_contains "$OUT" "lint skipped" "skip is announced visibly"
assert_contains "$OUT" "ALL SUITES PASSED" "banner still prints"
assert_contains "$OUT" "(7)" "only the 7 non-lint stages are counted"
assert_eq "$(cat "$ORDER_LOG")" "$EXPECTED_ORDER_NO_LINT" "lint did not run"

finish
