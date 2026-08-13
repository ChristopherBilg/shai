#!/bin/bash
# workflow.sh — shared helpers for shai workflow scripts
# Usage: source "$(dirname "$0")/../lib/workflow.sh"
set -uo pipefail

WF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DIR="$(cd "$WF_DIR/.." &>/dev/null && pwd)"

WF_NAME="${WF_NAME:-$(basename "$(dirname "${BASH_SOURCE[1]:-workflow}")")}"

mint_id() {
  printf '%s_%s_%s' "$1" "$(date -u +%Y%m%dT%H%M%S)" "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

wf_init() {
  SHAI_SESSION_ID="$(mint_id sess)"
  export SHAI_SESSION_ID
  export SHAI_SCHEMA_VERSION="${SHAI_SCHEMA_VERSION:-1.0}"
  export SHAI_HOME="${SHAI_HOME:-$HOME/.shai}"
  export SHAI_RUN_ID=""
  export SHAI_SPAN_ID=""
  export SHAI_PARENT_SPAN_ID=""

  local sessions_dir="$SHAI_HOME/sessions"
  mkdir -p "$sessions_dir"

  local session_log="$sessions_dir/$SHAI_SESSION_ID.jsonl"
  : >"$sessions_dir/$SHAI_SESSION_ID.latest.json"

  "$DIR/shai-prompt" system | "$DIR/shai-read" --system | "$DIR/shai-stamp" >"$session_log"
}

wf_llm() {
  local prompt="${!#}"
  local flags=("${@:1:$#-1}")
  printf '%s' "$prompt" | "$DIR/shai-loop" "${flags[@]+"${flags[@]}"}"
}

wf_output() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WF_NAME" "$*"
}

wf_fail() {
  printf '%s %s ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WF_NAME" "$*" >&2
  exit 1
}

# wf_seen KEY: exit 0 if KEY was previously wf_mark'd for this $WF_NAME, exit 1 otherwise.
# -n/inputs streams the JSONL without loading the whole file; any() short-circuits on first
# match. Produces exactly one boolean, sidestepping jq -e's exit code 4 ("no output at
# all") that a bare `select | halt` would otherwise return for a miss.
wf_seen() {
  local ledger="$SHAI_HOME/ledgers/$WF_NAME.jsonl"
  [ -f "$ledger" ] || return 1
  jq -ne --arg k "$1" 'any(inputs; .key == $k)' "$ledger" >/dev/null 2>&1
}

# wf_mark KEY: append a ledger entry for KEY under this $WF_NAME (idempotent — a KEY
# already seen is a no-op, so double-marking never produces a duplicate line).
wf_mark() {
  local ledger_dir="$SHAI_HOME/ledgers"
  local ledger="$ledger_dir/$WF_NAME.jsonl"
  wf_seen "$1" && return 0
  mkdir -p "$ledger_dir"
  jq -nc --arg k "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SHAI_SESSION_ID" \
    '{key: $k, ts: $ts, session_id: $sid}' >>"$ledger"
}
