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
  exit "$FAILED"
) || FAILED=1

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

# --- WF_NAME: auto-derived from parent directory of the sourcing script ---
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/workflows/my_workflow" "$FIX/lib" "$FIX/prompts"
cp "$DIR/lib/workflow.sh" "$FIX/lib/"
cp "$DIR/shai-prompt" "$DIR/shai-read" "$DIR/shai-stamp" "$FIX/"
cp "$DIR/prompts/system.txt" "$FIX/prompts/"
chmod +x "$FIX"/shai-*
cat >"$FIX/workflows/my_workflow/run.sh" <<'FIXTURE'
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/../../lib/workflow.sh"
printf '%s\n' "$WF_NAME"
FIXTURE
chmod +x "$FIX/workflows/my_workflow/run.sh"

# shellcheck disable=SC2030,SC2031
DERIVED_NAME=$(
  export SHAI_HOME="$TMP"
  "$FIX/workflows/my_workflow/run.sh"
)
assert_eq "$DERIVED_NAME" "my_workflow" "WF_NAME: auto-derived from parent directory name"

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
