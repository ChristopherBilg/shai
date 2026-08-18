#!/bin/bash
# ci/run.sh — run a configured CI check for the current repository
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .action and optional .check), $SHAI_HOME/ci.json, git remote
# Writes: check output or check listing to stdout
# Exit: 0 on success (including failed checks), 1 on tool-level error
set -euo pipefail
input="$1"

action=$(printf '%s' "$input" | jq -r '.action // empty' 2>/dev/null) || action=""
check=$(printf '%s' "$input" | jq -r '.check // empty' 2>/dev/null) || check=""

if [ "$action" != "list" ] && [ "$action" != "run" ]; then
  printf 'error: action must be "list" or "run" (got "%s")\n' "$action"
  exit 1
fi

if [ "$action" = "run" ] && [ -z "$check" ]; then
  echo "error: check name required when action is 'run'"
  exit 1
fi

config_file="${SHAI_HOME:-$HOME/.shai}/ci.json"
if [ ! -f "$config_file" ]; then
  echo "error: no CI config found at $config_file"
  echo "Create it with a repos map. Example:"
  echo '  {"version":"1.0","repos":{"github.com/owner/repo":{"checks":{"test":{"command":"npm test"}}}}}'
  exit 1
fi

if ! jq empty "$config_file" 2>/dev/null; then
  echo "error: $config_file is not valid JSON"
  exit 1
fi

remote=$(git remote get-url origin 2>/dev/null) || {
  echo "error: not in a git repository or no 'origin' remote"
  exit 1
}

normalize_url() {
  local url="$1"
  url="${url#https://}"
  url="${url#http://}"
  url="${url#git@}"
  url="${url%.git}"
  url="${url%/}"
  if [[ "$url" =~ ^([^/:]+):(.+)$ ]]; then
    url="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf '%s' "$url"
}

repo_key=$(normalize_url "$remote")

repo_exists=$(printf '%s' "$repo_key" | jq -Rsr --slurpfile cfg "$config_file" '$cfg[0].repos[.] // empty')
if [ -z "$repo_exists" ]; then
  printf 'error: repository "%s" not found in %s\n' "$repo_key" "$config_file"
  echo "Add it to the 'repos' map with your CI checks."
  exit 1
fi

if [ "$action" = "list" ]; then
  printf 'Available CI checks for %s:\n' "$repo_key"
  printf '%s' "$repo_key" | jq -Rsr --slurpfile cfg "$config_file" \
    '$cfg[0].repos[.].checks | to_entries[] | "  \(.key): \(.value.command)"'
  exit 0
fi

command=$(printf '%s' "$repo_key" | jq -Rsr --argjson cfg "$(cat "$config_file")" --arg c "$check" \
  '$cfg.repos[.].checks[$c].command // empty')
if [ -z "$command" ]; then
  printf 'error: check "%s" not found for %s\n' "$check" "$repo_key"
  echo "Available checks:"
  printf '%s' "$repo_key" | jq -Rsr --slurpfile cfg "$config_file" \
    '$cfg[0].repos[.].checks | keys[] | "  \(.)"'
  exit 1
fi

check_timeout=$(printf '%s' "$repo_key" | jq -Rsr --argjson cfg "$(cat "$config_file")" --arg c "$check" \
  '$cfg.repos[.].checks[$c].timeout // empty')
check_timeout="${check_timeout:-120}"

output=$(timeout "${check_timeout}s" bash -c "$command" 2>&1) && rc=$? || rc=$?

if [ "$rc" -eq 124 ]; then
  printf 'error: check "%s" timed out after %ss\n' "$check" "$check_timeout"
  [ -n "$output" ] && printf '%s\n' "$output"
  exit 1
fi

[ -n "$output" ] && printf '%s\n' "$output"
printf 'exit_code: %d\n' "$rc"
exit 0
