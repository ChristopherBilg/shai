#!/bin/bash
# test_failures.sh — unit tests for lib/failure.sh, its write sites, and the shai-failures command
# Covers: fail_record — JSONL schema, per-workflow files, workflow-name resolution,
#         failures/ dir creation, invalid/non-object-context fallback, never-fail invariant;
#         the five instrumented write sites — shai-loop (api_error, dispatch_error),
#         wf_fail (workflow_error), shai-dispatch (tool_error, policy_denial), and the
#         dispatchers' worker-failure WARNING sites (workflow_error);
#         shai-failures list/show/summary — per-workflow and per-record listing, filters,
#         prefix matching, --json, malformed-line tolerance, show detail + trace hint,
#         summary aggregates with percentages, exit codes
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

# --- write site: shai-dispatch records policy_denial on a headless prompt-gate denial ---
# stderr is redirected to /dev/null so prompt_user's `[ -t 2 ]` headless check fails
# deterministically (the denial mode non-interactive workflows actually hit)
desc "shai-dispatch: policy_denial recorded on headless prompt-gate denial"
TMP_PROMPT="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_PROMPT")
printf '{"version":"1.0","default":"prompt","rules":[]}' >"$TMP_PROMPT/policy.json"

PROMPT_TOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"pp1",type:"function",function:{name:"gh",arguments:({args:["pr","view","1"]}|tojson)}}],finish_reason:"tool_calls"}}')
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
echo "$PROMPT_TOOL" | SHAI_HOME="$TMP_PROMPT" "$DIR/shai-dispatch" >/dev/null 2>&1
assert_eq "$?" "1" "shai-dispatch: headless prompt denial still exits 1 (tool ran → re-eval)"
PROMPT_REC="$TMP_PROMPT/failures/_manual.jsonl"
assert_eq "$(test -f "$PROMPT_REC" && echo exists)" "exists" \
  "shai-dispatch: headless prompt policy_denial record written"
PROMPT_LINE="$(cat "$PROMPT_REC")"
assert_eq "$(printf '%s' "$PROMPT_LINE" | jq -r '.category')" "policy_denial" \
  "shai-dispatch: headless prompt record category is policy_denial"
assert_eq "$(printf '%s' "$PROMPT_LINE" | jq -r '.context.tool')" "gh" \
  "shai-dispatch: headless prompt policy_denial context names the tool"
assert_contains "$(printf '%s' "$PROMPT_LINE" | jq -r '.context.policy')" "default:" \
  "shai-dispatch: headless prompt policy_denial context names the deciding policy"

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

TOOLCALL_JSON='{"id":"chatcmpl-tc","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tl1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'
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

# --- write site: shai-loop records dispatch_error when the dispatch loop bound is exceeded ---
# A stub shai-dispatch that always exits 1 ("a tool ran") would re-evaluate forever; a small
# SHAI_MAX_DISPATCH_ROUNDS caps the loop so the bound path is hit quickly.
desc "shai-loop: dispatch_error recorded when the dispatch loop bound is exceeded"
TMP_BOUND="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP_BOUND")
mkdir -p "$TMP_BOUND/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP_BOUND/sessions/test.jsonl"
: >"$TMP_BOUND/sessions/test.latest.json"

FAKE_INSTALL_BOUND="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE_INSTALL_BOUND")
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/shai-loop" "$DIR/shai-context" "$DIR/shai-eval" \
  "$DIR/shai-read" "$DIR/shai-stamp" "$DIR/shai-print" "$FAKE_INSTALL_BOUND/"
printf '#!/bin/bash\nexit 1\n' >"$FAKE_INSTALL_BOUND/shai-dispatch"
mkdir -p "$FAKE_INSTALL_BOUND/lib"
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/lib/failure.sh" "$FAKE_INSTALL_BOUND/lib/"
chmod +x "$FAKE_INSTALL_BOUND"/shai-*

printf '%s\n' "$TOOLCALL_JSON" | write_curl_stub 200

# timeout guards the assertion itself: if the bound fails to stop the loop, the suite fails fast
BOUND_OUT=$(printf 'list' | timeout 30 env PATH="$STUB:$PATH" SHAI_HOME="$TMP_BOUND" SHAI_SESSION_ID=test SHAI_MAX_DISPATCH_ROUNDS=2 "$FAKE_INSTALL_BOUND/shai-loop" 2>/dev/null)
BOUND_RC=$?
assert_eq "$BOUND_RC" "0" "shai-loop: loop bound → loop stops, exit 0"
assert_contains "$BOUND_OUT" '"type":"error"' "shai-loop: loop bound → error event emitted"
BOUND_REC="$TMP_BOUND/failures/_repl.jsonl"
assert_eq "$(test -f "$BOUND_REC" && echo exists)" "exists" \
  "shai-loop: loop-bound dispatch_error record written"
BOUND_LINE="$(cat "$BOUND_REC")"
assert_eq "$(printf '%s' "$BOUND_LINE" | jq -r '.category')" "dispatch_error" \
  "shai-loop: loop-bound record category is dispatch_error"
assert_contains "$(printf '%s' "$BOUND_LINE" | jq -r '.summary')" "exceeded 2 dispatch rounds" \
  "shai-loop: loop-bound summary names the bound"
assert_eq "$(printf '%s' "$BOUND_LINE" | jq -r '.context.script')" "shai-loop" \
  "shai-loop: loop-bound context names shai-loop"

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
  "api "*"/dependencies/blocked_by"*) echo '[]' ;;
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

# ============================ shai-failures command ============================
# All absence/null/zero assertions in this section were mutation-checked: breaking the
# code they target (dropping the top-category computation, the chronological sort, the
# trace hint, the run/session null-omission, the zero-row skip, the empty-array path,
# the physical-line id mapping) turns each one red.

# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
FAILURES="$DIR/shai-failures"

# setup_failures: fresh SHAI_HOME with a failures/ dir for the command tests.
setup_failures() {
  # shellcheck disable=SC2031  # deliberate: SHAI_HOME is set by lib.sh at file scope, not lost
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/failures"
}

# make_failure <workflow> <ts> <category> <summary> [run_id] [session_id] [context_json]
# Appends one record exactly as fail_record writes it (seven schema fields; empty
# run_id/session_id become null).
make_failure() {
  local workflow="$1" ts="$2" category="$3" summary="$4"
  local run_id="${5:-}" sid="${6:-}" ctx="${7:-}"
  # NOTE: no `${7:-{}}` default — bash ends the expansion at the first `}`, so the
  # default would be `{` plus a stray literal `}` appended to a set $7 (a trap this
  # suite hit while bootstrapping). Assign then normalize instead.
  [ -n "$ctx" ] || ctx="{}"
  local rec
  rec=$(jq -nc --arg ts "$ts" --arg wf "$workflow" --arg cat "$category" \
    --arg summary "$summary" --arg run_id "$run_id" --arg sid "$sid" --argjson ctx "$ctx" '
      def nullable: if . == "" then null else . end;
      {ts: $ts, workflow: $wf, run_id: ($run_id | nullable),
       session_id: ($sid | nullable), category: $cat, summary: $summary, context: $ctx}')
  printf '%s\n' "$rec" >>"$SHAI_HOME/failures/$workflow.jsonl"
}

# --- list summary mode: per-workflow counts, date range, top category ---
desc "list: per-workflow counts, date range, top category"
setup_failures
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
make_failure issue_worker 2026-08-21T09:00:00Z api_error "HTTP 502"
make_failure issue_worker 2026-08-23T09:00:00Z tool_error "patch_file failed"
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed: HTTP 502"
make_failure _repl 2026-08-19T10:00:00Z tool_error "ls failed"
make_failure _repl 2026-08-24T10:00:00Z api_error "overloaded"

OUT=$("$FAILURES" list --json)
assert_eq "$(printf '%s' "$OUT" | jq -r 'type')" "array" "list: --json is a JSON array"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "3" "list: three workflows"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].workflow')" "_repl" "list: rows sorted alphabetically by workflow"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].workflow')" "issue_worker" "list: second row by workflow name"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[2].workflow')" "pr_reviewer" "list: third row by workflow name"
IW="$(printf '%s' "$OUT" | jq -c '[.[] | select(.workflow == "issue_worker")][0]')"
assert_eq "$(printf '%s' "$IW" | jq -r '.failures')" "3" "list: issue_worker failure count"
assert_eq "$(printf '%s' "$IW" | jq -r '.oldest')" "2026-08-20T09:00:00Z" "list: oldest ts"
assert_eq "$(printf '%s' "$IW" | jq -r '.newest')" "2026-08-23T09:00:00Z" "list: newest ts"
assert_eq "$(printf '%s' "$IW" | jq -r '.top_category.category')" "api_error" "list: top category name"
assert_eq "$(printf '%s' "$IW" | jq -r '.top_category.count')" "2" "list: top category count"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.workflow == "pr_reviewer")][0].failures')" "1" "list: pr_reviewer failure count"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.[] | select(.workflow == "_repl")][0].top_category.category')" "api_error" "list: _repl top category (tie → alphabetical)"

OUT=$("$FAILURES" list)
assert_contains "$OUT" "WORKFLOW" "list: header present"
assert_contains "$OUT" "TOP CATEGORY" "list: top category header present"
assert_contains "$OUT" "api_error (2)" "list: human top category with count"
assert_contains "$OUT" "2026-08-20" "list: human oldest date"
assert_contains "$OUT" "2026-08-24" "list: human newest date"

# --- list per-workflow mode: chronological, ids are physical line numbers ---
desc "list --workflow: chronological per-record listing with physical-line ids"
setup_failures
make_failure issue_worker 2026-08-22T03:14:00Z workflow_error "gh pr view failed: HTTP 502" run_1724295240_abc123 sess_1724295240_def456 '{"script":"workflows/pr_reviewer/run.sh","detail":"gh pr view failed: HTTP 502"}'
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
make_failure issue_worker 2026-08-23T09:00:00Z tool_error "patch_file failed"

OUT=$("$FAILURES" list --workflow issue_worker --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "3" "list --workflow: three records"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].ts')" "2026-08-20T09:00:00Z" "list --workflow: chronological first"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].ts')" "2026-08-22T03:14:00Z" "list --workflow: chronological second"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[2].ts')" "2026-08-23T09:00:00Z" "list --workflow: chronological third"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].id')" "issue_worker:2" "list --workflow: id follows the physical line (2)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].id')" "issue_worker:1" "list --workflow: id follows the physical line (1)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].run_id')" "run_1724295240_abc123" "list --workflow: run_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].session_id')" "sess_1724295240_def456" "list --workflow: session_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].context.detail')" "gh pr view failed: HTTP 502" "list --workflow: context preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "null" "list --workflow: null run_id stays null"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].workflow')" "issue_worker" "list --workflow: workflow field"

OUT=$("$FAILURES" list --workflow issue_worker)
assert_contains "$OUT" "TIMESTAMP" "list --workflow: header present"
assert_contains "$OUT" "CATEGORY" "list --workflow: category header present"
assert_contains "$OUT" "gh pr view failed: HTTP 502" "list --workflow: summary shown"
assert_contains "$OUT" "run_1724295240_abc123" "list --workflow: run shown"
assert_contains "$OUT" "2026-08-22T03:14:00Z" "list --workflow: full timestamp shown"

# --- list filters: --after/--before/--category/--recent compose ---
desc "list filters: --after/--before/--category/--recent compose"
setup_failures
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
make_failure issue_worker 2026-08-21T09:00:00Z api_error "HTTP 502"
make_failure issue_worker 2026-08-23T09:00:00Z tool_error "patch_file failed"
make_failure issue_worker 2026-08-25T09:00:00Z tool_error "ls failed"

OUT=$("$FAILURES" list --workflow issue_worker --after 2026-08-21 --before 2026-08-24 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "filters: after+before narrow to two"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].category')" "api_error" "filters: earliest in window kept"

OUT=$("$FAILURES" list --workflow issue_worker --category tool_error --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "filters: category narrows"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.[] | .category] | unique | join(",")')" "tool_error" "filters: only the requested category"

OUT=$("$FAILURES" list --workflow issue_worker --category tool_error --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "filters: recent keeps last row"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].ts')" "2026-08-25T09:00:00Z" "filters: recent keeps the latest"

OUT=$("$FAILURES" list --workflow issue_worker --after 2026-08-22 --category tool_error --recent 5 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "filters: after+category+recent composed"

OUT=$("$FAILURES" list --recent 0 --json)
assert_eq "$OUT" "[]" "filters: --recent 0 yields nothing"

# summary-mode filters narrow the per-workflow rows too
OUT=$("$FAILURES" list --after 2026-08-22 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "filters: summary-mode window drops other workflows"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].workflow')" "issue_worker" "filters: only in-window workflow remains"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].failures')" "2" "filters: in-window failure count"

# --- list --workflow prefix matching ---
desc "list --workflow prefix: unambiguous resolves; ambiguous and no-match error"
setup_failures
make_failure issue_dispatcher 2026-08-20T09:00:00Z workflow_error "dispatch failed"
OUT=$("$FAILURES" list --workflow issue_d --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "prefix: unambiguous prefix resolves"

make_failure issue_worker 2026-08-21T09:00:00Z api_error "boom"
ERR=$("$FAILURES" list --workflow issue_ 2>&1 >/dev/null)
assert_fails 1 "error: ambiguous prefix \"issue_\"" "prefix: ambiguous exits 1" -- "$FAILURES" list --workflow issue_
assert_contains "$ERR" "ambiguous" "prefix: ambiguous message"
assert_contains "$ERR" "issue_dispatcher" "prefix: first candidate listed"
assert_contains "$ERR" "issue_worker" "prefix: second candidate listed"

ERR=$("$FAILURES" list --workflow nope 2>&1 >/dev/null)
assert_fails 1 "error: no match for \"nope\"" "prefix: no match exits 1" -- "$FAILURES" list --workflow nope
assert_contains "$ERR" "no match" "prefix: no-match message"

# --- list empty state ---
desc "list: empty failures dir — clean no-failures output, exit 0"
setup_failures
rm -rf "$SHAI_HOME/failures"
OUT=$("$FAILURES" list 2>/dev/null)
RC=$?
assert_eq "$RC" "0" "empty: exit 0"
assert_eq "$OUT" "" "empty: no output"
OUT=$("$FAILURES" list --json)
assert_eq "$OUT" "[]" "empty: --json empty array"

desc "list --workflow: empty file yields an empty array"
setup_failures
: >"$SHAI_HOME/failures/empty_wf.jsonl"
OUT=$("$FAILURES" list --workflow empty_wf --json)
assert_eq "$OUT" "[]" "empty file: --json empty array"

desc "list: workflow fully outside the date window is omitted"
setup_failures
make_failure old_wf 2026-07-01T09:00:00Z api_error "old"
OUT=$("$FAILURES" list --after 2026-08-01 --json)
assert_eq "$OUT" "[]" "date filter: out-of-window workflow omitted"

# --- list malformed lines ---
desc "list: malformed lines dropped with stderr warning"
setup_failures
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
printf '%s' '{"ts":"2026-08-21T09:00:00Z","workflow":"issue_worker","run_id":null,"session_id":null,"category":"api_error","summary":"trunc' >>"$SHAI_HOME/failures/issue_worker.jsonl"
OUT=$("$FAILURES" list --workflow issue_worker --json 2>/dev/null)
RC=$?
ERR=$("$FAILURES" list --workflow issue_worker 2>&1 >/dev/null)
assert_eq "$RC" "0" "malformed: exit 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "malformed: bad line dropped, good kept"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].id')" "issue_worker:1" "malformed: id still the physical line"
assert_contains "$ERR" "warning" "malformed: stderr warning"
assert_contains "$ERR" "dropped 1" "malformed: warning reports dropped count"

OUT=$("$FAILURES" list --json 2>/dev/null)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].failures')" "1" "malformed: summary count unaffected"

# --- show: full detail with trace hint ---
desc "show: full detail, trace hint when run_id present"
setup_failures
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed: HTTP 502" run_1724295240_abc123 sess_1724295240_def456 '{"script":"workflows/pr_reviewer/run.sh","detail":"gh pr view failed: HTTP 502"}'
OUT=$("$FAILURES" show pr_reviewer:1)
assert_contains "$OUT" "Failure: pr_reviewer:1" "show: id line"
assert_contains "$OUT" "2026-08-22T03:14:00Z" "show: timestamp"
assert_contains "$OUT" "Workflow:  pr_reviewer" "show: workflow"
assert_contains "$OUT" "Category:  workflow_error" "show: category"
assert_contains "$OUT" "Summary:   gh pr view failed: HTTP 502" "show: summary"
assert_contains "$OUT" "Run:       run_1724295240_abc123" "show: run"
assert_contains "$OUT" "Session:   sess_1724295240_def456" "show: session"
assert_contains "$OUT" "Context:" "show: context header"
assert_contains "$OUT" "script:  workflows/pr_reviewer/run.sh" "show: context script"
assert_contains "$OUT" "detail:  gh pr view failed: HTTP 502" "show: context detail"
assert_contains "$OUT" "Trace:" "show: trace label"
assert_contains "$OUT" "shai-trace run_1724295240_abc123" "show: trace hint names the run"

# --- show: run_id null — no run/session/trace lines ---
desc "show: run_id null — no run/session/trace lines"
setup_failures
make_failure _manual 2026-08-22T03:14:00Z tool_error "manual failure"
OUT=$("$FAILURES" show _manual:1)
assert_contains "$OUT" "Failure: _manual:1" "show-null: id line"
assert_eq "$(printf '%s' "$OUT" | grep -c 'Trace:')" "0" "show-null: no trace hint"
assert_eq "$(printf '%s' "$OUT" | grep -c 'Run:')" "0" "show-null: no run line"
assert_eq "$(printf '%s' "$OUT" | grep -c 'Session:')" "0" "show-null: no session line"
assert_contains "$OUT" "Category:  tool_error" "show-null: record still fully displayed"

# --- show: invalid ids ---
desc "show: invalid ids exit 1"
setup_failures
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed"
assert_fails 1 "error: invalid failure id \"pr_reviewer\" (expected <workflow>:<line>)" "show: id without colon" -- "$FAILURES" show pr_reviewer
assert_fails 1 "error: invalid line number \"abc\" in failure id \"pr_reviewer:abc\"" "show: non-integer line" -- "$FAILURES" show pr_reviewer:abc
assert_fails 1 "error: invalid line number \"0\" in failure id \"pr_reviewer:0\"" "show: zero line" -- "$FAILURES" show pr_reviewer:0
assert_fails 1 "error: no failure record at pr_reviewer:99 (file has fewer lines)" "show: line beyond EOF" -- "$FAILURES" show pr_reviewer:99
assert_fails 1 "error: no failure records for workflow \"nope\"" "show: unknown workflow" -- "$FAILURES" show nope:1
assert_fails 1 "error: workflow must not contain / or .. (got \"../sessions/foo\")" "show: traversal" -- "$FAILURES" show "../sessions/foo:1"
ERR=$("$FAILURES" show pr_reviewer 2>&1 >/dev/null || true)
assert_contains "$ERR" "expected <workflow>:<line>" "show: bad id message"
ERR=$("$FAILURES" show pr_reviewer:99 2>&1 >/dev/null || true)
assert_contains "$ERR" "no failure record" "show: out-of-range message"

# --- show --json ---
desc "show --json: valid object with the full record"
setup_failures
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed: HTTP 502" run_1724295240_abc123 sess_1724295240_def456 '{"script":"workflows/pr_reviewer/run.sh","detail":"gh pr view failed: HTTP 502"}'
OUT=$("$FAILURES" show pr_reviewer:1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r 'type')" "object" "show --json: object"
assert_eq "$(printf '%s' "$OUT" | jq -r '.id')" "pr_reviewer:1" "show --json: id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.line')" "1" "show --json: line"
assert_eq "$(printf '%s' "$OUT" | jq -r '.workflow')" "pr_reviewer" "show --json: workflow"
assert_eq "$(printf '%s' "$OUT" | jq -r '.ts')" "2026-08-22T03:14:00Z" "show --json: ts"
assert_eq "$(printf '%s' "$OUT" | jq -r '.category')" "workflow_error" "show --json: category"
assert_eq "$(printf '%s' "$OUT" | jq -r '.summary')" "gh pr view failed: HTTP 502" "show --json: summary"
assert_eq "$(printf '%s' "$OUT" | jq -r '.run_id')" "run_1724295240_abc123" "show --json: run_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.session_id')" "sess_1724295240_def456" "show --json: session_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.context.detail')" "gh pr view failed: HTTP 502" "show --json: context"

# --- summary ---
desc "summary: totals, breakdowns with percentages"
setup_failures
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
make_failure issue_worker 2026-08-21T09:00:00Z api_error "HTTP 502"
make_failure issue_worker 2026-08-23T09:00:00Z tool_error "patch_file failed"
make_failure _repl 2026-08-19T10:00:00Z tool_error "ls failed"
make_failure _repl 2026-08-24T10:00:00Z api_error "overloaded"
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed: HTTP 502"

OUT=$("$FAILURES" summary --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.total')" "6" "summary: total"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-19T10:00:00Z" "summary: oldest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.newest')" "2026-08-24T10:00:00Z" "summary: newest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category | length')" "3" "summary: three categories"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[0].category')" "api_error" "summary: top category"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[0].count')" "3" "summary: top category count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[0].percent')" "50" "summary: top category percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[1].category')" "tool_error" "summary: second category"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[1].percent')" "33" "summary: second category percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[2].category')" "workflow_error" "summary: third category"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category[2].percent')" "17" "summary: third category percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow | length')" "3" "summary: three workflows"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[0].workflow')" "issue_worker" "summary: top workflow"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[0].count')" "3" "summary: top workflow count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[0].percent')" "50" "summary: top workflow percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[1].workflow')" "_repl" "summary: second workflow"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[1].percent')" "33" "summary: second workflow percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[2].workflow')" "pr_reviewer" "summary: third workflow"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[2].percent')" "17" "summary: third workflow percent"

OUT=$("$FAILURES" summary)
assert_contains "$OUT" "Failures: 6 total (2026-08-19 — 2026-08-24)" "summary: total line with range"
assert_contains "$OUT" "By category:" "summary: category header"
assert_contains "$OUT" "api_error" "summary: category name"
assert_contains "$OUT" "50%" "summary: percent shown"
assert_contains "$OUT" "By workflow:" "summary: workflow header"
assert_contains "$OUT" "issue_worker" "summary: workflow name"

# --- summary date filters ---
desc "summary: date filters narrow the aggregate"
setup_failures
make_failure issue_worker 2026-08-20T09:00:00Z api_error "HTTP 503"
make_failure issue_worker 2026-08-23T09:00:00Z tool_error "patch_file failed"
make_failure pr_reviewer 2026-08-22T03:14:00Z workflow_error "gh pr view failed"
OUT=$("$FAILURES" summary --after 2026-08-21 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.total')" "2" "summary: filtered total"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-22T03:14:00Z" "summary: filtered oldest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.newest')" "2026-08-23T09:00:00Z" "summary: filtered newest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category | length')" "2" "summary: filtered categories"
OUT=$("$FAILURES" summary --before 2026-08-21 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.total')" "1" "summary: before narrows"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow[0].workflow')" "issue_worker" "summary: before keeps the early record"

# --- summary empty store ---
desc "summary: empty store — clean zero output"
setup_failures
rm -rf "$SHAI_HOME/failures"
OUT=$("$FAILURES" summary)
RC=$?
assert_eq "$RC" "0" "summary empty: exit 0"
assert_eq "$OUT" "Failures: 0 total" "summary empty: zero total line only"
OUT=$("$FAILURES" summary --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.total')" "0" "summary empty json: total 0"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "null" "summary empty json: oldest null"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_category | length')" "0" "summary empty json: no categories"
assert_eq "$(printf '%s' "$OUT" | jq -r '.by_workflow | length')" "0" "summary empty json: no workflows"

# --- usage / argument errors ---
desc "usage errors exit 2; invalid arguments exit 1"
setup_failures
assert_fails 2 "usage: shai-failures <list|show|summary>" "no subcommand" -- "$FAILURES"
assert_fails 2 "error: unknown subcommand: frobnicate" "unknown subcommand" -- "$FAILURES" frobnicate
assert_fails 2 "usage: shai-failures show <workflow>:<line>" "show without id" -- "$FAILURES" show
assert_fails 1 "error: unknown option: --bogus" "list unknown flag" -- "$FAILURES" list --bogus
assert_fails 1 "error: --workflow requires a name or prefix" "list --workflow without value" -- "$FAILURES" list --workflow
assert_fails 1 "error: --recent value must be an integer" "list --recent non-integer" -- "$FAILURES" list --recent abc
assert_fails 1 "error: --after date must be YYYY-MM-DD" "list --after bad date" -- "$FAILURES" list --after not-a-date
assert_fails 1 "error: --before date must be YYYY-MM-DD" "list --before bad date" -- "$FAILURES" list --before 2026/08/10
assert_fails 1 "error: --after date must be YYYY-MM-DD" "summary --after bad date" -- "$FAILURES" summary --after 20260810
assert_fails 1 "error: unknown option: --bogus" "show unknown flag" -- "$FAILURES" show pr_reviewer:1 --bogus
ERR=$("$FAILURES" list --bogus 2>&1 >/dev/null || true)
assert_contains "$ERR" "unknown option" "invalid arg: message names the option"

finish
