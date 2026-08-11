#!/bin/bash
# test_doctor.sh — unit tests for shai-doctor
# Covers: shai-doctor — CLI tool detection, env var checks, output format, exit codes
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-doctor"

# Helper: run shai-doctor in a subshell with a controlled command-v override.
# Usage: run_doctor [FAIL_TOOLS...] — tools listed here will appear missing.
run_doctor() {
  local fail_list=("$@")
  (
    # Override the 'command' builtin so check_tool's `command -v` is controlled.
    # shellcheck disable=SC2317  # invoked from inside the dynamically-sourced shai-doctor, not visible to static analysis
    command() {
      if [ "$1" = "-v" ]; then
        local t
        for t in "${fail_list[@]}"; do
          if [ "$2" = "$t" ]; then return 1; fi
        done
        # Every tool not explicitly failed is reported present — never fall through to the
        # real builtin here, or the host's actual tool availability (e.g. no systemd on
        # macOS / minimal CI containers) would leak into the test and break exact counts.
        return 0
      else
        builtin command "$@"
      fi
    }
    export -f command 2>/dev/null || true
    source "$DIR/shai-doctor" 2>&1
  )
}

# --- Test 1: all checks pass ---
export ANTHROPIC_API_KEY="test-key"
export JIRA_BASE_URL="https://test.atlassian.net"
export JIRA_USER_EMAIL="test@example.com"
export JIRA_API_TOKEN="test-token"

OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: all pass → exit 0"
assert_contains "$OUT" "[OK]" "doctor: at least one OK in output"
if [[ "$OUT" == *"[FAIL]"* ]]; then
  assert_eq "found-fail" "no-fail" "doctor: no FAIL markers when all present"
else
  assert_eq "0" "0" "doctor: no FAIL markers when all present"
fi

# --- Test 2: core tool missing (jq) → exit 1 + FAIL ---
OUT=$(run_doctor jq)
RC=$?
assert_eq "$RC" "1" "doctor: missing core tool → exit 1"
assert_contains "$OUT" "[FAIL]" "doctor: missing jq shows FAIL"
assert_contains "$OUT" "jq" "doctor: FAIL line names jq"

# --- Test 3: conditional tool missing (gh) → exit 0 + WARN ---
OUT=$(run_doctor gh)
RC=$?
assert_eq "$RC" "0" "doctor: missing conditional tool → exit 0"
assert_contains "$OUT" "[WARN]" "doctor: missing gh shows WARN"

# --- Test 4: core env var missing (ANTHROPIC_API_KEY) → exit 1 + FAIL ---
(
  unset ANTHROPIC_API_KEY
  OUT=$(run_doctor)
  RC=$?
  assert_eq "$RC" "1" "doctor: missing ANTHROPIC_API_KEY → exit 1"
  assert_contains "$OUT" "[FAIL]" "doctor: missing API key shows FAIL"
  assert_contains "$OUT" "ANTHROPIC_API_KEY" "doctor: FAIL line names the var"
)

# --- Test 5: conditional env var missing (JIRA_BASE_URL) → exit 0 + WARN with hint ---
(
  unset JIRA_BASE_URL
  OUT=$(run_doctor)
  RC=$?
  assert_eq "$RC" "0" "doctor: missing JIRA var → exit 0"
  assert_contains "$OUT" "[WARN]" "doctor: missing JIRA var shows WARN"
  assert_contains "$OUT" "(needed by: jira_issue_view)" "doctor: JIRA WARN includes hint"
)

# --- Test 6: summary line accuracy ---
(
  unset JIRA_BASE_URL
  unset JIRA_USER_EMAIL
  OUT=$(run_doctor jq gh)
  assert_contains "$OUT" "1 error" "doctor: summary counts 1 error (jq)"
  assert_contains "$OUT" "3 warning" "doctor: summary counts 3 warnings (gh + 2 JIRA vars)"
)

finish
