#!/bin/bash
# pr_review.sh — review a GitHub pull request via LLM and post a draft review
# Usage: workflows/pr_review.sh <number> [--repo OWNER/REPO] [-q|--quiet]
# Reads: ANTHROPIC_API_KEY from environment; prompts/pr_review.txt for review instructions
# Writes: pending GitHub review with inline comments; ephemeral session log (prunable)
# Exit: 0 on success; 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../lib/workflow.sh"

NUMBER=""
REPO=""
QUIET=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -lt 2 ] && {
        printf 'error: --repo requires OWNER/REPO\n' >&2
        exit 2
      }
      REPO="$2"
      shift 2
      ;;
    -q | --quiet)
      QUIET=true
      shift
      ;;
    -*)
      printf 'error: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -z "$NUMBER" ]; then
        NUMBER="$1"
      else
        printf 'error: unexpected argument: %s\n' "$1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$NUMBER" ]; then
  printf 'Usage: pr_review.sh <number> [--repo OWNER/REPO]\n' >&2
  exit 2
fi

if [[ ! "$NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'error: PR number must be a positive integer (got "%s")\n' "$NUMBER" >&2
  exit 2
fi

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>&1) || {
    printf 'error: cannot determine repository (pass --repo OWNER/REPO): %s\n' "$REPO" >&2
    exit 1
  }
fi

wf_init

PROMPT_TEMPLATE=$("$DIR/shai-prompt" pr_review) || wf_fail "cannot load prompts/pr_review.txt"

PROMPT=$(printf '%s' "$PROMPT_TEMPLATE" | sed "s/{{NUMBER}}/$NUMBER/g; s|{{REPO}}|$REPO|g")

if "$QUIET"; then
  RESULT=$(wf_llm --tools "$PROMPT" 2>/dev/null) || wf_fail "pipeline error reviewing PR #$NUMBER"
else
  RESULT=$(wf_llm --tools "$PROMPT") || wf_fail "pipeline error reviewing PR #$NUMBER"
fi

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  wf_output "reviewed PR #$NUMBER on $REPO"
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
