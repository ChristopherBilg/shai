#!/bin/bash
# issue_dispatcher/run.sh — poll GitHub for assigned issues and delegate each to issue_worker
# Usage: workflows/issue_dispatcher/run.sh
# Reads: gh auth from environment; searches open issues assigned to @me labeled shai-issue-dispatcher;
#   checks each issue's blocked_by dependencies via gh api --paginate (defers issues with open
#   blockers; fails loudly when the endpoint is missing)
# Writes: removes the shai-issue-dispatcher label; dispatches shai-workflow run issue_worker;
#   session files materialized only when a dispatch runs (idle ticks write nothing; prunable)
# Exit: 0 on success (including idle tick with no matches); 1 on failure
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

LABEL="shai-issue-dispatcher"

# The dispatcher shells out to `shai-workflow run issue_worker`. SHAI_WORKFLOW lets a test
# substitute a stub for the real binary; production leaves it unset and uses $DIR/shai-workflow.
SHAI_WORKFLOW="${SHAI_WORKFLOW:-$DIR/shai-workflow}"

wf_init

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

# Global search across every repo for open issues assigned to the authenticated user and
# carrying the shai-issue-dispatcher label. --json emits an array of {repository:{nameWithOwner},number}.
SEARCH_JSON=$(gh search issues --assignee @me --label "$LABEL" --state open --limit 100 --json repository,number) ||
  wf_fail "gh search failed"

COUNT=$(printf '%s' "$SEARCH_JSON" | jq 'length') ||
  wf_fail "failed to parse search results"

if [ "$COUNT" -eq 0 ]; then
  wf_output "no matching issues"
  exit 0
fi

DISPATCHED=0
SKIPPED=0
FAILED=0
BLOCKED=0

# Iterate matches as compact "repo<TAB>number" lines so a for-loop over word-split output
# can't be tripped up by whitespace, and each field survives intact.
while IFS=$'\t' read -r REPO NUMBER; do
  [ -n "$REPO" ] || continue

  KEY="issue:$REPO:$NUMBER"

  # Check dependencies — skip if any blocker is still open (label stays for next tick).
  # --paginate: blocked_by is paginated (30/page), so a blocker beyond the first page must
  # not be missed. The error output is captured (not discarded) so the warning says why.
  DEPS_JSON=$(gh api --paginate "repos/$REPO/issues/$NUMBER/dependencies/blocked_by" 2>&1) || {
    case "$DEPS_JSON" in
      *"HTTP 404"* | *"HTTP 410"*)
        # Endpoint missing (e.g. older GHES) — deferring would stall dispatch forever while
        # still exiting 0, so surface it as a failure instead of a silent indefinite block
        wf_output "WARNING: dependency endpoint unavailable for $REPO#$NUMBER: $DEPS_JSON"
        FAILED=$((FAILED + 1))
        ;;
      *)
        wf_output "WARNING: could not check dependencies for $REPO#$NUMBER, deferring${DEPS_JSON:+: $DEPS_JSON}"
        BLOCKED=$((BLOCKED + 1))
        ;;
    esac
    continue
  }
  OPEN_DEPS=$(printf '%s' "$DEPS_JSON" | jq '[.[] | select(.state != "closed")] | length') || {
    wf_output "WARNING: could not parse dependencies for $REPO#$NUMBER, deferring"
    BLOCKED=$((BLOCKED + 1))
    continue
  }
  if [ "$OPEN_DEPS" -gt 0 ]; then
    BLOCKED=$((BLOCKED + 1))
    continue
  fi

  # Safety-net dedup: the label removal below is the primary guard, but a ledger hit means
  # this issue was already handed off in a prior tick before its label could be re-added.
  if wf_seen "$KEY"; then
    # A permanent removal failure here (e.g. lost triage permission) would otherwise make the
    # issue silently re-appear as skipped=1 on every tick, so surface it.
    if ! gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
      wf_output "WARNING: could not remove label from already-seen $REPO#$NUMBER, it will re-appear next tick"
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Remove the label *before* dispatch so a crashed or failing worker never leaves the issue
  # eligible for reprocessing. A retry requires re-applying the label by hand.
  if ! gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
    wf_output "WARNING: could not remove label from $REPO#$NUMBER, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Materialize the session for a tick that actually dispatches (#388): wf_init only mints
  # the id, so an idle tick writes nothing under $SHAI_HOME/sessions/. Seeding here — at the
  # first real dispatch — keeps the system prompt as the session's first event. A failed seed
  # must not abort the tick under `set -e`: the label is already removed (pre-#388 the same
  # failure aborted in wf_init before any `gh` mutation), so record the failure, skip this
  # item, and keep going — a human must re-apply the label to retry, as with a worker failure.
  if ! wf_seed_session; then
    # shellcheck source=lib/failure.sh
    source "$DIR/lib/failure.sh"
    fail_record "workflow_error" "could not materialize session for $REPO#$NUMBER" \
      '{"script":"wf_seed_session","detail":"re-label to retry"}'
    wf_output "WARNING: could not materialize session for $REPO#$NUMBER (re-label to retry)"
    FAILED=$((FAILED + 1))
    continue
  fi
  if env -u SHAI_POLICY_OVERLAY "$SHAI_WORKFLOW" run issue_worker "$REPO" "$NUMBER" </dev/null; then
    wf_mark "$KEY"
    DISPATCHED=$((DISPATCHED + 1))
    wf_output "dispatched $REPO#$NUMBER"
  else
    # Worker failed; the label is already gone, so wf_mark is intentionally skipped. A human
    # must re-apply the label to retry.
    # shellcheck source=lib/failure.sh
    source "$DIR/lib/failure.sh"
    fail_record "workflow_error" "worker failed for $REPO#$NUMBER" \
      '{"script":"issue_worker","detail":"re-label to retry"}'
    wf_output "WARNING: issue_worker failed for $REPO#$NUMBER (re-label to retry)"
    FAILED=$((FAILED + 1))
  fi
done < <(printf '%s' "$SEARCH_JSON" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"')

wf_output "dispatched=$DISPATCHED skipped=$SKIPPED failed=$FAILED blocked=$BLOCKED"
if [ "$FAILED" -gt 0 ] && [ "$DISPATCHED" -eq 0 ]; then
  exit 1
fi
exit 0
