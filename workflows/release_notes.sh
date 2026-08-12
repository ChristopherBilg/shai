#!/bin/bash
# release_notes.sh — generate categorized release notes from merged PRs between two refs
# Usage: workflows/release_notes.sh <repo> <base> [head]
# Reads: ANTHROPIC_API_KEY from environment; prompts/release_notes.txt for LLM instructions
# Writes: markdown changelog to stdout; ephemeral session log (prunable)
# Exit: 0 on success (including no-change early exits); 1 on failure; 2 on usage error
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../lib/workflow.sh"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  printf 'Usage: release_notes.sh <repo> <base> [head]\n' >&2
  exit 2
fi

REPO="$1"
BASE="$2"
HEAD="${3:-}"

if [[ ! "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
  printf 'error: repo must be OWNER/REPO format (got "%s")\n' "$REPO" >&2
  exit 2
fi

if [ -z "$BASE" ]; then
  printf 'error: base ref must not be empty\n' >&2
  exit 2
fi

wf_init

if [ -z "$HEAD" ]; then
  HEAD=$(gh api "repos/$REPO" --jq '.default_branch') || wf_fail "cannot resolve default branch for $REPO"
fi

COMPARE=$(gh api "repos/$REPO/compare/$BASE...$HEAD") || wf_fail "cannot compare $BASE...$HEAD on $REPO"

# shellcheck disable=SC2016
COMMIT_COUNT=$(printf '%s' "$COMPARE" | jq '[.commits[].sha] | length')
if [ "$COMMIT_COUNT" -eq 0 ]; then
  printf '%s release_notes: no changes between %s and %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BASE" "$HEAD" >&2
  exit 0
fi

# shellcheck disable=SC2016
COMMIT_SHAS=$(printf '%s' "$COMPARE" | jq -r '[.commits[].sha] | join("\n")')
# shellcheck disable=SC2016
BASE_DATE=$(printf '%s' "$COMPARE" | jq -r '.merge_base_commit.commit.committer.date // empty' | cut -dT -f1)

if [ -z "$BASE_DATE" ]; then
  wf_fail "cannot extract merge base date from compare response"
fi

PR_JSON=$(gh pr list --repo "$REPO" --state merged \
  --json number,title,labels,author,mergedAt,mergeCommit \
  --limit 100 \
  --search "merged:>=$BASE_DATE") || wf_fail "cannot list merged PRs for $REPO"

# shellcheck disable=SC2016
PR_DATA=$(printf '%s' "$PR_JSON" | jq -r --arg shas "$COMMIT_SHAS" '
  ($shas | split("\n")) as $sha_list |
  [ .[] | select(.mergeCommit.oid as $oid | $sha_list | index($oid)) ] |
  .[] | "#\(.number) | \(.title) | \([.labels[].name] | join(", ")) | \(.author.login)"
')

if [ -z "$PR_DATA" ]; then
  printf '%s release_notes: no merged PRs found between %s and %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BASE" "$HEAD" >&2
  exit 0
fi

PROMPT_TEMPLATE=$("$DIR/shai-prompt" release_notes) || wf_fail "cannot load prompts/release_notes.txt"

PROMPT="${PROMPT_TEMPLATE//\{\{REPO\}\}/$REPO}"
PROMPT="${PROMPT//\{\{BASE\}\}/$BASE}"
PROMPT="${PROMPT//\{\{HEAD\}\}/$HEAD}"
PROMPT="${PROMPT//\{\{PR_DATA\}\}/$PR_DATA}"

RESULT=$(wf_llm "$PROMPT") || wf_fail "pipeline error generating release notes"

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  printf '%s' "$RESULT" | jq -r '.payload.content[] | select(.type == "text") | .text'
  wf_output "generated release notes for $REPO ($BASE...$HEAD)" >&2
  exit 0
else
  wf_fail "unexpected response: type=$TYPE source=$SOURCE"
fi
