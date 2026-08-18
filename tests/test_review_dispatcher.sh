#!/bin/bash
# test_review_dispatcher.sh — unit tests for workflows/review_dispatcher/run.sh
# Covers: workflows/review_dispatcher/run.sh — idle tick, gh search failure, scoped search,
#   label removal before dispatch, sequential processing, ledger safety-net dedup, worker
#   failure leaving ledger unmarked, label-removal-failure skip-and-continue (including the
#   already-seen path), input validation, and truncation warning
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/review_dispatcher/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

make_stub_bin

WORKER_LOG="$TMP/worker.log"
WORKER_RC_FILE="$TMP/worker_rc"
echo 0 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
# args: run pr_reviewer <repo> <number>
if [ "\$1" = "run" ] && [ "\$2" = "pr_reviewer" ]; then
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
  rm -rf "$SHAI_HOME/ledgers"
  echo 0 >"$WORKER_RC_FILE"
  echo 0 >"$EDIT_RC_FILE"
  echo 0 >"$SEARCH_RC_FILE"
}

# --- idle tick: no matching PRs ---
desc "idle tick"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 when no PRs match"
assert_contains "$OUT" "no matching PRs" "review_dispatcher: reports idle tick"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "review_dispatcher: no worker dispatched on idle tick"

# --- scoped search: uses --involves @me ---
desc "scoped search"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
"$DIR/workflows/review_dispatcher/run.sh" >/dev/null 2>&1 || true
assert_contains "$(cat "$GH_ARGS_LOG")" "--involves @me" \
  "review_dispatcher: search is scoped with --involves @me"

# --- gh search failure ---
desc "gh search failure"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
echo 1 >"$SEARCH_RC_FILE"
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "review_dispatcher: exit 1 when gh search fails"
assert_contains "$OUT" "ERROR" "review_dispatcher: prints ERROR on search failure"

# --- single PR: label removed before dispatch, then worker run, ledger marked ---
desc "single PR happy path"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 on successful dispatch"
assert_contains "$OUT" "dispatched owner/repo#42" "review_dispatcher: logs the dispatch"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-review-dispatcher" \
  "review_dispatcher: removes the shai-review-dispatcher label"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "review_dispatcher: delegates to pr_reviewer with repo and number"
assert_eq "$(grep -c 'OVERLAY=' "$WORKER_LOG" 2>/dev/null || true)" "0" \
  "review_dispatcher: worker does not inherit SHAI_POLICY_OVERLAY"
LEDGER="$SHAI_HOME/ledgers/review_dispatcher.jsonl"
if [ -f "$LEDGER" ] && grep -q '"pr:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} review_dispatcher: wf_mark recorded PR key on success"
else
  echo -e "  ${RED}✗${NC} review_dispatcher: wf_mark did not record PR key"
  FAILED=1
fi

# --- multiple PRs: all processed sequentially ---
desc "multiple PRs"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":1},
 {"repository":{"nameWithOwner":"other/proj"},"number":7}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 processing multiple PRs"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 1" "review_dispatcher: dispatches first PR"
assert_contains "$(cat "$WORKER_LOG")" "other/proj 7" "review_dispatcher: dispatches second PR"
assert_contains "$OUT" "dispatched=2" "review_dispatcher: summary counts both dispatches"

# --- ledger idempotency: an already-seen PR is skipped (no dispatch) ---
desc "ledger idempotency"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"pr:owner/repo:99","ts":"2026-08-14T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/review_dispatcher.jsonl"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 when only match is already seen"
assert_contains "$OUT" "skipped=1" "review_dispatcher: summary counts the skip"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "review_dispatcher: already-seen PR is not dispatched"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-review-dispatcher" \
  "review_dispatcher: already-seen PR still has label removed"

# --- already-seen PR whose label cannot be removed is reported, not silently skipped ---
desc "already-seen label removal failure"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"pr:owner/repo:99","ts":"2026-08-14T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/review_dispatcher.jsonl"
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 when an already-seen PR cannot be de-labeled"
assert_contains "$OUT" "already-seen owner/repo#99" \
  "review_dispatcher: warns when an already-seen PR's label cannot be removed"
assert_contains "$OUT" "skipped=1" "review_dispatcher: still counts the skip"
assert_contains "$OUT" "failed=0" \
  "review_dispatcher: already-seen removal failure is not counted as a failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "review_dispatcher: already-seen PR is not dispatched when its label cannot be removed"

# --- label removal failure: skip and continue, label stays for retry, no dispatch ---
desc "label removal failure"
reset_state
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":55}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "review_dispatcher: exit 1 when all dispatches fail (label removal)"
assert_contains "$OUT" "WARNING" "review_dispatcher: warns on label removal failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "review_dispatcher: no dispatch when label removal fails"
if [ -f "$SHAI_HOME/ledgers/review_dispatcher.jsonl" ] &&
  grep -q '"pr:owner/repo:55"' "$SHAI_HOME/ledgers/review_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} review_dispatcher: should not mark ledger when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} review_dispatcher: ledger not marked when label removal fails"
fi

# --- worker failure: label already removed, ledger left unmarked for manual re-label retry ---
desc "worker failure leaves ledger unmarked"
reset_state
echo 1 >"$WORKER_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":77}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "review_dispatcher: exit 1 when all dispatches fail (worker failure)"
assert_contains "$OUT" "WARNING" "review_dispatcher: warns when worker fails"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-review-dispatcher" \
  "review_dispatcher: label was still removed before the failing worker ran"
if [ -f "$SHAI_HOME/ledgers/review_dispatcher.jsonl" ] &&
  grep -q '"pr:owner/repo:77"' "$SHAI_HOME/ledgers/review_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} review_dispatcher: should not mark ledger when worker fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} review_dispatcher: ledger not marked when worker fails"
fi

# --- input validation: malformed repo/number skipped ---
desc "input validation"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"../evil"},"number":1},
 {"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 when valid PR dispatched alongside invalid"
assert_contains "$OUT" "WARNING" "review_dispatcher: warns on invalid repo format"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "review_dispatcher: valid PR still dispatched after skipping invalid"

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
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
assert_contains "$OUT" "hit limit" \
  "review_dispatcher: warns when result count hits the search limit"

finish
