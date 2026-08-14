#!/bin/bash
# test_review_dispatcher.sh — unit tests for workflows/review_dispatcher/run.sh
# Covers: workflows/review_dispatcher/run.sh — idle tick, gh search failure, label removal
#   before dispatch, sequential processing, label-only dedup (no ledger), worker failure
#   leaving label removed, label-removal-failure skip-and-continue, and re-review support
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
echo 0 >"$EDIT_RC_FILE"
echo 0 >"$SEARCH_RC_FILE"
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search prs"*)
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
  rm -f "$WORKER_LOG" "$EDIT_LOG"
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

# --- gh search failure ---
desc "gh search failure"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
echo 1 >"$SEARCH_RC_FILE"
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "review_dispatcher: exit 1 when gh search fails"
assert_contains "$OUT" "ERROR" "review_dispatcher: prints ERROR on search failure"

# --- single PR: label removed before dispatch, then worker run, no ledger ---
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
if [ -f "$SHAI_HOME/ledgers/review_dispatcher.jsonl" ]; then
  echo -e "  ${RED}✗${NC} review_dispatcher: should not use ledger (label-only dedup)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} review_dispatcher: no ledger written (label-only dedup)"
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

# --- worker failure: label already removed, warns ---
desc "worker failure"
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

# --- re-review: same PR can be dispatched again (no ledger blocks it) ---
desc "re-review support"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
"$DIR/workflows/review_dispatcher/run.sh" >/dev/null 2>&1
rm -f "$WORKER_LOG"
OUT=$("$DIR/workflows/review_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "review_dispatcher: exit 0 on re-review dispatch"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "review_dispatcher: re-dispatches the same PR (no ledger dedup)"

finish
