#!/bin/bash
# test_review_resolver.sh — unit tests for workflows/review_resolver/run.sh
# Covers: workflows/review_resolver/run.sh — arg validation, prompt loading + substitution,
#   policy overlay export, wf_llm dispatch, success output, LLM failure, non-idempotency
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/review_resolver/run.sh"

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
OUT=$("$DIR/workflows/review_resolver/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 with no arguments"
assert_contains "$OUT" "Usage" "review_resolver: prints usage on no args"

# --- usage error: only one argument ---
OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 with only repo"

# --- usage error: invalid repo format ---
OUT=$("$DIR/workflows/review_resolver/run.sh" "not-a-repo" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 on invalid repo format"
assert_contains "$OUT" "OWNER/REPO" "review_resolver: error names the expected format"

OUT=$("$DIR/workflows/review_resolver/run.sh" "a/b/c" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 on repo with extra slash"

OUT=$("$DIR/workflows/review_resolver/run.sh" "foo|bar" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 on repo with sed metacharacter"

# --- usage error: bad PR number ---
OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo abc 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 on non-numeric PR number"
assert_contains "$OUT" "positive integer" "review_resolver: error names the constraint"

OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo 0 2>&1)
RC=$?
assert_eq "$RC" "2" "review_resolver: exit 2 on PR number 0"

# --- success case: valid assistant response ---
desc "happy path"
printf '{"type":"message","content":[{"type":"text","text":"Resolution complete."}],"stop_reason":"end_turn"}' |
  write_capture_curl_stub 200

OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "review_resolver: exit 0 on valid assistant response"
assert_contains "$OUT" "PR #42" "review_resolver: output includes PR number"
assert_contains "$OUT" "owner/repo" "review_resolver: output includes repo"

# --- prompt substitution: placeholders replaced in the request sent to the API ---
desc "prompt substitution"
REQ_BODY="$(cat "$REQ" 2>/dev/null)"
assert_contains "$REQ_BODY" "owner/repo" "review_resolver: {{REPO}} substituted into the prompt"
assert_contains "$REQ_BODY" "pull request #42" "review_resolver: {{NUMBER}} substituted into the prompt"
if [[ "$REQ_BODY" == *'{{REPO}}'* ]] || [[ "$REQ_BODY" == *'{{NUMBER}}'* ]]; then
  echo -e "  ${RED}✗${NC} review_resolver: unsubstituted placeholder left in the prompt"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} review_resolver: no unsubstituted placeholders in the prompt"
fi

# --- policy overlay: co-located policy.json exported to the tool dispatch path ---
desc "policy overlay"
assert_contains "$(cat "$ENVF" 2>/dev/null)" "workflows/review_resolver/policy.json" \
  "review_resolver: SHAI_POLICY_OVERLAY points at the co-located policy.json"
if jq -e '.rules | type == "array" and length > 0' \
  "$DIR/workflows/review_resolver/policy.json" >/dev/null 2>&1; then
  echo -e "  ${GREEN}✓${NC} review_resolver: policy.json has a non-empty .rules array"
else
  echo -e "  ${RED}✗${NC} review_resolver: policy.json missing a non-empty .rules array"
  FAILED=1
fi

# --- no idempotency: re-running the same PR is allowed and writes no ledger ---
desc "non-idempotent by design"
OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "review_resolver: exit 0 on a repeat run for the same PR"
assert_contains "$OUT" "PR #42" "review_resolver: repeat run still does the work"
assert_eq "$(test -e "$SHAI_HOME/ledgers/review_resolver.jsonl" && echo yes || echo no)" "no" \
  "review_resolver: writes no idempotency ledger"

# --- fail case: error response from the API ---
desc "LLM failure"
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_capture_curl_stub 529

OUT=$("$DIR/workflows/review_resolver/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "1" "review_resolver: exit 1 on error response"
assert_contains "$OUT" "ERROR" "review_resolver: prints ERROR on failure"

# --- prompt file is loadable by name ---
desc "prompt file"
OUT=$("$DIR/shai-prompt" review_resolver 2>&1)
RC=$?
assert_eq "$RC" "0" "review_resolver: shai-prompt loads prompts/review_resolver.txt"
assert_contains "$OUT" "{{NUMBER}}" "review_resolver: prompt template has a NUMBER placeholder"
assert_contains "$OUT" "{{REPO}}" "review_resolver: prompt template has a REPO placeholder"

finish
