#!/bin/bash
# pr_reviewer/run.sh — review a GitHub pull request via LLM and post a comment review
# Usage: workflows/pr_reviewer/run.sh <repo> <number>
# Reads: ANTHROPIC_API_KEY from environment; prompts/pr_reviewer.txt for review instructions
# Writes: GitHub comment review with inline comments; ephemeral session log (prunable)
# Exit: 0 on success; 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: workflows/pr_reviewer/run.sh <repo> <number>\n' >&2
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

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" pr_reviewer) || wf_fail "cannot load prompts/pr_reviewer.txt"

OWNER="${REPO%%/*}"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" | sed "s/{{NUMBER}}/$NUMBER/g; s|{{REPO}}|$REPO|g; s/{{OWNER}}/$OWNER/g")

RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error reviewing PR #$NUMBER"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_output "reviewed PR #$NUMBER on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
