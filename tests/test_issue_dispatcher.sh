#!/bin/bash
# test_issue_dispatcher.sh — unit tests for workflows/issue_dispatcher/run.sh
# Covers: workflows/issue_dispatcher/run.sh — idle tick, gh search failure, label removal
#   before dispatch, sequential processing, dual idempotency (label + ledger), worker
#   failure leaving ledger unmarked, and label-removal-failure skip-and-continue
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/issue_dispatcher/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

make_stub_bin

# A shai-workflow stub records each `run issue_worker <repo> <number>` invocation to a log
# and returns a configurable exit code (default 0). Tests point SHAI_WORKFLOW at it.
WORKER_LOG="$TMP/worker.log"
WORKER_RC_FILE="$TMP/worker_rc"
echo 0 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
# args: run issue_worker <repo> <number>
if [ "\$1" = "run" ] && [ "\$2" = "issue_worker" ]; then
  printf '%s %s\n' "\$3" "\$4" >>"$WORKER_LOG"
  [ -z "\${SHAI_POLICY_OVERLAY:-}" ] || printf 'OVERLAY=%s\n' "\$SHAI_POLICY_OVERLAY" >>"$WORKER_LOG"
fi
exit "\$(cat "$WORKER_RC_FILE")"
WFSTUB
chmod +x "$STUB/shai-workflow"
export SHAI_WORKFLOW="$STUB/shai-workflow"

# A gh stub whose behavior for `search issues` is driven by a fixture file, and which records
# `issue edit ... --remove-label` calls to a log. `edit` returns a configurable exit code.
SEARCH_FIXTURE="$TMP/search.json"
EDIT_LOG="$TMP/edit.log"
EDIT_RC_FILE="$TMP/edit_rc"
SEARCH_RC_FILE="$TMP/search_rc"
echo 0 >"$EDIT_RC_FILE"
echo 0 >"$SEARCH_RC_FILE"
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search issues"*)
    rc="\$(cat "$SEARCH_RC_FILE")"
    [ "\$rc" = "0" ] || exit "\$rc"
    cat "$SEARCH_FIXTURE"
    ;;
  "issue edit"*)
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
  rm -f "$WORKER_LOG" "$EDIT_LOG"
  rm -rf "$SHAI_HOME/ledgers"
  echo 0 >"$WORKER_RC_FILE"
  echo 0 >"$EDIT_RC_FILE"
  echo 0 >"$SEARCH_RC_FILE"
}

# --- idle tick: no matching issues ---
desc "idle tick"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when no issues match"
assert_contains "$OUT" "no matching issues" "issue_dispatcher: reports idle tick"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no worker dispatched on idle tick"

# --- gh search failure ---
desc "gh search failure"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
echo 1 >"$SEARCH_RC_FILE"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when gh search fails"
assert_contains "$OUT" "ERROR" "issue_dispatcher: prints ERROR on search failure"

# --- single issue: label removed before dispatch, then worker run, then ledger marked ---
desc "single issue happy path"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 on successful dispatch"
assert_contains "$OUT" "dispatched owner/repo#42" "issue_dispatcher: logs the dispatch"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-worker" \
  "issue_dispatcher: removes the shai-issue-worker label"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "issue_dispatcher: delegates to issue_worker with repo and number"
assert_eq "$(grep -c 'OVERLAY=' "$WORKER_LOG" 2>/dev/null || true)" "0" \
  "issue_dispatcher: worker does not inherit SHAI_POLICY_OVERLAY"
LEDGER="$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
if [ -f "$LEDGER" ] && grep -q '"issue:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: wf_mark recorded issue key on success"
else
  echo -e "  ${RED}✗${NC} issue_dispatcher: wf_mark did not record issue key"
  FAILED=1
fi

# --- multiple issues: all processed sequentially ---
desc "multiple issues"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":1},
 {"repository":{"nameWithOwner":"other/proj"},"number":7}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 processing multiple issues"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 1" "issue_dispatcher: dispatches first issue"
assert_contains "$(cat "$WORKER_LOG")" "other/proj 7" "issue_dispatcher: dispatches second issue"
assert_contains "$OUT" "dispatched=2" "issue_dispatcher: summary counts both dispatches"

# --- ledger idempotency: an already-seen issue is skipped (no label edit, no worker) ---
desc "ledger idempotency"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"issue:owner/repo:99","ts":"2026-08-13T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when only match is already seen"
assert_contains "$OUT" "skipped=1" "issue_dispatcher: summary counts the skip"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: already-seen issue is not dispatched"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-worker" \
  "issue_dispatcher: already-seen issue still has label removed"

# --- label removal failure: skip and continue, label stays for retry, no dispatch ---
desc "label removal failure"
reset_state
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":55}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when all dispatches fail (label removal)"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on label removal failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no dispatch when label removal fails"
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
  grep -q '"issue:owner/repo:55"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: should not mark ledger when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: ledger not marked when label removal fails"
fi

# --- worker failure: label already removed, ledger left unmarked for manual re-label retry ---
desc "worker failure leaves ledger unmarked"
reset_state
echo 1 >"$WORKER_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":77}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when all dispatches fail (worker failure)"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns when worker fails"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-worker" \
  "issue_dispatcher: label was still removed before the failing worker ran"
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
  grep -q '"issue:owner/repo:77"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: should not mark ledger when worker fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: ledger not marked when worker fails"
fi

finish
