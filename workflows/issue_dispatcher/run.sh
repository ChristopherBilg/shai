#!/bin/bash
# issue_dispatcher/run.sh — poll GitHub for assigned issues and delegate to issue_worker
# Usage: workflows/issue_dispatcher/run.sh
# Reads: gh auth from environment; issues assigned to @me with the shai-issue-worker label
# Writes: removes the shai-issue-worker label; per-issue ledger entries; ephemeral session log (prunable)
# Exit: 0 on success (including no matches); 1 on search failure
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

LABEL="shai-issue-worker"

wf_init

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

# Global search across all repos for open issues assigned to the authenticated user that
# carry the pickup label. --json emits an array of {repository:{nameWithOwner}, number}.
MATCHES=$(gh search issues --assignee @me --label "$LABEL" --state open \
  --json repository,number 2>/dev/null) ||
  wf_fail "gh search failed"

COUNT=$(printf '%s' "$MATCHES" | jq 'length' 2>/dev/null) || COUNT=0

if [ "${COUNT:-0}" -eq 0 ]; then
  wf_output "no matching issues"
  exit 0
fi

DISPATCHED=0
SKIPPED=0
FAILED=0

# Iterate the matches as TAB-separated repo/number pairs. jq -r keeps repo and number on one
# line so a single read splits them; no issue field can contain a tab or newline.
while IFS=$'\t' read -r REPO NUMBER; do
  [ -n "$REPO" ] || continue
  [ -n "$NUMBER" ] || continue

  KEY="issue:$REPO:$NUMBER"

  # Ledger safety net: skip anything already dispatched even if the label somehow lingers.
  if wf_seen "$KEY"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Remove the label before dispatch so a crashed worker never re-triggers on the next tick.
  # A failed removal leaves the label in place for a manual retry; skip and keep going.
  if ! gh issue edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
    wf_output "WARNING: could not remove label from $REPO#$NUMBER; skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Delegate the LLM work to issue_worker. On failure the label is already gone, so wf_mark
  # is intentionally NOT called — a maintainer must re-apply the label to retry.
  if "$DIR/shai-workflow" run issue_worker "$REPO" "$NUMBER"; then
    wf_mark "$KEY"
    DISPATCHED=$((DISPATCHED + 1))
    wf_output "dispatched $REPO#$NUMBER"
  else
    FAILED=$((FAILED + 1))
    wf_output "WARNING: issue_worker failed for $REPO#$NUMBER (label removed; re-label to retry)"
  fi
done < <(printf '%s' "$MATCHES" |
  jq -r '.[] | [.repository.nameWithOwner, (.number | tostring)] | @tsv')

wf_output "dispatched=$DISPATCHED skipped=$SKIPPED failed=$FAILED"
exit 0