#!/bin/bash
# jira_issue_view/run.sh — view a Jira issue via REST API
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .key); JIRA_BASE_URL, JIRA_USER_EMAIL, JIRA_API_TOKEN from environment
# Writes: formatted issue details to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
key=$(printf '%s' "$input" | jq -r '.key')

if [ -z "${JIRA_BASE_URL:-}" ]; then
  printf 'JIRA_BASE_URL not set'
  exit 1
fi
if [ -z "${JIRA_USER_EMAIL:-}" ]; then
  printf 'JIRA_USER_EMAIL not set'
  exit 1
fi
if [ -z "${JIRA_API_TOKEN:-}" ]; then
  printf 'JIRA_API_TOKEN not set'
  exit 1
fi

if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]+-[0-9]+$ ]]; then
  printf 'Invalid Jira key format: %s' "$key"
  exit 1
fi

url="${JIRA_BASE_URL%/}/rest/api/2/issue/$key"

result=$(timeout 30s curl -sS -w '\n%{http_code}' \
  -u "$JIRA_USER_EMAIL:$JIRA_API_TOKEN" \
  -H "Content-Type: application/json" \
  "$url" 2>&1) || {
  printf 'Request failed: %s' "$result"
  exit 1
}

http_code=$(printf '%s' "$result" | tail -n1)
body=$(printf '%s' "$result" | sed '$d')

if [ "$http_code" != "200" ]; then
  printf 'Jira API returned %s: %s' "$http_code" "$body"
  exit 1
fi

printf '%s' "$body" | jq -r '
  "Key:         \(.key)",
  "Summary:     \(.fields.summary // "n/a")",
  "Status:      \(.fields.status.name // "n/a")",
  "Assignee:    \(.fields.assignee.displayName // "Unassigned")",
  "Reporter:    \(.fields.reporter.displayName // "n/a")",
  "Priority:    \(.fields.priority.name // "n/a")",
  "Labels:      \((.fields.labels // []) | join(", ") | if . == "" then "none" else . end)",
  "Created:     \(.fields.created // "n/a")",
  "Updated:     \(.fields.updated // "n/a")",
  "",
  "Description:",
  ((.fields.description // "No description.") | if type == "string" then . else tostring end)'
