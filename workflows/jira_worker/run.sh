#!/bin/bash
# jira_worker/run.sh — implement a Jira ticket and open a draft pull request
# Usage: workflows/jira_worker/run.sh <repo> <issue_key>
# Reads: DEEPSEEK_API_KEY from environment; prompts/jira_worker.txt for LLM instructions
# Writes: draft GitHub pull request; ephemeral session log (prunable)
# Exit: 0 on success; 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: workflows/jira_worker/run.sh <repo> <issue_key>\n' >&2
  exit 2
fi

REPO="$1"
ISSUE_KEY="$2"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'error: repo must be OWNER/REPO format (got "%s")\n' "$REPO" >&2
  exit 2
fi

if [[ ! "$ISSUE_KEY" =~ ^[A-Z]+-[1-9][0-9]*$ ]]; then
  printf 'error: issue key must be a Jira key like PROJ-123 (got "%s")\n' "$ISSUE_KEY" >&2
  exit 2
fi

wf_init

ISSUE_CONTENT=$(jira issue view "$ISSUE_KEY" --plain 2>&1) ||
  wf_fail "cannot fetch $ISSUE_KEY"

BRANCH_KEY=$(printf '%s' "$ISSUE_KEY" | tr '[:upper:]' '[:lower:]')
BRANCH_NAME="shai/${BRANCH_KEY}"

# Ticket content is attacker-controlled (anyone with edit access to the Jira project) and is
# spliced straight into the prompt below rather than fetched by the model via a tool call, so
# it never gets shai-dispatch's automatic [external_data] truncation/escaping. Bound its size
# (matching shai-dispatch's MAX_BYTES) and escape closing external_data tags (same pattern
# shai-dispatch uses to escape tool_result content) before it reaches prompts/jira_worker.txt's
# external_data fence, so injected content can't forge a closing tag and break out of the
# fence. The final `gsub("&"; "\\&")` backslash-escapes ampersands: the ${PROMPT//...}
# substitution below expands a bare `&` in the replacement to the whole matched text on
# bash 5.2+ (where the `patsub_replacement` shopt is on by default) and treats it
# literally on older bash, which would otherwise corrupt the escaped form into the
# {{ISSUE_CONTENT}} placeholder itself; `\&` renders a literal `&` on every bash
# version, so the escaping is cheap insurance across environments.
ISSUE_CONTENT=$(head -c 32000 <<<"$ISSUE_CONTENT")

ISSUE_CONTENT=$(printf '%s' "$ISSUE_CONTENT" | jq -Rrs 'gsub("<\\s*/\\s*external_data\\s*>"; "&lt;/external_data&gt;"; "i") | gsub("&"; "\\&")')

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" jira_worker) || wf_fail "cannot load prompts/jira_worker.txt"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" |
  sed "s|{{REPO}}|$REPO|g" |
  sed "s|{{BRANCH_NAME}}|$BRANCH_NAME|g" |
  sed "s/{{ISSUE_KEY}}/$ISSUE_KEY/g")

PROMPT="${PROMPT//\{\{ISSUE_CONTENT\}\}/$ISSUE_CONTENT}"

RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error implementing $ISSUE_KEY"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_suggest
  wf_output "implemented $ISSUE_KEY on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
