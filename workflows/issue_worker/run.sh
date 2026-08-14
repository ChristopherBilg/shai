#!/bin/bash
# issue_worker/run.sh — implement a GitHub issue and open a draft pull request
# Usage: workflows/issue_worker/run.sh <repo> <number>
# Reads: ANTHROPIC_API_KEY from environment; prompts/issue_worker.txt for LLM instructions
# Writes: draft GitHub pull request; ephemeral session log (prunable)
# Exit: 0 on success (including idempotent skip); 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../../lib/workflow.sh"

if [ "$#" -ne 2 ]; then
  printf 'Usage: workflows/issue_worker/run.sh <repo> <number>\n' >&2
  exit 2
fi

REPO="$1"
NUMBER="$2"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'error: repo must be OWNER/REPO format (got "%s")\n' "$REPO" >&2
  exit 2
fi

if [[ ! "$NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'error: issue number must be a positive integer (got "%s")\n' "$NUMBER" >&2
  exit 2
fi

wf_init

if wf_seen "issue:$REPO:$NUMBER"; then
  exit 0
fi

ISSUE_JSON=$(gh issue view "$NUMBER" --repo "$REPO" --json title,body,labels) ||
  wf_fail "cannot fetch issue #$NUMBER on $REPO"

ISSUE_TITLE=$(printf '%s' "$ISSUE_JSON" | jq -r '.title // ""')
ISSUE_BODY=$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')
# shellcheck disable=SC2016
ISSUE_LABELS=$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")')

SLUG=$(printf '%s' "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50 | sed 's/-$//')
BRANCH_NAME="shai/${NUMBER}-${SLUG}"

# Issue content is attacker-controlled (anyone who can open an issue) and is spliced
# straight into the prompt below rather than fetched by the model via a tool call, so it
# never gets shai-dispatch's automatic <external_data> truncation/sanitization. Bound the
# body's size (matching shai-dispatch's MAX_BYTES) and neutralize external_data tag syntax
# in all three fields (same regex shai-dispatch uses to sanitize tool_result content)
# before they reach prompts/issue_worker.txt's <external_data> fences, so injected content
# can't forge a closing tag and break out of the fence.
ISSUE_BODY=$(printf '%s' "$ISSUE_BODY" | cut -c1-32000)

ISSUE_TITLE=$(printf '%s' "$ISSUE_TITLE" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
ISSUE_BODY=$(printf '%s' "$ISSUE_BODY" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')
ISSUE_LABELS=$(printf '%s' "$ISSUE_LABELS" | jq -Rrs 'gsub("<\\s*/?\\s*external_data\\s*>?"; "[external_data]"; "i")')

WF_POLICY="$(dirname "$0")/policy.json"
if [ -f "$WF_POLICY" ]; then
  export SHAI_POLICY_OVERLAY="$WF_POLICY"
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" issue_worker) || wf_fail "cannot load prompts/issue_worker.txt"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" |
  sed "s/{{NUMBER}}/$NUMBER/g" |
  sed "s|{{REPO}}|$REPO|g" |
  sed "s|{{BRANCH_NAME}}|$BRANCH_NAME|g")

PROMPT="${PROMPT//\{\{ISSUE_TITLE\}\}/$ISSUE_TITLE}"
PROMPT="${PROMPT//\{\{ISSUE_BODY\}\}/$ISSUE_BODY}"
PROMPT="${PROMPT//\{\{ISSUE_LABELS\}\}/$ISSUE_LABELS}"

RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error implementing issue #$NUMBER"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_mark "issue:$REPO:$NUMBER"
  wf_output "implemented issue #$NUMBER on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
