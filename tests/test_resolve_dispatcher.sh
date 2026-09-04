#!/bin/bash
# test_resolve_dispatcher.sh — unit tests for workflows/resolve_dispatcher/run.sh
# Covers: workflows/resolve_dispatcher/run.sh — idle tick, gh search failure, scoped search,
#   label removal before dispatch, sequential processing, ledger safety-net dedup, worker
#   failure leaving ledger unmarked, label-removal-failure skip-and-continue (including the
#   already-seen path), input validation, and truncation warning
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/resolve_dispatcher/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

make_stub_bin

WORKER_LOG="$TMP/worker.log"
WORKER_RC_FILE="$TMP/worker_rc"
echo 0 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
# args: run review_resolver <repo> <number>
if [ "\$1" = "run" ] && [ "\$2" = "review_resolver" ]; then
  printf '%s %s\n' "\$3" "\$4" >>"$WORKER_LOG"
  [ -z "\${SHAI_POLICY_OVERLAY:-}" ] || printf 'OVERLAY=%s\n' "\$SHAI_POLICY_OVERLAY" >>"$WORKER_LOG"
fi
exit "\$(cat "$WORKER_RC_FILE")"
WFSTUB
chmod +x "$STUB/shai-workflow"
export SHAI_WORKFLOW="$STUB/shai-workflow"

SEARCH_FIXTURE="$TMP/search.json"
EDIT_LOG="$TMP/edit.log"
EDIT_RC_FILE="$TMP/edit_rc"
SEARCH_RC_FILE="$TMP/search_rc"
GH_ARGS_LOG="$TMP/gh_args.log"
echo 0 >"$EDIT_RC_FILE"
echo 0 >"$SEARCH_RC_FILE"
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search prs"*)
    printf '%s\n' "\$*" >>"$GH_ARGS_LOG"
    rc="\$(cat "$SEARCH_RC_FILE")"
    [ "\$rc" = "0" ] || exit "\$rc"
    cat "$SEARCH_FIXTURE"
    ;;
  "pr edit"*)
    printf '%s\n' "\$*" >>"$EDIT_LOG"
    exit "\$(cat "$EDIT_RC_FILE")"
    ;;
  *)
    echo "stub gh: \$*"
    ;;
esac
GHSTUB
chmod +x "$STUB/gh"

reset_state() {
  rm -f "$WORKER_LOG" "$EDIT_LOG" "$GH_ARGS_LOG"
  rm -rf "$SHAI_HOME/ledgers" "$SHAI_HOME/sessions" "$SHAI_HOME/failures"
  echo 0 >"$WORKER_RC_FILE"
  echo 0 >"$EDIT_RC_FILE"
  echo 0 >"$SEARCH_RC_FILE"
}

# --- idle tick: no matching PRs ---
desc "idle tick"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 when no PRs match"
assert_contains "$OUT" "no matching PRs" "resolve_dispatcher: reports idle tick"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "resolve_dispatcher: no worker dispatched on idle tick"
# Expected-zero assertion (#388): an idle tick must leave $SHAI_HOME/sessions/ empty — no
# stillborn session files on every timer tick. Mutation-checked: reverting wf_init to eager
# seeding turns this red.
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "resolve_dispatcher: idle tick creates no session files"

# --- dispatching tick: session IS materialized (positive control for the idle zero-count) ---
# The same fixture shape with a matching PR must produce the artifact the idle tick does not:
# exactly two files — the session log seeded with the system prompt plus the empty
# .latest.json sibling. The count (not bare existence) catches a fix that writes one file
# instead of two; the adjacent zero-count above provides the contrast. Mutation-checked
# (#388): removing the dispatcher's wf_seed_session call turns these red.
desc "dispatching tick materializes the session"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: dispatching tick exits 0"
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "resolve_dispatcher: dispatching tick creates exactly two session files"
SESSION_LOG=$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f -name '*.jsonl' | head -n1)
assert_eq "$(jq -r '.source' "$SESSION_LOG" | head -n1)" "system" \
  "resolve_dispatcher: dispatching tick seeds the system prompt as the first event"

# --- scoped search: uses --involves @me and the resolve label ---
desc "scoped search"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
"$DIR/workflows/resolve_dispatcher/run.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$GH_ARGS_LOG")" "--involves @me" \
  "resolve_dispatcher: search is scoped with --involves @me"
assert_contains "$(cat "$GH_ARGS_LOG")" "--label shai-resolve-dispatcher" \
  "resolve_dispatcher: search filters on the shai-resolve-dispatcher label"

# --- gh search failure ---
desc "gh search failure"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
echo 1 >"$SEARCH_RC_FILE"
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "resolve_dispatcher: exit 1 when gh search fails"
assert_contains "$OUT" "ERROR" "resolve_dispatcher: prints ERROR on search failure"
# wf_fail on a pure-bash tick still records a failure attributed to this workflow (not the
# _repl fallback) with the minted session id, and still writes no session files.
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "resolve_dispatcher: failed search tick creates no session files"
FAILURE_LOG="$SHAI_HOME/failures/resolve_dispatcher.jsonl"
assert_eq "$(test -f "$FAILURE_LOG" && echo yes || echo no)" "yes" \
  "resolve_dispatcher: records the search failure"
assert_eq "$(jq -r '.workflow' "$FAILURE_LOG" | head -n1)" "resolve_dispatcher" \
  "resolve_dispatcher: failure attributed to the workflow name, not _repl"
FAILURE_SID=$(jq -r '.session_id' "$FAILURE_LOG" | head -n1)
assert_eq "$(test -n "$FAILURE_SID" && echo set || echo empty)" "set" \
  "resolve_dispatcher: failure record carries the minted session_id"

# --- single PR: label removed before dispatch, then worker run, ledger marked ---
desc "single PR happy path"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 on successful dispatch"
assert_contains "$OUT" "dispatched owner/repo#42" "resolve_dispatcher: logs the dispatch"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-resolve-dispatcher" \
  "resolve_dispatcher: removes the shai-resolve-dispatcher label"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "resolve_dispatcher: delegates to review_resolver with repo and number"
assert_eq "$(grep -c 'OVERLAY=' "$WORKER_LOG" 2>/dev/null || true)" "0" \
  "resolve_dispatcher: worker does not inherit SHAI_POLICY_OVERLAY"
LEDGER="$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"
if [ -f "$LEDGER" ] && grep -q '"resolve:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} resolve_dispatcher: wf_mark recorded PR key on success"
else
  echo -e "  ${RED}✗${NC} resolve_dispatcher: wf_mark did not record PR key"
  FAILED=1
fi
LEDGER_SID=$(jq -r '.session_id' "$LEDGER" 2>/dev/null | head -n1)
assert_eq "$(test -n "$LEDGER_SID" && echo set || echo empty)" "set" \
  "resolve_dispatcher: wf_mark ledger entry carries a non-empty session_id"

# --- multiple PRs: all processed sequentially ---
desc "multiple PRs"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":1},
 {"repository":{"nameWithOwner":"other/proj"},"number":7}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 processing multiple PRs"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 1" "resolve_dispatcher: dispatches first PR"
assert_contains "$(cat "$WORKER_LOG")" "other/proj 7" "resolve_dispatcher: dispatches second PR"
assert_contains "$OUT" "dispatched=2" "resolve_dispatcher: summary counts both dispatches"

# --- ledger idempotency: an already-seen PR is skipped (no dispatch) ---
desc "ledger idempotency"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"resolve:owner/repo:99","ts":"2026-08-14T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 when only match is already seen"
assert_contains "$OUT" "skipped=1" "resolve_dispatcher: summary counts the skip"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "resolve_dispatcher: already-seen PR is not dispatched"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-resolve-dispatcher" \
  "resolve_dispatcher: already-seen PR still has label removed"

# --- already-seen PR whose label cannot be removed is reported, not silently skipped ---
desc "already-seen label removal failure"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"resolve:owner/repo:99","ts":"2026-08-14T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 when an already-seen PR cannot be de-labeled"
assert_contains "$OUT" "already-seen owner/repo#99" \
  "resolve_dispatcher: warns when an already-seen PR's label cannot be removed"
assert_contains "$OUT" "skipped=1" "resolve_dispatcher: still counts the skip"

# --- label removal failure: skip and continue, label stays for retry, no dispatch ---
desc "label removal failure"
reset_state
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":55},
 {"repository":{"nameWithOwner":"other/proj"},"number":56}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "resolve_dispatcher: exit 1 when all dispatches fail (label removal)"
assert_contains "$OUT" "WARNING" "resolve_dispatcher: warns on label removal failure"
assert_contains "$OUT" "failed=2" "resolve_dispatcher: continues to the next PR after a removal failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "resolve_dispatcher: no dispatch when label removal fails"
if [ -f "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl" ] &&
  grep -q '"resolve:owner/repo:55"' "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} resolve_dispatcher: should not mark ledger when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} resolve_dispatcher: ledger not marked when label removal fails"
fi

# --- worker failure: label already removed, ledger left unmarked for manual re-label retry ---
desc "worker failure leaves ledger unmarked"
reset_state
echo 1 >"$WORKER_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":77}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "resolve_dispatcher: exit 1 when all dispatches fail (worker failure)"
assert_contains "$OUT" "WARNING" "resolve_dispatcher: warns when worker fails"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-resolve-dispatcher" \
  "resolve_dispatcher: label was still removed before the failing worker ran"
if [ -f "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl" ] &&
  grep -q '"resolve:owner/repo:77"' "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} resolve_dispatcher: should not mark ledger when worker fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} resolve_dispatcher: ledger not marked when worker fails"
fi

# --- seed failure: label already removed, failure recorded, item skipped, tick continues ---
# wf_seed_session runs after the label is removed, so a bare call under `set -e` would abort
# the tick after the `gh` mutation with no failure record — pre-#388 the same failure aborted
# in wf_init before any mutation. A read-only sessions dir makes the seed fail (skipped as
# root, where chmod 555 is no obstacle). Mutation-checked: reverting the guard to a bare
# `wf_seed_session` call turns the WARNING, failure-record, and zero-file assertions red.
if [ "$(id -u)" -ne 0 ]; then
  desc "seed failure records a failure and skips the dispatch"
  reset_state
  mkdir -p "$SHAI_HOME/sessions"
  chmod 555 "$SHAI_HOME/sessions"
  cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
  OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
  RC=$?
  chmod 755 "$SHAI_HOME/sessions"
  assert_eq "$RC" "1" "resolve_dispatcher: exit 1 when seeding fails (only item, nothing dispatched)"
  assert_contains "$OUT" "WARNING: could not materialize session for owner/repo#42" \
    "resolve_dispatcher: warns when seeding fails"
  assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-resolve-dispatcher" \
    "resolve_dispatcher: label was still removed before the seed failure"
  assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
    "resolve_dispatcher: no dispatch when seeding fails"
  FAILURE_LOG="$SHAI_HOME/failures/resolve_dispatcher.jsonl"
  assert_eq "$(test -f "$FAILURE_LOG" && echo yes || echo no)" "yes" \
    "resolve_dispatcher: seed failure recorded in the failure store"
  assert_eq "$(jq -r '.workflow' "$FAILURE_LOG" | head -n1)" "resolve_dispatcher" \
    "resolve_dispatcher: seed failure attributed to the workflow name"
  assert_eq "$(jq -r '.context.detail' "$FAILURE_LOG" | head -n1)" "re-label to retry" \
    "resolve_dispatcher: seed failure tells the operator to re-label"
  SEED_SID=$(jq -r '.session_id' "$FAILURE_LOG" | head -n1)
  assert_eq "$(test -n "$SEED_SID" && echo set || echo empty)" "set" \
    "resolve_dispatcher: seed failure record carries the minted session_id"
  if [ -f "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl" ] &&
    grep -q '"resolve:owner/repo:42"' "$SHAI_HOME/ledgers/resolve_dispatcher.jsonl"; then
    echo -e "  ${RED}✗${NC} resolve_dispatcher: should not mark ledger when seeding fails"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} resolve_dispatcher: ledger not marked when seeding fails"
  fi
  assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "resolve_dispatcher: failed seed leaves no session files"
fi

# --- input validation: malformed repo skipped ---
desc "repo validation"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"../evil"},"number":1},
 {"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 when valid PR dispatched alongside invalid"
assert_contains "$OUT" "invalid repo format" "resolve_dispatcher: warns on invalid repo format"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "resolve_dispatcher: valid PR still dispatched after skipping invalid"
assert_eq "$(grep -c 'evil' "$WORKER_LOG" 2>/dev/null || true)" "0" \
  "resolve_dispatcher: malformed repo is never dispatched"

# --- input validation: non-numeric PR number skipped ---
desc "PR number validation"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":"abc"},
 {"repository":{"nameWithOwner":"owner/repo"},"number":0},
 {"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "resolve_dispatcher: exit 0 when valid PR dispatched alongside bad numbers"
assert_contains "$OUT" "invalid PR number" "resolve_dispatcher: warns on non-numeric PR number"
assert_contains "$OUT" "failed=2" "resolve_dispatcher: counts both rejected PR numbers"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "resolve_dispatcher: valid PR still dispatched after skipping bad numbers"

# --- truncation warning: warns when result count hits limit ---
desc "truncation warning"
reset_state
# Generate exactly 100 results to trigger the warning
printf '[' >"$SEARCH_FIXTURE"
for i in $(seq 1 100); do
  [ "$i" -gt 1 ] && printf ',' >>"$SEARCH_FIXTURE"
  printf '{"repository":{"nameWithOwner":"owner/repo"},"number":%d}' "$i" >>"$SEARCH_FIXTURE"
done
printf ']' >>"$SEARCH_FIXTURE"
OUT=$("$DIR/workflows/resolve_dispatcher/run.sh" 2>&1)
assert_contains "$OUT" "hit limit" \
  "resolve_dispatcher: warns when result count hits the search limit"

# --- pr_reviewer prompt closes the loop by adding the resolve label ---
desc "pipeline wiring"
PROMPT_OUT=$("$DIR/shai-prompt" pr_reviewer 2>&1)
assert_contains "$PROMPT_OUT" "--add-label shai-resolve-dispatcher" \
  "pr_reviewer prompt: adds the shai-resolve-dispatcher label after review"
assert_contains "$PROMPT_OUT" "gh label create shai-resolve-dispatcher" \
  "pr_reviewer prompt: creates the label if the repo lacks it"
assert_eq "$(printf '%s' "$PROMPT_OUT" | grep -c '|| true' || true)" "0" \
  "pr_reviewer prompt: no shell operators — the gh tool runs a pre-tokenized argv array"
assert_contains "$PROMPT_OUT" "at least one actionable" \
  "pr_reviewer prompt: gates the label on actionable inline comments"
# Regression guard for #106: the review payload must never go back to a fixed
# /tmp/review.json --input path, and must stay inside the per-run clone dir with the PR number.
assert_eq "$(printf '%s' "$PROMPT_OUT" | grep -cF -- '--input /tmp/review.json' || true)" "0" \
  "pr_reviewer prompt: no fixed /tmp/review.json payload path"
assert_contains "$PROMPT_OUT" "/tmp/pr-review-XXXXX/comment-{{NUMBER}}-<k>.json" \
  "pr_reviewer prompt: stages each per-comment payload inside the per-run clone dir with the PR number"

finish
