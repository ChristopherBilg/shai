#!/bin/bash
# workflow.sh — shared helpers for shai workflow scripts
# Usage: source "$(dirname "$0")/../lib/workflow.sh"
set -uo pipefail

WF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DIR="$(cd "$WF_DIR/.." &>/dev/null && pwd)"

WF_NAME="${WF_NAME:-$(basename "${BASH_SOURCE[1]:-workflow}" .sh)}"

mint_id() {
  printf '%s_%s_%s' "$1" "$(date -u +%Y%m%dT%H%M%S)" "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

wf_init() {
  SHAI_SESSION_ID="$(mint_id sess)"
  export SHAI_SESSION_ID
  export SHAI_SCHEMA_VERSION="${SHAI_SCHEMA_VERSION:-1.0}"
  export SHAI_HOME="${SHAI_HOME:-$HOME/.shai}"

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
