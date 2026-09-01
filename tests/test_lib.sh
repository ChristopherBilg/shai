#!/bin/bash
# test_lib.sh — unit tests for the assertion helpers in tests/lib.sh
# Covers: assert_fails — empty-fragment usage error, command skipped, literal fragment match
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

finish
