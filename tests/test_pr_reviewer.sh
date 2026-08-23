#!/bin/bash
# test_pr_reviewer.sh — unit tests for workflows/pr_reviewer/run.sh
# Covers: workflows/pr_reviewer/run.sh — arg validation, prompt loading + substitution,
#   policy overlay export, wf_llm dispatch, success output, LLM failure, non-idempotency
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/pr_reviewer/run.sh"

make_stub_bin
write_gh_stub

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

REQ="$TMP/request.json"
ENVF="$TMP/env.txt"

# write_capture_curl_stub <http_code>: like write_curl_stub, but also records the request
# body and the SHAI_POLICY_OVERLAY value curl was invoked with (curl inherits the workflow's
# exported environment through shai-loop → shai-eval).
write_capture_curl_stub() {
  local code="$1"
  cat >"$STUB/.curl_body"
  {
    printf '#!/bin/bash\n'
    printf 'cat > "%s"\n' "$REQ"
    printf 'printf "SHAI_POLICY_OVERLAY=%%s\\n" "${SHAI_POLICY_OVERLAY:-}" > "%s"\n' "$ENVF"
    printf 'cat "%s/.curl_body"\n' "$STUB"
    printf 'printf "\\n"\n'
    printf 'echo "%s"\n' "$code"
  } >"$STUB/curl"
  chmod +x "$STUB/curl"
}

# --- usage error: no arguments ---
desc "argument validation"
OUT=$("$DIR/workflows/pr_reviewer/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 with no arguments"
assert_contains "$OUT" "Usage" "pr_reviewer: prints usage on no args"

# --- usage error: only one argument ---
OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 with only repo"

# --- usage error: invalid repo format ---
OUT=$("$DIR/workflows/pr_reviewer/run.sh" "not-a-repo" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on invalid repo format"
assert_contains "$OUT" "OWNER/REPO" "pr_reviewer: error names the expected format"

# --- usage error: repo with sed metacharacters ---
OUT=$("$DIR/workflows/pr_reviewer/run.sh" "foo|bar" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on repo with pipe character"

OUT=$("$DIR/workflows/pr_reviewer/run.sh" "foo/bar/baz" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on repo with extra slash"

# --- usage error: path traversal in repo ---
OUT=$("$DIR/workflows/pr_reviewer/run.sh" "../.." 42 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on path-traversal repo"

OUT=$("$DIR/workflows/pr_reviewer/run.sh" "a../b.." 42 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on repo with dot-dot segments"

# --- usage error: bad PR number ---
OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo abc 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on non-numeric PR number"
assert_contains "$OUT" "positive integer" "pr_reviewer: error names the constraint"

OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 0 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on PR number 0"

OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 007 2>&1)
RC=$?
assert_eq "$RC" "2" "pr_reviewer: exit 2 on leading-zero PR number"

# --- success case: valid assistant response ---
desc "happy path"
printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"Review complete."},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_capture_curl_stub 200

OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "pr_reviewer: exit 0 on valid assistant response"
assert_contains "$OUT" "reviewed PR #42" "pr_reviewer: output includes PR number"
assert_contains "$OUT" "owner/repo" "pr_reviewer: output includes repo"

# --- prompt substitution: placeholders replaced in the request sent to the API ---
desc "prompt substitution"
REQ_BODY="$(cat "$REQ" 2>/dev/null)"
assert_contains "$REQ_BODY" "owner/repo" "pr_reviewer: {{REPO}} substituted into the prompt"
assert_contains "$REQ_BODY" "pull request #42" "pr_reviewer: {{NUMBER}} substituted into the prompt"
if [[ "$REQ_BODY" == *'{{REPO}}'* ]] || [[ "$REQ_BODY" == *'{{NUMBER}}'* ]] ||
  [[ "$REQ_BODY" == *'{{OWNER}}'* ]]; then
  echo -e "  ${RED}✗${NC} pr_reviewer: unsubstituted placeholder left in the prompt"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} pr_reviewer: no unsubstituted placeholders in the prompt"
fi

# --- policy overlay: co-located policy.json exported to the tool dispatch path ---
desc "policy overlay"
assert_contains "$(cat "$ENVF" 2>/dev/null)" "workflows/pr_reviewer/policy.json" \
  "pr_reviewer: SHAI_POLICY_OVERLAY points at the co-located policy.json"
if jq -e '.rules | type == "array" and length > 0' \
  "$DIR/workflows/pr_reviewer/policy.json" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} pr_reviewer: policy.json has a non-empty .rules array"
else
  echo -e "  ${RED}✗${NC} pr_reviewer: policy.json missing a non-empty .rules array"
  FAILED=1
fi

# --- no idempotency: re-running the same PR is allowed and writes no ledger ---
desc "non-idempotent by design"
OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "pr_reviewer: exit 0 on a repeat run for the same PR"
assert_contains "$OUT" "reviewed PR #42" "pr_reviewer: repeat run still does the work"
assert_eq "$(test -e "$SHAI_HOME/ledgers/pr_reviewer.jsonl" && echo yes || echo no)" "no" \
  "pr_reviewer: writes no idempotency ledger"

# --- fail case: error response from the API ---
desc "LLM failure"
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_capture_curl_stub 529

OUT=$("$DIR/workflows/pr_reviewer/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "1" "pr_reviewer: exit 1 on error response"
assert_contains "$OUT" "ERROR" "pr_reviewer: prints ERROR on failure"

# --- prompt file is loadable by name ---
desc "prompt file"
OUT=$("$DIR/shai-prompt" pr_reviewer 2>&1)
RC=$?
assert_eq "$RC" "0" "pr_reviewer: shai-prompt loads prompts/pr_reviewer.txt"
assert_contains "$OUT" "{{NUMBER}}" "pr_reviewer: prompt template has a NUMBER placeholder"
assert_contains "$OUT" "{{REPO}}" "pr_reviewer: prompt template has a REPO placeholder"
assert_contains "$OUT" "{{OWNER}}" "pr_reviewer: prompt template has an OWNER placeholder"
assert_contains "$OUT" "gh issue view N -R {{REPO}} --json title,body,labels,comments" \
  "pr_reviewer: prompt instructs fetching the linked GitHub issue"
assert_contains "$OUT" "silently returns that PR's own data" \
  "pr_reviewer: prompt distinguishes bare-#N PR references from issue references"
assert_contains "$OUT" "gh api repos/{{REPO}}/issues/N --jq 'has(\"pull_request\")'" \
  "pr_reviewer: prompt instructs detecting a bare-#N PR collision via the pull_request key"
assert_contains "$OUT" "rev-parse HEAD" \
  "pr_reviewer: prompt verifies the clone is at the PR head SHA"
assert_contains "$OUT" "reset --hard <headRefOid>" \
  "pr_reviewer: prompt hard-resets a stale clone to the PR head SHA"
assert_contains "$OUT" "gh api repos/{{REPO}}/pulls/{{NUMBER}}/comments --method POST --input <file>" \
  "pr_reviewer: prompt documents the one-at-a-time 422-recovery re-post"
assert_contains "$OUT" '"commit_id": "<head SHA>"' \
  "pr_reviewer: 422-recovery payload adds commit_id (the PR head SHA)"
assert_contains "$OUT" '"subject_type": "file"' \
  "pr_reviewer: prompt documents the file-level comment fallback with no line"

finish
