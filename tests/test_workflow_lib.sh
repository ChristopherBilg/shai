#!/bin/bash
# test_workflow_lib.sh — unit tests for lib/workflow.sh
# Covers: lib/workflow.sh — wf_init, wf_llm, wf_output, wf_fail, wf_seen, wf_mark
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/workflow.sh"

make_stub_bin
write_gh_stub

# --- wf_init: mints session, creates log, seeds system prompt ---
TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
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

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"llm reply"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
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
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/lib/workflow.sh" "$FIX/lib/"
# shellcheck disable=SC2031
cp "$DIR/shai-prompt" "$DIR/shai-read" "$DIR/shai-stamp" "$FIX/"
# shellcheck disable=SC2031
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

# --- wf_seen/wf_mark: per-workflow idempotency ledger ---
TMP_LEDGER1="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_LEDGER1")

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this test case
(
  export SHAI_HOME="$TMP_LEDGER1"
  WF_NAME="test-ledger"
  source "$DIR/lib/workflow.sh"
  wf_init

  # unseen key (no ledger file yet)
  wf_seen "pr:owner/repo:42" && SEEN=0 || SEEN=$?
  assert_eq "$SEEN" "1" "wf_seen: returns 1 for unseen key (no ledger)"

  # mark a key
  wf_mark "pr:owner/repo:42"

  # now it should be seen
  wf_seen "pr:owner/repo:42" && SEEN=0 || SEEN=$?
  assert_eq "$SEEN" "0" "wf_seen: returns 0 after wf_mark"

  # different key still unseen
  wf_seen "pr:owner/repo:99" && SEEN=0 || SEEN=$?
  assert_eq "$SEEN" "1" "wf_seen: returns 1 for different key"

  # double mark is idempotent
  wf_mark "pr:owner/repo:42"
  LINE_COUNT=$(wc -l <"$SHAI_HOME/ledgers/test-ledger.jsonl" | tr -d ' ')
  assert_eq "$LINE_COUNT" "1" "wf_mark: double mark produces exactly one line"

  # ledger entry is valid JSONL with correct fields
  ENTRY=$(cat "$SHAI_HOME/ledgers/test-ledger.jsonl")
  KEY=$(printf '%s' "$ENTRY" | jq -r '.key')
  TS=$(printf '%s' "$ENTRY" | jq -r '.ts')
  SID=$(printf '%s' "$ENTRY" | jq -r '.session_id')
  assert_eq "$KEY" "pr:owner/repo:42" "wf_mark: ledger entry has correct key"
  assert_eq "$(printf '%s' "$TS" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1" \
    "wf_mark: ledger entry has ISO timestamp"
  assert_eq "$SID" "$SHAI_SESSION_ID" "wf_mark: ledger entry has session_id"

  exit "$FAILED"
) || FAILED=1

# --- wf_seen/wf_mark: separate WF_NAME → separate files ---
TMP_LEDGER2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_LEDGER2")

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this test case
(
  export SHAI_HOME="$TMP_LEDGER2"
  source "$DIR/lib/workflow.sh"
  wf_init

  WF_NAME="workflow-a"
  wf_mark "item:1"
  WF_NAME="workflow-b"
  wf_mark "item:2"

  assert_eq "$(test -f "$SHAI_HOME/ledgers/workflow-a.jsonl" && echo exists)" "exists" \
    "wf_mark: workflow-a gets its own ledger"
  assert_eq "$(test -f "$SHAI_HOME/ledgers/workflow-b.jsonl" && echo exists)" "exists" \
    "wf_mark: workflow-b gets its own ledger"

  WF_NAME="workflow-a"
  wf_seen "item:2" && SEEN=0 || SEEN=$?
  assert_eq "$SEEN" "1" "wf_seen: workflow-a cannot see workflow-b keys"

  exit "$FAILED"
) || FAILED=1

finish
