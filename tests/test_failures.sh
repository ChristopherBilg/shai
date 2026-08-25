#!/bin/bash
# test_failures.sh — unit tests for lib/failure.sh and the failure write sites (#271)
# Covers: fail_record — JSONL schema, per-workflow files, workflow-name resolution,
#         failures/ dir creation, invalid/non-object-context fallback, never-fail invariant;
#         write sites — shai-loop api_error/dispatch_error, wf_fail workflow_error,
#         shai-dispatch tool_error/policy_denial, issue_dispatcher workflow_error
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

# --- jq failure: both encode invocations fail (broken jq on PATH), warns, returns 0 ---
# Mutation-checked: changing the else branch to `return 1` turns the RC assertion red.
desc "jq failure: warns on stderr, returns 0"
TMP_JQ="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_JQ")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_JQ"
  unset WF_NAME SHAI_FAILURE_WORKFLOW SHAI_SESSION_ID
  make_stub_bin
  printf '#!/bin/bash\nexit 1\n' >"$STUB/jq"
  chmod +x "$STUB/jq"
  source "$DIR/lib/failure.sh"
  ERR="$(fail_record "tool_error" "cannot encode" 2>&1)"
  RC="$?"
  assert_eq "$RC" "0" "jq failure: fail_record returns 0"
  assert_contains "$ERR" "fail_record" "jq failure: warning names fail_record on stderr"
  exit "$FAILED"
) || FAILED=1

# =====================================================================================
# Failure write sites (#271) — every failure type is recorded to the durable failure store
# instead of vanishing into stderr.
# =====================================================================================

# --- write site #1: shai-loop records api_error when the initial eval pass yields a system
#     error event (API/curl/parse failure), with the payload text as summary and
#     shai-eval/chat_completions context. SHAI_EVAL_RETRIES=0 keeps the 529 from sleeping
#     through its retry backoffs. ---
desc "write site: shai-loop records api_error on an eval error event"
TMP_LOOP_ERR="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_LOOP_ERR")
mkdir -p "$TMP_LOOP_ERR/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP_LOOP_ERR/sessions/test.jsonl"
: >"$TMP_LOOP_ERR/sessions/test.latest.json"
make_stub_bin
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

LOOP_ERR_OUT=$(printf 'hi' | SHAI_EVAL_RETRIES=0 SHAI_HOME="$TMP_LOOP_ERR" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
LOOP_ERR_RC=$?
assert_eq "$LOOP_ERR_RC" "0" "write site: shai-loop still exits 0 on an eval error (errors are events)"
assert_contains "$LOOP_ERR_OUT" '"type":"error"' "write site: error event still emitted to stdout"
LOOP_ERR_REC="$TMP_LOOP_ERR/failures/_repl.jsonl"
assert_eq "$(test -f "$LOOP_ERR_REC" && echo exists)" "exists" \
  "write site: api_error recorded in failures/_repl.jsonl (session-scoped workflow)"
assert_eq "$(jq -s 'length' "$LOOP_ERR_REC")" "1" \
  "write site: exactly one record (the api_error, no dispatch_error)"
assert_eq "$(jq -sr '.[0].category' "$LOOP_ERR_REC")" "api_error" \
  "write site: api_error category"
assert_eq "$(jq -sr '.[0].summary' "$LOOP_ERR_REC")" "overloaded" \
  "write site: api_error summary is the event's payload text"
assert_eq "$(jq -sr '.[0].context.script' "$LOOP_ERR_REC")" "shai-eval" \
  "write site: api_error context names shai-eval"
assert_eq "$(jq -sr '.[0].context.stage' "$LOOP_ERR_REC")" "chat_completions" \
  "write site: api_error context names the chat_completions stage"
assert_eq "$(jq -sr '.[0].session_id' "$LOOP_ERR_REC")" "test" \
  "write site: api_error record carries the session id"

# --- write site #4: shai-loop records dispatch_error when shai-dispatch exits 3 (the
#     missing-lib/read-only.sh fixture — the same one test_loop.sh uses for the exit-code
#     contract), before emitting the terminal error event. ---
desc "write site: shai-loop records dispatch_error on dispatch exit 3"
TMP_LOOP_DISP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_LOOP_DISP")
mkdir -p "$TMP_LOOP_DISP/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP_LOOP_DISP/sessions/test.jsonl"
: >"$TMP_LOOP_DISP/sessions/test.latest.json"

FAKE_LOOP="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE_LOOP")
cp "$DIR/shai-loop" "$DIR/shai-dispatch" "$DIR/shai-context" "$DIR/shai-eval" \
  "$DIR/shai-read" "$DIR/shai-stamp" "$DIR/shai-print" "$FAKE_LOOP/"
mkdir -p "$FAKE_LOOP/lib"
cp "$DIR/lib/failure.sh" "$FAKE_LOOP/lib/failure.sh"
chmod +x "$FAKE_LOOP"/shai-*

TOOLCALL_JSON='{"id":"chatcmpl-tc","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tl1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'
printf '%s\n' "$TOOLCALL_JSON" | write_curl_stub 200

# timeout guards the assertion itself: if the loop regressed into a re-eval spin, the suite
# fails fast instead of hanging.
LOOP_DISP_OUT=$(printf 'list' | timeout 30 env PATH="$STUB:$PATH" SHAI_HOME="$TMP_LOOP_DISP" SHAI_SESSION_ID=test "$FAKE_LOOP/shai-loop" 2>/dev/null)
LOOP_DISP_RC=$?
assert_eq "$LOOP_DISP_RC" "0" "write site: dispatch failure still stops the loop, exit 0"
assert_contains "$LOOP_DISP_OUT" 'shai-dispatch failed (exit 3)' \
  "write site: terminal error event still names dispatch exit 3"
LOOP_DISP_REC="$TMP_LOOP_DISP/failures/_repl.jsonl"
assert_eq "$(test -f "$LOOP_DISP_REC" && echo exists)" "exists" \
  "write site: dispatch_error recorded"
assert_eq "$(jq -s 'length' "$LOOP_DISP_REC")" "1" \
  "write site: exactly one record (the dispatch_error, no api_error)"
assert_eq "$(jq -sr '.[0].category' "$LOOP_DISP_REC")" "dispatch_error" \
  "write site: dispatch_error category"
assert_contains "$(jq -sr '.[0].summary' "$LOOP_DISP_REC")" "shai-dispatch exited 3" \
  "write site: dispatch_error summary names the exit code"

# --- write site #2: wf_fail records workflow_error (script + message context) before
#     exiting 1, in the WF_NAME file. ---
desc "write site: wf_fail records workflow_error before exit 1"
TMP_WF_FAIL="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_WF_FAIL")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
WF_FAIL_OUT=$( (
  export SHAI_HOME="$TMP_WF_FAIL"
  export WF_NAME="wf_fail_case"
  source "$DIR/lib/workflow.sh"
  wf_fail "pre-pipeline boom" 2>&1
))
WF_FAIL_RC=$?
assert_eq "$WF_FAIL_RC" "1" "write site: wf_fail still exits 1"
assert_contains "$WF_FAIL_OUT" "pre-pipeline boom" "write site: wf_fail still prints the error on stderr"
WF_FAIL_REC="$TMP_WF_FAIL/failures/wf_fail_case.jsonl"
assert_eq "$(test -f "$WF_FAIL_REC" && echo exists)" "exists" \
  "write site: workflow_error recorded in the WF_NAME file"
assert_eq "$(jq -r '.category' "$WF_FAIL_REC")" "workflow_error" \
  "write site: workflow_error category"
assert_eq "$(jq -r '.summary' "$WF_FAIL_REC")" "pre-pipeline boom" \
  "write site: workflow_error summary is the message"
assert_eq "$(jq -r '.context.detail' "$WF_FAIL_REC")" "pre-pipeline boom" \
  "write site: workflow_error context detail is the message"
assert_eq "$(jq -r '.context.script | length > 0' "$WF_FAIL_REC")" "true" \
  "write site: workflow_error context script names the workflow script"

# --- write site #3d: shai-dispatch records tool_error when run.sh exits non-zero — tool,
#     first 500 bytes of input, and the exact exit code; the is_error tool_result and the
#     exit-code contract are unchanged. ---
desc "write site: shai-dispatch records tool_error on a non-zero run.sh exit"
TMP_TOOLERR="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_TOOLERR")
printf '{"version":"1.0","default":"allow","rules":[]}' >"$TMP_TOOLERR/policy.json"
PFNF_TOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"pf2",type:"function",function:{name:"patch_file",arguments:({path:"/nonexistent/file.txt",old_string:"x",new_string:"y"}|tojson)}}],finish_reason:"tool_calls"}}')
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
TOOLERR_OUT=$(printf '%s\n' "$PFNF_TOOL" | SHAI_HOME="$TMP_TOOLERR" SHAI_SESSION_ID=test "$DIR/shai-dispatch") || true
assert_contains "$TOOLERR_OUT" '"is_error":true' \
  "write site: failing tool still yields is_error true"
assert_contains "$TOOLERR_OUT" 'file not found' "write site: tool error message unchanged"
TOOLERR_REC="$TMP_TOOLERR/failures/_repl.jsonl"
assert_eq "$(test -f "$TOOLERR_REC" && echo exists)" "exists" \
  "write site: tool_error recorded"
assert_eq "$(jq -s 'length' "$TOOLERR_REC")" "1" "write site: exactly one record"
assert_eq "$(jq -sr '.[0].category' "$TOOLERR_REC")" "tool_error" \
  "write site: tool_error category"
assert_eq "$(jq -sr '.[0].context.tool' "$TOOLERR_REC")" "patch_file" \
  "write site: tool_error context names the tool"
assert_eq "$(jq -sr '.[0].context.exit_code' "$TOOLERR_REC")" "1" \
  "write site: tool_error context carries the run.sh exit code"
assert_contains "$(jq -sr '.[0].context.input' "$TOOLERR_REC")" '"path":"/nonexistent/file.txt"' \
  "write site: tool_error context carries the tool input"
assert_eq "$(jq -sr '.[0].context.input | length <= 500' "$TOOLERR_REC")" "true" \
  "write site: tool_error context input is capped at 500 bytes"

# --- write site #3a: shai-dispatch records policy_denial at a default-deny permission gate,
#     with the tool and the deciding policy reason (default:<file> here) as context. ---
desc "write site: shai-dispatch records policy_denial at a default-deny gate"
TMP_POLDENY="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_POLDENY")
printf '{"version":"1.0","default":"deny","rules":[]}' >"$TMP_POLDENY/policy.json"
DENY_TOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"d1",type:"function",function:{name:"list_directory",arguments:({path:"."}|tojson)}}],finish_reason:"tool_calls"}}')
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
POLDENY_OUT=$(printf '%s\n' "$DENY_TOOL" | SHAI_HOME="$TMP_POLDENY" SHAI_SESSION_ID=test "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$POLDENY_OUT" '"is_error":true' "write site: denial still yields is_error true"
assert_contains "$POLDENY_OUT" 'Policy denied' "write site: denial message unchanged"
POLDENY_REC="$TMP_POLDENY/failures/_repl.jsonl"
assert_eq "$(test -f "$POLDENY_REC" && echo exists)" "exists" \
  "write site: policy_denial recorded"
assert_eq "$(jq -sr '.[0].category' "$POLDENY_REC")" "policy_denial" \
  "write site: policy_denial category"
assert_eq "$(jq -sr '.[0].context.tool' "$POLDENY_REC")" "list_directory" \
  "write site: policy_denial context names the tool"
assert_contains "$(jq -sr '.[0].context.policy' "$POLDENY_REC")" "default:" \
  "write site: policy_denial context reason names the deciding default"
assert_contains "$(jq -sr '.[0].context.policy' "$POLDENY_REC")" "$TMP_POLDENY/policy.json" \
  "write site: policy_denial context reason names the deciding policy file"

# --- write site #5: issue_dispatcher records workflow_error on worker failure, in the
#     dispatcher's own failure file (via WF_NAME), with the worker name as context script. ---
desc "write site: issue_dispatcher records workflow_error on worker failure"
TMP_DISPATCHER="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_DISPATCHER")
# shellcheck disable=SC2030,SC2031  # deliberate: this block pins SHAI_HOME at file scope like test_issue_dispatcher.sh
export SHAI_HOME="$TMP_DISPATCHER"

make_stub_bin
WORKER_LOG="$TMP_DISPATCHER/worker.log"
WORKER_RC_FILE="$TMP_DISPATCHER/worker_rc"
echo 1 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
# args: run issue_worker <repo> <number>
if [ "\$1" = "run" ] && [ "\$2" = "issue_worker" ]; then
  printf '%s %s\n' "\$3" "\$4" >>"$WORKER_LOG"
fi
exit "\$(cat "$WORKER_RC_FILE")"
WFSTUB
chmod +x "$STUB/shai-workflow"
export SHAI_WORKFLOW="$STUB/shai-workflow"

SEARCH_FIXTURE="$TMP_DISPATCHER/search.json"
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search issues"*) cat "$SEARCH_FIXTURE" ;;
  *) echo "stub gh: \$*" ;;
esac
GHSTUB
chmod +x "$STUB/gh"

cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":77}]
JSON

# shellcheck disable=SC2030,SC2031  # deliberate: this block runs the dispatcher at file scope like test_issue_dispatcher.sh
DISPATCHER_OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
DISPATCHER_RC=$?
assert_eq "$DISPATCHER_RC" "1" "write site: dispatcher still exits 1 when all workers fail"
assert_contains "$DISPATCHER_OUT" "WARNING" "write site: dispatcher still warns on worker failure"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 77" "write site: failing worker still ran"
DISPATCHER_REC="$TMP_DISPATCHER/failures/issue_dispatcher.jsonl"
assert_eq "$(test -f "$DISPATCHER_REC" && echo exists)" "exists" \
  "write site: workflow_error recorded in the dispatcher's own failure file"
assert_eq "$(jq -sr '.[0].category' "$DISPATCHER_REC")" "workflow_error" \
  "write site: dispatcher workflow_error category"
assert_eq "$(jq -sr '.[0].context.script' "$DISPATCHER_REC")" "issue_worker" \
  "write site: dispatcher workflow_error context script names the worker"
assert_contains "$(jq -sr '.[0].summary' "$DISPATCHER_REC")" "owner/repo#77" \
  "write site: dispatcher workflow_error summary names the failed issue"
[ ! -f "$TMP_DISPATCHER/failures/issue_worker.jsonl" ] && NO_WORKER_FILE=yes || NO_WORKER_FILE=no
assert_eq "$NO_WORKER_FILE" "yes" \
  "write site: record does not land in a worker-named failure file"

# --- never-fail invariant at a write site: a blocked failures/ dir still lets wf_fail exit
#     1 with the original error on stderr (fail_record degrades to a warning). ---
desc "write site: blocked failures/ dir still lets wf_fail exit 1 with the original error"
TMP_WF_BLOCKED="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_WF_BLOCKED")
printf 'x' >"$TMP_WF_BLOCKED/failures" # a file sits where the failures/ dir would go
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
WF_BLOCKED_OUT=$( (
  export SHAI_HOME="$TMP_WF_BLOCKED"
  export WF_NAME="wf_fail_blocked"
  source "$DIR/lib/workflow.sh"
  wf_fail "original boom" 2>&1
))
WF_BLOCKED_RC=$?
assert_eq "$WF_BLOCKED_RC" "1" "write site: blocked failures/ dir → wf_fail still exits 1"
assert_contains "$WF_BLOCKED_OUT" "original boom" \
  "write site: blocked failures/ dir → original error still on stderr"
assert_contains "$WF_BLOCKED_OUT" "fail_record" \
  "write site: blocked failures/ dir → fail_record warns on stderr (never-fail invariant)"

finish
