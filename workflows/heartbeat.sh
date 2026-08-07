#!/bin/bash
# heartbeat.sh — exercise the full pipeline and report pass/fail
# Usage: workflows/heartbeat.sh
# Reads: ANTHROPIC_API_KEY from environment
# Writes: timestamped pass/fail line to stderr; ephemeral session log (prunable)
# Exit: 0 on pipeline success; 1 on pipeline failure
set -euo pipefail
# shellcheck source=lib/workflow.sh
source "$(dirname "$0")/../lib/workflow.sh"

wf_init

RESULT=$(wf_llm --quiet "Respond with the single word OK" 2>/dev/null) || {
  printf '%s FAIL heartbeat: pipeline error\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  exit 1
}

TYPE=$(printf '%s' "$RESULT" | jq -r '.type // empty' 2>/dev/null) || TYPE=""
SOURCE=$(printf '%s' "$RESULT" | jq -r '.source // empty' 2>/dev/null) || SOURCE=""

if [ "$TYPE" = "message" ] && [ "$SOURCE" = "assistant" ]; then
  printf '%s PASS heartbeat\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
  exit 0
else
  printf '%s FAIL heartbeat: type=%s source=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TYPE" "$SOURCE" >&2
  exit 1
fi
