#!/bin/bash
# test_failures.sh — unit tests for lib/failure.sh
# Covers: fail_record — JSONL schema, per-workflow files, workflow-name resolution,
#         failures/ dir creation, invalid/non-object-context fallback, never-fail invariant
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/failure.sh"

# Each block runs in a subshell that exports its own SHAI_HOME and pins the
# workflow-resolution env vars, so cases never leak into each other.
# All absence/null/zero assertions below were mutation-checked: breaking the code they
# target (dropping a field, writing "" instead of null, returning 1 on append/mkdir/jq
# failure, dropping the raw fallback or the non-object wrap, reordering the resolution
# chain) turns each one red.

# --- basic record: all fields, valid JSONL, per-workflow file ---
desc "basic record: all fields in the per-workflow file"
TMP_BASIC="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_BASIC")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_BASIC"
  export SHAI_RUN_ID="run_1724512200_abc123"
  export SHAI_SESSION_ID="sess_1724512200_def456"
  WF_NAME="pr_reviewer"
  unset SHAI_FAILURE_WORKFLOW
  source "$DIR/lib/failure.sh"
  fail_record "api_error" "HTTP 503 from Deepseek API" \
    '{"script":"shai-eval","stage":"chat_completions","detail":"curl exit 0, HTTP 503 Service Unavailable"}'
  exit "$FAILED"
) || FAILED=1

REC="$TMP_BASIC/failures/pr_reviewer.jsonl"
assert_eq "$(test -d "$TMP_BASIC/failures" && echo dir)" "dir" \
  "fail_record: failures/ directory created on first write"
assert_eq "$(test -f "$REC" && echo exists)" "exists" \
  "fail_record: wrote the per-workflow file"
LINE="$(cat "$REC")"
assert_eq "$(printf '%s' "$LINE" | jq -r 'type')" "object" "fail_record: record is a JSON object"
assert_eq "$(printf '%s' "$LINE" | jq 'keys | length')" "7" \
  "fail_record: exactly the seven schema fields"
assert_eq "$(printf '%s' "$LINE" | jq -r '.workflow')" "pr_reviewer" \
  "fail_record: workflow field"
assert_eq "$(printf '%s' "$LINE" | jq -r '.run_id')" "run_1724512200_abc123" \
  "fail_record: run_id field"
assert_eq "$(printf '%s' "$LINE" | jq -r '.session_id')" "sess_1724512200_def456" \
  "fail_record: session_id field"
assert_eq "$(printf '%s' "$LINE" | jq -r '.category')" "api_error" \
  "fail_record: category field"
assert_eq "$(printf '%s' "$LINE" | jq -r '.summary')" "HTTP 503 from Deepseek API" \
  "fail_record: summary field"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context | type')" "object" \
  "fail_record: context is an object"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context.stage')" "chat_completions" \
  "fail_record: context preserved"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context.detail')" \
  "curl exit 0, HTTP 503 Service Unavailable" "fail_record: context detail"
assert_eq "$(printf '%s' "$LINE" | jq -r '.ts | type')" "string" \
  "fail_record: ts is a string"
assert_eq "$(printf '%s' "$LINE" | jq -r '.ts' | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1" \
  "fail_record: ts is ISO 8601"

# --- append: a second record adds a second valid JSONL line ---
desc "append: second record adds a second line"
TMP_APP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_APP2")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_APP2"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "tool_error" "first"
  fail_record "tool_error" "second"
  exit "$FAILED"
) || FAILED=1
assert_eq "$(wc -l <"$TMP_APP2/failures/_manual.jsonl" | tr -d ' ')" "2" \
  "append: two records, two lines"
assert_eq "$(jq -s 'length' "$TMP_APP2/failures/_manual.jsonl")" "2" \
  "append: both lines are valid JSON"
assert_eq "$(jq -sr '.[1].summary' "$TMP_APP2/failures/_manual.jsonl")" "second" \
  "append: second record preserved"

# --- workflow resolution: WF_NAME wins over SHAI_FAILURE_WORKFLOW ---
desc "resolution: WF_NAME beats SHAI_FAILURE_WORKFLOW"
TMP_RES1="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_RES1")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_RES1"
  export WF_NAME="wf_from_name"
  export SHAI_FAILURE_WORKFLOW="wf_from_env"
  unset SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "workflow_error" "pre-pipeline failure"
  exit "$FAILED"
) || FAILED=1
assert_eq "$(test -f "$TMP_RES1/failures/wf_from_name.jsonl" && echo exists)" "exists" \
  "resolution: WF_NAME file written"
[ ! -f "$TMP_RES1/failures/wf_from_env.jsonl" ] && ABSENT=yes || ABSENT=no
assert_eq "$ABSENT" "yes" "resolution: SHAI_FAILURE_WORKFLOW not used when WF_NAME set"

# --- workflow resolution: SHAI_FAILURE_WORKFLOW when WF_NAME unset ---
desc "resolution: SHAI_FAILURE_WORKFLOW when WF_NAME unset"
TMP_RES2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_RES2")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_RES2"
  export SHAI_FAILURE_WORKFLOW="wf_from_env"
  unset WF_NAME SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "workflow_error" "pre-pipeline failure"
  exit "$FAILED"
) || FAILED=1
assert_eq "$(test -f "$TMP_RES2/failures/wf_from_env.jsonl" && echo exists)" "exists" \
  "resolution: SHAI_FAILURE_WORKFLOW file written when WF_NAME unset"

# --- workflow resolution: _repl when only SHAI_SESSION_ID is set ---
desc "resolution: _repl when only SHAI_SESSION_ID is set"
TMP_RES3="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_RES3")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_RES3"
  export SHAI_SESSION_ID="sess_repl_case"
  unset WF_NAME SHAI_FAILURE_WORKFLOW
  source "$DIR/lib/failure.sh"
  fail_record "api_error" "repl failure"
  exit "$FAILED"
) || FAILED=1
assert_eq "$(test -f "$TMP_RES3/failures/_repl.jsonl" && echo exists)" "exists" \
  "resolution: _repl file written when only session id set"
assert_eq "$(jq -r '.session_id' "$TMP_RES3/failures/_repl.jsonl")" "sess_repl_case" \
  "resolution: _repl record carries the session id"

# --- workflow resolution: _manual when nothing is set ---
desc "resolution: _manual when nothing is set"
TMP_RES4="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_RES4")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_RES4"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "tool_error" "manual failure"
  exit "$FAILED"
) || FAILED=1
assert_eq "$(test -f "$TMP_RES4/failures/_manual.jsonl" && echo exists)" "exists" \
  "resolution: _manual file written when nothing set"

# --- null run_id/session_id when the env vars are unset ---
desc "null run_id/session_id when env vars unset"
TMP_NULL="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_NULL")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_NULL"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_RUN_ID SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "tool_error" "tool failed"
  exit "$FAILED"
) || FAILED=1
LINE="$(cat "$TMP_NULL/failures/_manual.jsonl")"
assert_eq "$(printf '%s' "$LINE" | jq 'has("run_id") and .run_id == null')" "true" \
  "fail_record: run_id null (not empty, not absent) when unset"
assert_eq "$(printf '%s' "$LINE" | jq 'has("session_id") and .session_id == null')" "true" \
  "fail_record: session_id null (not empty, not absent) when unset"

# --- context_json omitted: defaults to {} ---
desc "default context: {} when context_json omitted"
TMP_DEF="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_DEF")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_DEF"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "policy_denial" "policy denied tool"
  exit "$FAILED"
) || FAILED=1
LINE="$(cat "$TMP_DEF/failures/_manual.jsonl")"
assert_eq "$(printf '%s' "$LINE" | jq '.context')" "{}" \
  "fail_record: context defaults to {}"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context | type')" "object" \
  "fail_record: default context is an object"

# --- invalid context_json: replaced with {"raw": ...}, record never dropped ---
desc "invalid context_json: raw fallback, record still written"
TMP_INV="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_INV")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_INV"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "dispatch_error" "dispatch exited 3" '{"script":"shai-dispatch", detail: oops}'
  exit "$FAILED"
) || FAILED=1
LINE="$(cat "$TMP_INV/failures/_manual.jsonl")"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context | type')" "object" \
  "invalid context: fallback context is an object"
assert_eq "$(printf '%s' "$LINE" | jq '.context | keys | length')" "1" \
  "invalid context: fallback has exactly the raw key"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context.raw')" \
  '{"script":"shai-dispatch", detail: oops}' \
  "invalid context: raw holds the original text"
assert_eq "$(printf '%s' "$LINE" | jq -r '.category')" "dispatch_error" \
  "invalid context: record still written with its category"

# --- non-object context_json: valid JSON that is not an object -> {"raw": ...} ---
# Mutation-checked: replacing the type guard with a bare `context: $context` turns the
# first two assertions below red.
desc "non-object context_json: raw fallback, record still written"
TMP_NOBJ="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_NOBJ")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_NOBJ"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  fail_record "tool_error" "non-object context" '42'
  exit "$FAILED"
) || FAILED=1
LINE="$(cat "$TMP_NOBJ/failures/_manual.jsonl")"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context | type')" "object" \
  "non-object context: context stays an object"
assert_eq "$(printf '%s' "$LINE" | jq -r '.context.raw')" "42" \
  "non-object context: value wrapped as raw"
assert_eq "$(printf '%s' "$LINE" | jq '.context | keys | length')" "1" \
  "non-object context: fallback has exactly the raw key"
assert_eq "$(printf '%s' "$LINE" | jq -r '.category')" "tool_error" \
  "non-object context: record still written with its category"

# --- append failure: warns on stderr, returns 0 (never-fail invariant) ---
desc "append failure: warns on stderr, returns 0"
TMP_APP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_APP")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_APP"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  mkdir -p "$SHAI_HOME/failures"
  mkdir "$SHAI_HOME/failures/_manual.jsonl" # a directory blocks the append
  ERR="$(fail_record "tool_error" "cannot append" 2>&1)"
  RC="$?"
  assert_eq "$RC" "0" "append failure: fail_record returns 0"
  assert_contains "$ERR" "fail_record" "append failure: warning names fail_record on stderr"
  exit "$FAILED"
) || FAILED=1

# --- failures/ creation failure: warns on stderr, returns 0 (never-fail invariant) ---
desc "failures/ creation failure: warns on stderr, returns 0"
TMP_MK="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_MK")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_MK/blocker" # a file sits where the failures/ dir would go
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  source "$DIR/lib/failure.sh"
  printf 'x' >"$TMP_MK/blocker"
  ERR="$(fail_record "tool_error" "cannot create dir" 2>&1)"
  RC="$?"
  assert_eq "$RC" "0" "mkdir failure: fail_record returns 0"
  assert_contains "$ERR" "fail_record" "mkdir failure: warning names fail_record on stderr"
  exit "$FAILED"
) || FAILED=1

finish
