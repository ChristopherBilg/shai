#!/bin/bash
# test_pr_review.sh — unit tests for workflows/pr_review.sh
# Covers: workflows/pr_review.sh — arg parsing, prompt loading, LLM dispatch
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/pr_review.sh"

make_stub_bin
write_gh_stub

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

# --- usage error: no arguments ---
OUT=$("$DIR/workflows/pr_review.sh" 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_review: exit 2 with no arguments"
assert_contains "$OUT" "Usage" "pr_review: prints usage on no args"

# --- usage error: non-numeric PR number ---
OUT=$("$DIR/workflows/pr_review.sh" abc 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_review: exit 2 on non-numeric PR number"
assert_contains "$OUT" "positive integer" "pr_review: error names the constraint"

# --- usage error: unknown option ---
OUT=$("$DIR/workflows/pr_review.sh" 42 --bad 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_review: exit 2 on unknown option"

# --- success case: valid assistant response ---
printf '{"type":"message","content":[{"type":"text","text":"Review complete."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

OUT=$("$DIR/workflows/pr_review.sh" 42 --repo owner/repo 2>&1)
RC=$?
assert_eq "$RC" "0" "pr_review: exit 0 on valid assistant response"
assert_contains "$OUT" "reviewed PR #42" "pr_review: output includes PR number"
assert_contains "$OUT" "owner/repo" "pr_review: output includes repo"

# --- fail case: error response from API ---
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

OUT=$("$DIR/workflows/pr_review.sh" 42 --repo owner/repo 2>&1)
RC=$?
assert_eq "$RC" "1" "pr_review: exit 1 on error response"
assert_contains "$OUT" "ERROR" "pr_review: prints ERROR on failure"

finish
