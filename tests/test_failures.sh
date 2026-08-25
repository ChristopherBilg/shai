#!/bin/bash
# test_failures.sh — unit tests for lib/failure.sh and its write sites
# Covers: fail_record — JSONL schema, per-workflow files, workflow-name resolution,
#         failures/ dir creation, invalid/non-object-context fallback, never-fail invariant;
#         the five instrumented write sites — shai-loop (api_error, dispatch_error),
#         wf_fail (workflow_error), shai-dispatch (tool_error, policy_denial), and the
#         dispatchers' worker-failure WARNING sites (workflow_error)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/failure.sh + write sites"

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

# ============================ instrumented write sites ============================
# The wf_fail subshells below source lib/workflow.sh, which reassigns DIR (and the subshells
# export SHAI_HOME) in their own scopes; those scoped values never leak, so the top-level
# uses of DIR/SHAI_HOME after this point are unaffected (SC2031 suppressed per line below).

# --- write site: shai-loop records api_error when shai-eval emits an error event ---
desc "shai-loop: api_error recorded when shai-eval emits an error event"
make_stub_bin
TMP_API="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_API")
mkdir -p "$TMP_API/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP_API/sessions/test.jsonl"
: >"$TMP_API/sessions/test.latest.json"

printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

# SHAI_EVAL_RETRIES=0 skips shai-eval's transient-failure backoff sleeps
OUT=$(printf 'hi' | SHAI_HOME="$TMP_API" SHAI_SESSION_ID=test SHAI_EVAL_RETRIES=0 "$DIR/shai-loop" 2>/dev/null)
RC=$?
assert_eq "$RC" "0" "shai-loop: exit 0 even on eval error (errors are events, not crashes)"
assert_contains "$OUT" '"type":"error"' "shai-loop: stdout emits the error event"
API_REC="$TMP_API/failures/_repl.jsonl"
assert_eq "$(test -f "$API_REC" && echo exists)" "exists" \
  "shai-loop: api_error record written"
API_LINE="$(cat "$API_REC")"
assert_eq "$(printf '%s' "$API_LINE" | jq -r '.category')" "api_error" \
  "shai-loop: record category is api_error"
assert_eq "$(printf '%s' "$API_LINE" | jq -r '.workflow')" "_repl" \
  "shai-loop: record lands in _repl (SHAI_SESSION_ID set, no WF_NAME)"
assert_eq "$(printf '%s' "$API_LINE" | jq -r '.context.script')" "shai-eval" \
  "shai-loop: api_error context names shai-eval"
assert_contains "$(printf '%s' "$API_LINE" | jq -r '.summary')" "overloaded" \
  "shai-loop: api_error summary carries the eval error text"
assert_eq "$(printf '%s' "$API_LINE" | jq -r '.run_id' | grep -cE '^run_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$')" "1" \
  "shai-loop: api_error record carries the ambient minted run_id"

# --- write site: wf_fail records workflow_error before exiting ---
desc "wf_fail: workflow_error recorded, then exit 1"
TMP_WF="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_WF")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_WF"
  export WF_NAME="wf_fail_case"
  unset SHAI_SESSION_ID
  source "$DIR/lib/workflow.sh"
  ERR=$(wf_fail "gh search failed" 2>&1) && RC=0 || RC=$?
  assert_eq "$RC" "1" "wf_fail: exits 1"
  assert_contains "$ERR" "ERROR: gh search failed" "wf_fail: error message on stderr"
  exit "$FAILED"
) || FAILED=1
WF_REC="$TMP_WF/failures/wf_fail_case.jsonl"
assert_eq "$(test -f "$WF_REC" && echo exists)" "exists" \
  "wf_fail: record written to the workflow's own file"
WF_LINE="$(cat "$WF_REC")"
assert_eq "$(printf '%s' "$WF_LINE" | jq -r '.category')" "workflow_error" \
  "wf_fail: record category is workflow_error"
assert_eq "$(printf '%s' "$WF_LINE" | jq -r '.workflow')" "wf_fail_case" \
  "wf_fail: record workflow is WF_NAME"
assert_eq "$(printf '%s' "$WF_LINE" | jq -r '.summary')" "gh search failed" \
  "wf_fail: summary is the failure message"
assert_eq "$(printf '%s' "$WF_LINE" | jq -r '.context.detail')" "gh search failed" \
  "wf_fail: context detail is the failure message"

# --- write site: shai-dispatch records tool_error when a tool's run.sh exits nonzero ---
desc "shai-dispatch: tool_error recorded on tool run.sh nonzero exit"
TMP_TOOLERR="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_TOOLERR")
printf '{"version":"1.0","default":"allow","rules":[]}' >"$TMP_TOOLERR/policy.json"

TOOLERR_TOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"te1",type:"function",function:{name:"patch_file",arguments:({path:"/nonexistent/file.txt",old_string:"x",new_string:"y"}|tojson)}}],finish_reason:"tool_calls"}}')
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
echo "$TOOLERR_TOOL" | SHAI_HOME="$TMP_TOOLERR" "$DIR/shai-dispatch" >/dev/null 2>&1
assert_eq "$?" "1" "shai-dispatch: failing tool still exits 1 (tool ran → re-eval)"
TOOLERR_REC="$TMP_TOOLERR/failures/_manual.jsonl"
assert_eq "$(test -f "$TOOLERR_REC" && echo exists)" "exists" \
  "shai-dispatch: tool_error record written"
TOOLERR_LINE="$(cat "$TOOLERR_REC")"
assert_eq "$(printf '%s' "$TOOLERR_LINE" | jq -r '.category')" "tool_error" \
  "shai-dispatch: record category is tool_error"
assert_eq "$(printf '%s' "$TOOLERR_LINE" | jq -r '.context.tool')" "patch_file" \
  "shai-dispatch: tool_error context names the tool"
assert_eq "$(printf '%s' "$TOOLERR_LINE" | jq -r '.context.exit_code')" "1" \
  "shai-dispatch: tool_error context carries the exit code"
assert_contains "$(printf '%s' "$TOOLERR_LINE" | jq -r '.context.input')" "nonexistent" \
  "shai-dispatch: tool_error context carries the tool input"

# --- write site: shai-dispatch records policy_denial when the permission gate denies ---
desc "shai-dispatch: policy_denial recorded on permission gate deny"
TMP_DENY="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_DENY")
printf '{"version":"1.0","default":"deny","rules":[]}' >"$TMP_DENY/policy.json"

DENY_TOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"pd1",type:"function",function:{name:"gh",arguments:({args:["pr","view","1"]}|tojson)}}],finish_reason:"tool_calls"}}')
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
echo "$DENY_TOOL" | SHAI_HOME="$TMP_DENY" "$DIR/shai-dispatch" >/dev/null 2>&1
assert_eq "$?" "1" "shai-dispatch: denied tool still exits 1 (tool ran → re-eval)"
DENY_REC="$TMP_DENY/failures/_manual.jsonl"
assert_eq "$(test -f "$DENY_REC" && echo exists)" "exists" \
  "shai-dispatch: policy_denial record written"
DENY_LINE="$(cat "$DENY_REC")"
assert_eq "$(printf '%s' "$DENY_LINE" | jq -r '.category')" "policy_denial" \
  "shai-dispatch: record category is policy_denial"
assert_eq "$(printf '%s' "$DENY_LINE" | jq -r '.context.tool')" "gh" \
  "shai-dispatch: policy_denial context names the tool"
assert_contains "$(printf '%s' "$DENY_LINE" | jq -r '.context.policy')" "default:" \
  "shai-dispatch: policy_denial context names the deciding policy"

# --- write site: shai-loop records dispatch_error when shai-dispatch exits 3 ---
desc "shai-loop: dispatch_error recorded when shai-dispatch exits 3"
TMP_DISP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_DISP")
mkdir -p "$TMP_DISP/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP_DISP/sessions/test.jsonl"
: >"$TMP_DISP/sessions/test.latest.json"

# Mirror the repo layout minus lib/read-only.sh so shai-dispatch's pre-flight exits 3 (see
# #257); lib/failure.sh IS copied so shai-loop's own instrumentation can run in the fixture.
FAKE_INSTALL="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE_INSTALL")
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/shai-loop" "$DIR/shai-dispatch" "$DIR/shai-context" "$DIR/shai-eval" \
  "$DIR/shai-read" "$DIR/shai-stamp" "$DIR/shai-print" "$FAKE_INSTALL/"
mkdir -p "$FAKE_INSTALL/lib"
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/lib/failure.sh" "$FAKE_INSTALL/lib/"
chmod +x "$FAKE_INSTALL"/shai-*

TOOLCALL_JSON='{"id":"chatcmpl-tc","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tl1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'
printf '%s\n' "$TOOLCALL_JSON" | write_curl_stub 200

# timeout guards the assertion itself: if the loop fails to stop, the suite fails fast
DISP_OUT=$(printf 'list' | timeout 30 env PATH="$STUB:$PATH" SHAI_HOME="$TMP_DISP" SHAI_SESSION_ID=test "$FAKE_INSTALL/shai-loop" 2>/dev/null)
DISP_RC=$?
assert_eq "$DISP_RC" "0" "shai-loop: dispatch exit 3 → loop stops, exit 0"
assert_contains "$DISP_OUT" '"type":"error"' "shai-loop: dispatch failure → error event emitted"
DISP_REC="$TMP_DISP/failures/_repl.jsonl"
assert_eq "$(test -f "$DISP_REC" && echo exists)" "exists" \
  "shai-loop: dispatch_error record written"
DISP_LINE="$(cat "$DISP_REC")"
assert_eq "$(printf '%s' "$DISP_LINE" | jq -r '.category')" "dispatch_error" \
  "shai-loop: record category is dispatch_error"
assert_contains "$(printf '%s' "$DISP_LINE" | jq -r '.summary')" "exited 3" \
  "shai-loop: dispatch_error summary names the exit code"
assert_eq "$(printf '%s' "$DISP_LINE" | jq -r '.context.script')" "shai-dispatch" \
  "shai-loop: dispatch_error context names shai-dispatch"

# --- write site: issue_dispatcher records workflow_error when a worker fails ---
desc "issue_dispatcher: workflow_error recorded when a worker fails"
TMP_DISPATCHER="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_DISPATCHER")
# shellcheck disable=SC2031  # deliberate: SHAI_HOME is set by lib.sh at file scope, not lost
export SHAI_HOME="$TMP_DISPATCHER"

make_stub_bin
WORKER_RC_FILE="$TMP_DISPATCHER/worker_rc"
echo 1 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
exit "\$(cat "$WORKER_RC_FILE")"
WFSTUB
chmod +x "$STUB/shai-workflow"

SEARCH_FIXTURE="$TMP_DISPATCHER/search.json"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search issues"*) cat "$SEARCH_FIXTURE" ;;
  "issue edit"*) exit 0 ;;
  *) echo "stub gh: \$*" ;;
esac
GHSTUB
chmod +x "$STUB/gh"

# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
DISPATCHER_OUT=$(SHAI_WORKFLOW="$STUB/shai-workflow" "$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
DISPATCHER_RC=$?
assert_eq "$DISPATCHER_RC" "1" "issue_dispatcher: exit 1 when the worker fails"
assert_contains "$DISPATCHER_OUT" "WARNING" "issue_dispatcher: warns when the worker fails"
DISPATCHER_REC="$TMP_DISPATCHER/failures/issue_dispatcher.jsonl"
assert_eq "$(test -f "$DISPATCHER_REC" && echo exists)" "exists" \
  "issue_dispatcher: record written to the dispatcher's own file"
DISPATCHER_LINE="$(cat "$DISPATCHER_REC")"
assert_eq "$(printf '%s' "$DISPATCHER_LINE" | jq -r '.category')" "workflow_error" \
  "issue_dispatcher: record category is workflow_error"
assert_eq "$(printf '%s' "$DISPATCHER_LINE" | jq -r '.workflow')" "issue_dispatcher" \
  "issue_dispatcher: record workflow is the dispatcher name"
assert_eq "$(printf '%s' "$DISPATCHER_LINE" | jq -r '.summary')" "worker failed for owner/repo#42" \
  "issue_dispatcher: summary names the failed worker target"
assert_eq "$(printf '%s' "$DISPATCHER_LINE" | jq -r '.context.script')" "issue_worker" \
  "issue_dispatcher: context names the failed worker"

# --- never-fail invariant at a write site: recording failure does not mask the original ---
desc "write-site invariant: wf_fail still exits 1 when the failure store is unwritable"
TMP_WFBLOCK="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_WFBLOCK")
# shellcheck disable=SC2030,SC2031  # deliberate: subshell-scoped env vars isolate this case
(
  export SHAI_HOME="$TMP_WFBLOCK"
  export WF_NAME="wf_fail_blocked"
  unset SHAI_SESSION_ID
  printf 'x' >"$SHAI_HOME/failures" # a file blocks the failures/ directory
  source "$DIR/lib/workflow.sh"
  ERR=$(wf_fail "original failure" 2>&1) && RC=0 || RC=$?
  assert_eq "$RC" "1" "write-site invariant: wf_fail still exits 1"
  assert_contains "$ERR" "ERROR: original failure" \
    "write-site invariant: original error still on stderr"
  exit "$FAILED"
) || FAILED=1

finish
