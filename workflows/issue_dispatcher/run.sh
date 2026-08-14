#!/bin/bash
# issue_dispatcher/run.sh — poll GitHub for assigned issues and delegate each to issue_worker
# Usage: workflows/issue_dispatcher/run.sh
# Reads: gh auth from environment; searches open issues assigned to @me labeled shai-issue-dispatcher
# Writes: removes the shai-issue-dispatcher label; dispatches shai-workflow run issue_worker; ephemeral session log (prunable)
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

# Iterate matches as compact "repo<TAB>number" lines so a for-loop over word-split output
# can't be tripped up by whitespace, and each field survives intact.
while IFS=$'\t' read -r REPO NUMBER; do
  [ -n "$REPO" ] || continue

  KEY="issue:$REPO:$NUMBER"

  # Safety-net dedup: the label removal below is the primary guard, but a ledger hit means
  # this issue was already handed off in a prior tick before its label could be re-added.
  if wf_seen "$KEY"; then
    gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1 || true
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

  if env -u SHAI_POLICY_OVERLAY "$SHAI_WORKFLOW" run issue_worker "$REPO" "$NUMBER" </dev/null; then
    wf_mark "$KEY"
    DISPATCHED=$((DISPATCHED + 1))
    wf_output "dispatched $REPO#$NUMBER"
  else
    # Worker failed; the label is already gone, so wf_mark is intentionally skipped. A human
    # must re-apply the label to retry.
    wf_output "WARNING: issue_worker failed for $REPO#$NUMBER (re-label to retry)"
    FAILED=$((FAILED + 1))
  fi
done < <(printf '%s' "$SEARCH_JSON" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"')

wf_output "dispatched=$DISPATCHED skipped=$SKIPPED failed=$FAILED"
if [ "$FAILED" -gt 0 ] && [ "$DISPATCHED" -eq 0 ]; then
  exit 1
fi
exit 0
