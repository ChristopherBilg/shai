#!/bin/bash
# review_dispatcher/run.sh — poll GitHub for labeled PRs and delegate each to pr_reviewer
# Usage: workflows/review_dispatcher/run.sh
# Reads: gh auth from environment; searches open PRs labeled shai-review-dispatcher involving @me
# Writes: removes the shai-review-dispatcher label; dispatches shai-workflow run pr_reviewer; ephemeral session log (prunable)
# Exit: 0 on success (including idle tick with no matches); 1 on failure
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

LABEL="shai-review-dispatcher"
SEARCH_LIMIT=100

SHAI_WORKFLOW="${SHAI_WORKFLOW:-$DIR/shai-workflow}"

wf_init

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

SEARCH_JSON=$(gh search prs --involves @me --label "$LABEL" --state open --limit "$SEARCH_LIMIT" --json repository,number) ||
  wf_fail "gh search failed"

COUNT=$(printf '%s' "$SEARCH_JSON" | jq 'length') ||
  wf_fail "failed to parse search results"

if [ "$COUNT" -eq 0 ]; then
  wf_output "no matching PRs"
  exit 0
fi

if [ "$COUNT" -ge "$SEARCH_LIMIT" ]; then
  wf_output "WARNING: result count ($COUNT) hit limit ($SEARCH_LIMIT), some PRs may have been dropped"
fi

DISPATCHED=0
SKIPPED=0
FAILED=0

while IFS=$'\t' read -r REPO NUMBER; do
  [ -n "$REPO" ] || continue

  if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "$REPO" == *..* ]]; then
    wf_output "WARNING: invalid repo format '$REPO', skipping"
    FAILED=$((FAILED + 1))
    continue
  fi
  if [[ ! "$NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    wf_output "WARNING: invalid PR number '$NUMBER', skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  KEY="pr:$REPO:$NUMBER"

  if wf_seen "$KEY"; then
    # A permanent removal failure here (e.g. lost triage permission) would otherwise make the
    # PR silently re-appear as skipped=1 on every tick, so surface it.
    if ! gh pr edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
      wf_output "WARNING: could not remove label from already-seen $REPO#$NUMBER, it will re-appear next tick"
    fi
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! gh pr edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
    wf_output "WARNING: could not remove label from $REPO#$NUMBER, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  if env -u SHAI_POLICY_OVERLAY "$SHAI_WORKFLOW" run pr_reviewer "$REPO" "$NUMBER" </dev/null; then
    wf_mark "$KEY"
    DISPATCHED=$((DISPATCHED + 1))
    wf_output "dispatched $REPO#$NUMBER"
  else
    wf_output "WARNING: pr_reviewer failed for $REPO#$NUMBER (re-label to retry)"
    FAILED=$((FAILED + 1))
  fi
done < <(printf '%s' "$SEARCH_JSON" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"')

wf_output "dispatched=$DISPATCHED skipped=$SKIPPED failed=$FAILED"
if [ "$FAILED" -gt 0 ] && [ "$DISPATCHED" -eq 0 ]; then
  exit 1
fi
exit 0
