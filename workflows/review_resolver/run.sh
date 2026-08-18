#!/bin/bash
# review_resolver/run.sh — process PR review comments: classify and act on each
# Usage: workflows/review_resolver/run.sh <repo> <number>
# Reads: ANTHROPIC_API_KEY from environment; prompts/review_resolver.txt for LLM instructions
# Writes: commits/replies/issues/resolved threads on GitHub; ephemeral session log (prunable)
# Exit: 0 on success; 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: workflows/review_resolver/run.sh <repo> <number>\n' >&2
  exit 2
fi

REPO="$1"
NUMBER="$2"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || [[ "$REPO" == *..* ]]; then
  printf 'error: repo must be OWNER/REPO format (got "%s")\n' "$REPO" >&2
  exit 2
fi

if [[ ! "$NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  printf 'error: PR number must be a positive integer (got "%s")\n' "$NUMBER" >&2
  exit 2
fi

wf_init

# No wf_seen/wf_mark: this workflow is deliberately non-idempotent and safe to re-run.
# Dedup is the dispatcher's job (label removal before dispatch), same as pr_reviewer.

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" review_resolver) || wf_fail "cannot load prompts/review_resolver.txt"

OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" | sed "s/{{NUMBER}}/$NUMBER/g; s|{{REPO}}|$REPO|g; s/{{OWNER}}/$OWNER/g; s/{{REPO_NAME}}/$REPO_NAME/g")

RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error resolving reviews on PR #$NUMBER"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_output "resolved review comments on PR #$NUMBER on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
