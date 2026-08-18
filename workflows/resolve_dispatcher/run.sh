#!/bin/bash
# resolve_dispatcher/run.sh — poll GitHub for reviewed PRs and delegate each to review_resolver
# Usage: workflows/resolve_dispatcher/run.sh
# Reads: gh auth from environment; searches open PRs labeled shai-resolve-dispatcher involving @me
# Writes: removes the shai-resolve-dispatcher label; dispatches shai-workflow run review_resolver; ephemeral session log (prunable)
# Exit: 0 on success (including idle tick with no matches); 1 on failure
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

LABEL="shai-resolve-dispatcher"
SEARCH_LIMIT=100

# The dispatcher shells out to `shai-workflow run review_resolver`. SHAI_WORKFLOW lets a test
# substitute a stub for the real binary; production leaves it unset and uses $DIR/shai-workflow.
SHAI_WORKFLOW="${SHAI_WORKFLOW:-$DIR/shai-workflow}"

wf_init

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

# Global search for open PRs the authenticated user is involved in (author or reviewer) that
# carry the shai-resolve-dispatcher label — added by pr_reviewer once its review is posted.
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

# Iterate matches as compact "repo<TAB>number" lines so a for-loop over word-split output
# can't be tripped up by whitespace, and each field survives intact.
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

  KEY="resolve:$REPO:$NUMBER"

  # Safety-net dedup: the label removal below is the primary guard, but GitHub search is
  # eventually consistent, so a just-dispatched PR can still show up on the next tick.
  if wf_seen "$KEY"; then
    gh pr edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1 || true
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Remove the label *before* dispatch so a crashed or failing worker never leaves the PR
  # eligible for reprocessing. A retry requires re-applying the label by hand.
  if ! gh pr edit "$NUMBER" --repo "$REPO" --remove-label "$LABEL" >/dev/null 2>&1; then
    wf_output "WARNING: could not remove label from $REPO#$NUMBER, skipping"
    FAILED=$((FAILED + 1))
    continue
  fi

  if env -u SHAI_POLICY_OVERLAY "$SHAI_WORKFLOW" run review_resolver "$REPO" "$NUMBER" </dev/null; then
    wf_mark "$KEY"
    DISPATCHED=$((DISPATCHED + 1))
    wf_output "dispatched $REPO#$NUMBER"
  else
    # Worker failed; the label is already gone, so wf_mark is intentionally skipped. A human
    # must re-apply the label to retry.
    wf_output "WARNING: review_resolver failed for $REPO#$NUMBER (re-label to retry)"
    FAILED=$((FAILED + 1))
  fi
done < <(printf '%s' "$SEARCH_JSON" | jq -r '.[] | "\(.repository.nameWithOwner)\t\(.number)"')

wf_output "dispatched=$DISPATCHED skipped=$SKIPPED failed=$FAILED"
if [ "$FAILED" -gt 0 ] && [ "$DISPATCHED" -eq 0 ]; then
  exit 1
fi
exit 0
