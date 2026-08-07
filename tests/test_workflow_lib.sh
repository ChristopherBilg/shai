#!/bin/bash
# test_workflow_lib.sh — unit tests for lib/workflow.sh
# Covers: lib/workflow.sh — wf_init, wf_llm, wf_output, wf_fail
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/workflow.sh"

make_stub_bin
write_gh_stub

# --- wf_init: mints session, creates log, seeds system prompt ---
TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")

printf '{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

# shellcheck disable=SC2030,SC2031  # deliberate: each block scopes SHAI_HOME/DIR to its own subshell for test isolation
(
  export SHAI_HOME="$TMP"
  source "$DIR/lib/workflow.sh"
  wf_init
  assert_eq "$(test -n "$SHAI_SESSION_ID" && echo set)" "set" "wf_init: SHAI_SESSION_ID is set"
  assert_eq "$(test -f "$SHAI_HOME/sessions/$SHAI_SESSION_ID.jsonl" && echo exists)" "exists" \
    "wf_init: session log created"
  SYSEVT=$(jq -r '.source' "$SHAI_HOME/sessions/$SHAI_SESSION_ID.jsonl")
  assert_eq "$SYSEVT" "system" "wf_init: system prompt seeded in session log"
  assert_eq "$(test -n "$DIR" && echo set)" "set" "wf_init: DIR is set"
)

# --- wf_llm: delegates to shai-loop ---
TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP2")

printf '{"type":"message","content":[{"type":"text","text":"llm reply"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this test case
OUT=$(
  export SHAI_HOME="$TMP2"
  source "$DIR/lib/workflow.sh"
  wf_init
  wf_llm "say hello"
)
assert_contains "$OUT" 'llm reply' "wf_llm: returns shai-loop output"

# --- wf_output: structured line to stdout ---
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this test case
OUTMSG=$(
  export SHAI_HOME="$TMP"
  WF_NAME="test-wf"
  source "$DIR/lib/workflow.sh"
  wf_output "PR created: https://example.com"
)
assert_contains "$OUTMSG" "test-wf" "wf_output: includes workflow name"
assert_contains "$OUTMSG" "PR created" "wf_output: includes message"
assert_eq "$(printf '%s' "$OUTMSG" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1" \
  "wf_output: starts with ISO timestamp"

# --- wf_fail: stderr + exit non-zero ---
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this test case
FERR=$(
  export SHAI_HOME="$TMP"
  source "$DIR/lib/workflow.sh"
  wf_fail "something broke" 2>&1
) || FAIL_RC=$?
assert_eq "${FAIL_RC:-0}" "1" "wf_fail: exits 1"
assert_contains "$FERR" "something broke" "wf_fail: message on stderr"

finish
