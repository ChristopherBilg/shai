#!/bin/bash
# test_issue_dispatcher.sh — unit tests for workflows/issue_dispatcher/run.sh
# Covers: workflows/issue_dispatcher/run.sh — no-match idle tick, search failure, label
#   removal before dispatch, ledger idempotency, per-issue error isolation, multi-issue loop
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/issue_dispatcher/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

make_stub_bin

# write_dispatcher_gh_stub <search_json>: gh stub whose `search issues` returns the given
# JSON, records every `issue edit` invocation to $STUB/edits.log, and can be told to fail a
# specific issue's label removal via $STUB/fail_edit (matched against "<repo> <number>").
write_dispatcher_gh_stub() {
  local search_json="$1"
  printf '%s' "$search_json" >"$STUB/.search_json"
  rm -f "$STUB/edits.log"
  cat >"$STUB/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
  "search issues"*)
    cat "$(dirname "$0")/.search_json"
    ;;
  "issue edit"*)
    # args: issue edit <number> --repo <repo> --remove-label <label>
    number="$3"
    repo=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--repo" ] && repo="$a"
      prev="$a"
    done
    echo "$repo $number" >>"$(dirname "$0")/edits.log"
    if [ -f "$(dirname "$0")/fail_edit" ] && grep -qx "$repo $number" "$(dirname "$0")/fail_edit"; then
      exit 1
    fi
    echo "edited"
    ;;
  *)
    echo "stub gh: $*"
    ;;
esac
GHSTUB
  chmod +x "$STUB/gh"
}

# write_worker_stub: a fake shai-workflow that records dispatches and honors $STUB/fail_worker
# (matched against "<repo> <number>") to simulate an issue_worker failure.
write_worker_stub() {
  rm -f "$STUB/dispatches.log"
  cat >"$STUB/shai-workflow" <<'WFSTUB'
#!/bin/bash
# args: run issue_worker <repo> <number>
if [ "$1" = "run" ] && [ "$2" = "issue_worker" ]; then
  repo="$3"
  number="$4"
  echo "$repo $number" >>"$(dirname "$0")/dispatches.log"
  if [ -f "$(dirname "$0")/fail_worker" ] && grep -qx "$repo $number" "$(dirname "$0")/fail_worker"; then
    exit 1
  fi
  exit 0
fi
exit 0
WFSTUB
  chmod +x "$STUB/shai-workflow"
}

# The workflow invokes "$DIR/shai-workflow"; override DIR so it resolves to our stub.
run_dispatcher() {
  DIR="$STUB" "$DIR/workflows/issue_dispatcher/run.sh" "$@"
}

# --- no matching issues: normal idle tick ---
desc "no matching issues"
write_dispatcher_gh_stub '[]'
write_worker_stub
OUT=$(run_dispatcher 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when no issues match"
assert_contains "$OUT" "no matching issues" "issue_dispatcher: reports idle tick"
if [ -f "$STUB/dispatches.log" ]; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: no dispatch on empty search"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: no dispatch on empty search"
fi

# --- gh search failure ---
desc "gh search failure"
cat >"$STUB/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
  "search issues"*) exit 1 ;;
  *) echo "stub gh: $*" ;;
esac
GHSTUB
chmod +x "$STUB/gh"
write_worker_stub
OUT=$(run_dispatcher 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 on gh search failure"
assert_contains "$OUT" "ERROR" "issue_dispatcher: prints ERROR on search failure"

# --- single issue: label removed before dispatch, then marked ---
desc "single issue dispatch"
rm -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
write_dispatcher_gh_stub '[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]'
write_worker_stub
OUT=$(run_dispatcher 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 on successful dispatch"
assert_contains "$OUT" "dispatched owner/repo#42" "issue_dispatcher: reports the dispatched issue"
assert_contains "$(cat "$STUB/edits.log" 2>/dev/null)" "owner/repo 42" \
  "issue_dispatcher: label removal called for the issue"
assert_contains "$(cat "$STUB/dispatches.log" 2>/dev/null)" "owner/repo 42" \
  "issue_dispatcher: issue_worker dispatched for the issue"
LEDGER="$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
if [ -f "$LEDGER" ] && grep -q '"issue:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: wf_mark recorded issue key after success"
else
  echo -e "  ${RED}✗${NC} issue_dispatcher: wf_mark did not record issue key"
  FAILED=1
fi

# --- idempotency: already-marked issue is skipped (no label edit, no dispatch) ---
desc "ledger idempotency"
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"issue:owner/repo:99","ts":"2026-08-13T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
write_dispatcher_gh_stub '[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]'
write_worker_stub
OUT=$(run_dispatcher 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when only match is already seen"
assert_contains "$OUT" "skipped=1" "issue_dispatcher: counts the skipped issue"
if [ -f "$STUB/edits.log" ]; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: no label edit for already-seen issue"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: no label edit for already-seen issue"
fi
if [ -f "$STUB/dispatches.log" ]; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: no dispatch for already-seen issue"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: no dispatch for already-seen issue"
fi
rm -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"

# --- label removal failure: issue skipped, not dispatched, label left for retry ---
desc "label removal failure"
write_dispatcher_gh_stub '[{"repository":{"nameWithOwner":"owner/repo"},"number":7}]'
write_worker_stub
printf 'owner/repo 7\n' >"$STUB/fail_edit"
OUT=$(run_dispatcher 2>&1)
RC=$?
rm -f "$STUB/fail_edit"
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when label removal fails"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on label removal failure"
if [ -f "$STUB/dispatches.log" ]; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: no dispatch when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: no dispatch when label removal fails"
fi
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ]; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: no ledger mark when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: no ledger mark when label removal fails"
fi

# --- worker failure: label already removed, NOT marked (manual re-label to retry) ---
desc "issue_worker failure"
write_dispatcher_gh_stub '[{"repository":{"nameWithOwner":"owner/repo"},"number":8}]'
write_worker_stub
printf 'owner/repo 8\n' >"$STUB/fail_worker"
OUT=$(run_dispatcher 2>&1)
RC=$?
rm -f "$STUB/fail_worker"
assert_eq "$RC" "0" "issue_dispatcher: exit 0 even when a worker fails"
assert_contains "$(cat "$STUB/edits.log" 2>/dev/null)" "owner/repo 8" \
  "issue_dispatcher: label removed before the worker failed"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on worker failure"
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
  grep -q '"issue:owner/repo:8"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: worker failure must not be marked in ledger"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: worker failure not marked in ledger"
fi
rm -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"

# --- multiple issues: sequential loop processes each and reports a summary ---
desc "multiple issues"
write_dispatcher_gh_stub '[{"repository":{"nameWithOwner":"a/b"},"number":1},{"repository":{"nameWithOwner":"c/d"},"number":2},{"repository":{"nameWithOwner":"e/f"},"number":3}]'
write_worker_stub
OUT=$(run_dispatcher 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 for multiple issues"
assert_contains "$OUT" "dispatched=3" "issue_dispatcher: summary counts all dispatched issues"
DISP="$(cat "$STUB/dispatches.log" 2>/dev/null)"
assert_contains "$DISP" "a/b 1" "issue_dispatcher: first issue dispatched"
assert_contains "$DISP" "c/d 2" "issue_dispatcher: second issue dispatched"
assert_contains "$DISP" "e/f 3" "issue_dispatcher: third issue dispatched"

finish