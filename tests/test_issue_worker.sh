#!/bin/bash
# test_issue_worker.sh — unit tests for workflows/issue_worker/run.sh
# Covers: workflows/issue_worker/run.sh — arg parsing, idempotency, slug generation, LLM dispatch
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/issue_worker/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

# --- usage error: no arguments ---
OUT=$("$DIR/workflows/issue_worker/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "2" "issue_worker: exit 2 with no arguments"
assert_contains "$OUT" "Usage" "issue_worker: prints usage on no args"

# --- usage error: only one argument ---
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 2>&1)
RC=$?
assert_eq "$RC" "2" "issue_worker: exit 2 with only repo"

# --- usage error: invalid repo format ---
OUT=$("$DIR/workflows/issue_worker/run.sh" "not-a-repo" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "issue_worker: exit 2 on invalid repo format"
assert_contains "$OUT" "OWNER/REPO" "issue_worker: error names the expected format"

# --- usage error: repo with extra slash ---
OUT=$("$DIR/workflows/issue_worker/run.sh" "foo/bar/baz" 42 2>&1)
RC=$?
assert_eq "$RC" "2" "issue_worker: exit 2 on repo with extra slash"

# --- usage error: non-numeric issue number ---
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo abc 2>&1)
RC=$?
assert_eq "$RC" "2" "issue_worker: exit 2 on non-numeric issue number"
assert_contains "$OUT" "positive integer" "issue_worker: error names the constraint"

make_stub_bin

# gh stub that returns issue JSON for `issue view` and echoes args otherwise
write_issue_worker_gh_stub() {
  local title="$1" body="${2:-}" labels="${3:-[]}"
  cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "issue view"*)
    cat <<'ISSUE'
{"title":"$title","body":"$body","labels":$labels}
ISSUE
    ;;
  *)
    echo "stub gh: \$*"
    ;;
esac
GHSTUB
  chmod +x "$STUB/gh"
}

# --- idempotency: already-processed issue skips (no gh fetch, no LLM call) ---
desc "idempotency"
write_issue_worker_gh_stub "Fix something" "Body text"
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"issue:owner/repo:42","ts":"2026-08-13T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/issue_worker.jsonl"

# a curl that records whether it was ever invoked, so the idempotent skip can be verified
# end-to-end rather than just inferred from the exit code
CALLED_MARKER="$TMP/llm_called"
rm -f "$CALLED_MARKER"
{
  printf '#!/bin/bash\n'
  printf 'touch "%s"\n' "$CALLED_MARKER"
  printf 'cat >/dev/null\n'
  printf 'echo "500"\n'
} >"$STUB/curl"
chmod +x "$STUB/curl"

OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 on already-processed issue"
assert_eq "$(test -f "$CALLED_MARKER" && echo called || echo not-called)" "not-called" \
  "issue_worker: idempotent skip makes no LLM call"

rm -f "$SHAI_HOME/ledgers/issue_worker.jsonl" "$CALLED_MARKER"

# --- gh failure ---
desc "gh failure"
printf '#!/bin/bash\nexit 1\n' >"$STUB/gh"
chmod +x "$STUB/gh"

OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_worker: exit 1 on gh failure"
assert_contains "$OUT" "ERROR" "issue_worker: prints ERROR on gh failure"

# --- branch slug generation ---
# SLUG/BRANCH_NAME never reach stdout — the only place they surface is the LLM prompt (the
# template's "Use branch name `{{BRANCH_NAME}}` exactly" line), so verify them by inspecting
# the exact request payload shai-eval dumps per span. A plain end_turn reply never loops, so
# span_1 is always the only request for a given invocation; runs/ is cleared beforehand so the
# glob below can only match that one call.
desc "branch slug generation"

# special characters collapse to a single hyphen and are stripped from both ends
write_issue_worker_gh_stub 'Fix @#$% Login Bug!!!' "Body"
printf '{"type":"message","content":[{"type":"text","text":"done."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200
rm -rf "$SHAI_HOME/runs"
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 201 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 for special-char title"
REQ=$(cat "$SHAI_HOME"/runs/*/span_1-request.json 2>/dev/null)
assert_contains "$REQ" "shai/201-fix-login-bug" \
  "issue_worker: slug collapses special chars and strips leading/trailing hyphens"

# long titles truncate to 50 characters, with no dangling hyphen at the cut point
LONG_TITLE="This Is A Very Long Issue Title That Definitely Exceeds Fifty Characters In Length For Sure"
write_issue_worker_gh_stub "$LONG_TITLE" "Body"
printf '{"type":"message","content":[{"type":"text","text":"done."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200
rm -rf "$SHAI_HOME/runs"
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 202 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 for long title"
REQ=$(cat "$SHAI_HOME"/runs/*/span_1-request.json 2>/dev/null)
EXPECT='shai/202-this-is-a-very-long-issue-title-that-definitely-ex`'
assert_contains "$REQ" "$EXPECT" \
  "issue_worker: slug truncates to 50 characters with no dangling hyphen"

# a title whose 50th collapsed character lands exactly on a hyphen: the post-cut sed strips it
FORTYNINE_A="$(printf 'a%.0s' {1..49})"
BOUNDARY_TITLE="$FORTYNINE_A more words here to push past fifty chars total length for sure"
write_issue_worker_gh_stub "$BOUNDARY_TITLE" "Body"
printf '{"type":"message","content":[{"type":"text","text":"done."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200
rm -rf "$SHAI_HOME/runs"
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 203 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 for hyphen-at-truncation-boundary title"
REQ=$(cat "$SHAI_HOME"/runs/*/span_1-request.json 2>/dev/null)
EXPECT_BOUNDARY=$(printf 'shai/203-%s`' "$FORTYNINE_A")
assert_contains "$REQ" "$EXPECT_BOUNDARY" \
  "issue_worker: trailing hyphen introduced by truncation is stripped"

# empty title: known deferred edge case (docs: sdd progress notes) — empty slug, branch name
# keeps the trailing hyphen from "shai/<n>-" + "" (still a valid git branch name)
write_issue_worker_gh_stub "" "Body"
printf '{"type":"message","content":[{"type":"text","text":"done."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200
rm -rf "$SHAI_HOME/runs"
OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 204 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 for empty title"
REQ=$(cat "$SHAI_HOME"/runs/*/span_1-request.json 2>/dev/null)
assert_contains "$REQ" 'shai/204-`' \
  "issue_worker: empty title yields empty slug (trailing hyphen retained)"

rm -rf "$SHAI_HOME/runs"
rm -f "$SHAI_HOME/ledgers/issue_worker.jsonl"

# --- success case: valid assistant response ---
desc "success path"
write_issue_worker_gh_stub "Fix the login bug" "The login page crashes"
printf '{"type":"message","content":[{"type":"text","text":"PR created."}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_worker: exit 0 on valid assistant response"
assert_contains "$OUT" "implemented issue #42" "issue_worker: output includes issue number"
assert_contains "$OUT" "owner/repo" "issue_worker: output includes repo"

# verify wf_mark was called
LEDGER="$SHAI_HOME/ledgers/issue_worker.jsonl"
if [ -f "$LEDGER" ] && grep -q '"issue:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} issue_worker: wf_mark recorded issue key"
else
  echo -e "  ${RED}✗${NC} issue_worker: wf_mark did not record issue key"
  FAILED=1
fi

rm -f "$SHAI_HOME/ledgers/issue_worker.jsonl"

# --- fail case: error response from API ---
desc "failure path"
write_issue_worker_gh_stub "Some issue" "Body"
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

OUT=$("$DIR/workflows/issue_worker/run.sh" owner/repo 42 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_worker: exit 1 on error response"
assert_contains "$OUT" "ERROR" "issue_worker: prints ERROR on failure"

# verify wf_mark was NOT called
if [ -f "$SHAI_HOME/ledgers/issue_worker.jsonl" ]; then
  echo -e "  ${RED}✗${NC} issue_worker: wf_mark should not be called on failure"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_worker: wf_mark not called on failure"
fi

finish
