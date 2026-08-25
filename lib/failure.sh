#!/bin/bash
# failure.sh — record structured failure data to $SHAI_HOME/failures/<workflow>.jsonl
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/failure.sh"
set -uo pipefail

# fail_record "category" "summary" ['context_json']
#
# Append one JSONL failure record to $SHAI_HOME/failures/<workflow>.jsonl:
#
#   {"ts": "...", "workflow": "...", "run_id": "..."|null, "session_id": "..."|null,
#    "category": "...", "summary": "...", "context": {...}}
#
# Workflow name resolution (first non-empty wins):
#   $WF_NAME -> $SHAI_FAILURE_WORKFLOW -> "_repl" (when $SHAI_SESSION_ID is set) -> "_manual"
#
# run_id/session_id come from the ambient trace context ($SHAI_RUN_ID, $SHAI_SESSION_ID)
# and are null when unset. context_json is optional (defaults to {}); a value that is not
# valid JSON — or a valid JSON value that is not an object — is stored as
# {"raw":"<escaped original>"}, so the documented context: object schema always holds and
# a record is never dropped.
#
# Invariant: fail_record never fails the caller — every failure path warns on stderr and
# returns 0, so a caller under `set -e` can call it as a bare command. The failures/
# directory is created on first write; no locking is used (JSONL appends under the OS page
# size are atomic on Linux, the same assumption the ledgers make).
fail_record() {
  local category="${1:-}" summary="${2:-}" context_json="${3:-}"
  local ts workflow home file line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$context_json" ] || context_json='{}'

  if [ -n "${WF_NAME:-}" ]; then
    workflow="$WF_NAME"
  elif [ -n "${SHAI_FAILURE_WORKFLOW:-}" ]; then
    workflow="$SHAI_FAILURE_WORKFLOW"
  elif [ -n "${SHAI_SESSION_ID:-}" ]; then
    workflow="_repl"
  else
    workflow="_manual"
  fi

  home="${SHAI_HOME:-$HOME/.shai}"
  file="$home/failures/$workflow.jsonl"

  mkdir -p "$(dirname "$file")" 2>/dev/null || {
    printf 'fail_record: cannot create failures directory %s\n' "$(dirname "$file")" >&2
    return 0
  }

  # A context_json that jq cannot parse as JSON — or that parses to a non-object — falls
  # back to {"raw": ...} (escaped by jq itself), so the record is always written and the
  # documented context: object schema always holds. Both invocations live in condition
  # context so a failing jq cannot trip a `set -e` caller.
  if line=$(jq -nc \
    --arg ts "$ts" \
    --arg workflow "$workflow" \
    --arg run_id "${SHAI_RUN_ID:-}" \
    --arg session_id "${SHAI_SESSION_ID:-}" \
    --arg category "$category" \
    --arg summary "$summary" \
    --argjson context "$context_json" '
      def nullable: if . == "" then null else . end;
      {ts: ($ts | nullable),
       workflow: $workflow,
       run_id: ($run_id | nullable),
       session_id: ($session_id | nullable),
       category: $category,
       summary: $summary,
       context: (if ($context | type) == "object" then $context else {raw: ($context | tojson)} end)}' 2>/dev/null); then
    :
  elif line=$(jq -nc \
    --arg ts "$ts" \
    --arg workflow "$workflow" \
    --arg run_id "${SHAI_RUN_ID:-}" \
    --arg session_id "${SHAI_SESSION_ID:-}" \
    --arg category "$category" \
    --arg summary "$summary" \
    --arg raw "$context_json" '
      def nullable: if . == "" then null else . end;
      {ts: ($ts | nullable),
       workflow: $workflow,
       run_id: ($run_id | nullable),
       session_id: ($session_id | nullable),
       category: $category,
       summary: $summary,
       context: {raw: $raw}}' 2>/dev/null); then
    :
  else
    printf 'fail_record: cannot encode failure record\n' >&2
    return 0
  fi

  printf '%s\n' "$line" >>"$file" 2>/dev/null || {
    printf 'fail_record: cannot append to %s\n' "$file" >&2
  }
  return 0
}
