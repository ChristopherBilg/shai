#!/bin/bash
# test_sleep.sh — unit tests for tools/sleep/run.sh
# Covers: tools/sleep/run.sh — input validation, range enforcement, success path
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools/sleep/run.sh"

TOOL="$DIR/tools/sleep/run.sh"

# --- valid input ---
desc "valid input"
OUT=$("$TOOL" '{"seconds":1}')
RC=$?
assert_eq "$RC" "0" "sleep: exit 0 on valid input"
assert_contains "$OUT" "slept 1s" "sleep: output confirms elapsed time"

# --- invalid: non-integer ---
desc "invalid input"
OUT=$("$TOOL" '{"seconds":"abc"}' 2>&1) || true
assert_contains "$OUT" "between 1 and 300" "sleep: error on non-integer"

assert_exit 1 "sleep: exit 1 on non-integer" -- "$TOOL" '{"seconds":"abc"}'

# --- invalid: zero ---
assert_exit 1 "sleep: exit 1 on zero" -- "$TOOL" '{"seconds":0}'

# --- invalid: negative ---
assert_exit 1 "sleep: exit 1 on negative" -- "$TOOL" '{"seconds":-5}'

# --- invalid: exceeds 300 ---
assert_exit 1 "sleep: exit 1 on seconds > 300" -- "$TOOL" '{"seconds":999}'

# --- invalid: decimal ---
assert_exit 1 "sleep: exit 1 on decimal" -- "$TOOL" '{"seconds":1.5}'

# --- invalid: missing key ---
assert_exit 1 "sleep: exit 1 on missing seconds key" -- "$TOOL" '{}'

# --- error message content ---
desc "error messages"
OUT=$("$TOOL" '{"seconds":999}' 2>&1) || true
assert_contains "$OUT" "between 1 and 300" "sleep: error message names the valid range"

finish
