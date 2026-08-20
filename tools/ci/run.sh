#!/bin/bash
# ci/run.sh — run a configured CI check for a repository
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .action, optional .check and .cwd), $SHAI_HOME/ci.json, git remote
# Writes: check output or check listing to stdout
# Exit: 0 on success (including failed checks), 1 on tool-level error
# The check runs in an environment scrubbed of every exported SHAI_* variable and the API keys
# (PATH/HOME/LANG/TERM survive), so the repository-under-test cannot observe the agent that
# dispatched the tool; a per-check "env" map in ci.json re-injects variables explicitly.
set -euo pipefail
input="$1"

action=$(printf '%s' "$input" | jq -r '.action // empty' 2>/dev/null) || action=""
check=$(printf '%s' "$input" | jq -r '.check // empty' 2>/dev/null) || check=""
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""

if [ "$action" != "list" ] && [ "$action" != "run" ]; then
  printf 'error: action must be "list" or "run" (got "%s")\n' "$action"
  exit 1
fi

if [ "$action" = "run" ] && [ -z "$check" ]; then
  echo "error: check name required when action is 'run'"
  exit 1
fi

# Repo detection and the check command both run in $cwd when given, so workflows that
# clone elsewhere (e.g. /tmp) can point the tool at their checkout instead of shai's own.
if [ -n "$cwd" ]; then
  if [ ! -d "$cwd" ]; then
    printf 'error: cwd "%s" is not a directory\n' "$cwd"
    exit 1
  fi
  cd "$cwd" || {
    printf 'error: cannot enter cwd "%s"\n' "$cwd"
    exit 1
  }
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
  url="${url#git+ssh://}"
  url="${url#ssh://}"
  url="${url#https://}"
  url="${url#http://}"
  # Strip userinfo (user or user:token) so credentials never land in the lookup key.
  # Only an '@' in the authority (before the first '/') is userinfo.
  local authority="${url%%/*}"
  if [[ "$authority" == *@* ]]; then
    url="${url#*@}"
  fi
  # Trailing slashes first, then '.git', then any slash it was hiding, so both
  # 'host/o/r.git' and 'host/o/r.git/' normalize to 'host/o/r'.
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  url="${url%.git}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  if [[ "$url" =~ ^([^/:]+):(.+)$ ]]; then
    url="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf '%s' "$url"
}

repo_key=$(normalize_url "$remote")

repo_cfg=$(jq -c --arg key "$repo_key" '.repos[$key] // empty' "$config_file" 2>/dev/null) || repo_cfg=""
if [ -z "$repo_cfg" ]; then
  printf 'error: repository "%s" not found in %s\n' "$repo_key" "$config_file"
  echo "Add it to the 'repos' map with your CI checks."
  exit 1
fi

repo_cfg_type=$(printf '%s' "$repo_cfg" | jq -r 'type')
if [ "$repo_cfg_type" != "object" ]; then
  printf 'error: repository "%s" in %s must be an object (got %s)\n' \
    "$repo_key" "$config_file" "$repo_cfg_type"
  exit 1
fi

checks_type=$(printf '%s' "$repo_cfg" | jq -r '.checks | type')
if [ "$checks_type" != "object" ]; then
  printf 'error: repository "%s" in %s has no "checks" object (got %s)\n' \
    "$repo_key" "$config_file" "$checks_type"
  echo 'Expected: {"checks":{"test":{"command":"npm test"}}}'
  exit 1
fi

if [ "$action" = "list" ]; then
  printf 'Available CI checks for %s:\n' "$repo_key"
  printf '%s' "$repo_cfg" | jq -r '
    .checks
    | to_entries
    | if length == 0 then "  (none configured)"
      else (.[] | "  \(.key): \(.value.command? // "<no command configured>")")
      end'
  exit 0
fi

check_cfg=$(printf '%s' "$repo_cfg" | jq -c --arg c "$check" '.checks[$c] // empty')
if [ -z "$check_cfg" ]; then
  printf 'error: check "%s" not found for %s\n' "$check" "$repo_key"
  echo "Available checks:"
  printf '%s' "$repo_cfg" | jq -r '
    .checks | keys | if length == 0 then "  (none configured)" else (.[] | "  \(.)") end'
  exit 1
fi

check_cfg_type=$(printf '%s' "$check_cfg" | jq -r 'type')
if [ "$check_cfg_type" != "object" ]; then
  printf 'error: check "%s" in %s must be an object with a "command" string (got %s)\n' \
    "$check" "$config_file" "$check_cfg_type"
  exit 1
fi

check_command=$(printf '%s' "$check_cfg" | jq -r '.command // empty')
if [ -z "$check_command" ]; then
  printf 'error: check "%s" in %s has no "command" string\n' "$check" "$config_file"
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "error: 'timeout' not found on PATH (install coreutils) — refusing to run a check unbounded"
  exit 1
fi

check_timeout=$(printf '%s' "$check_cfg" | jq -r '.timeout // empty')
check_timeout="${check_timeout:-120}"
if ! [[ "$check_timeout" =~ ^[0-9]+$ ]] || [ "$check_timeout" -eq 0 ]; then
  printf 'error: check "%s" has an invalid timeout "%s" — expected a positive integer (seconds)\n' \
    "$check" "$check_timeout"
  exit 1
fi

# Environment isolation: a check runs project code, so it must not observe the agent's own
# state. Every exported SHAI_* variable (run/span/session ids, policy overlay, tools dir,
# retry flag) and the API keys are scrubbed before the check starts; PATH, HOME, LANG and TERM
# survive (env -i is the wrong instrument — a check still needs a working shell). A per-check
# "env" map in ci.json re-injects variables explicitly, for the rare check that needs one.
env_args=()
while IFS='=' read -r name _; do
  case "$name" in
    SHAI_*) env_args+=(-u "$name") ;;
  esac
done < <(env)
env_args+=(-u ANTHROPIC_API_KEY -u DEEPSEEK_API_KEY)

check_env_type=$(printf '%s' "$check_cfg" | jq -r '.env | type' 2>/dev/null) || check_env_type="null"
if [ "$check_env_type" != "null" ] && [ "$check_env_type" != "object" ]; then
  printf 'error: check "%s" has an invalid "env" — expected an object mapping variable names to values\n' \
    "$check"
  exit 1
fi
if [ "$check_env_type" = "object" ]; then
  while IFS=$'\t' read -r env_name env_value; do
    env_args+=("$env_name=$env_value")
  done < <(printf '%s' "$check_cfg" | jq -r '.env | to_entries[] | [.key, .value] | @tsv')
fi

# timeout(1) reports 124, but a check command can also exit 124 on its own, so 124 alone is
# not enough. An in-band sentinel does not help either: bash runs EXIT traps even when it is
# killed by SIGTERM. So require the run to have lasted about as long as the configured limit.
# The 1s slack absorbs $SECONDS truncation; only a check that exits 124 on its own within a
# second of its own limit stays ambiguous.
start=$SECONDS
output=$(env "${env_args[@]}" timeout "${check_timeout}s" bash -c "$check_command" 2>&1) && rc=$? || rc=$?
elapsed=$((SECONDS - start))

if [ "$rc" -eq 124 ] && [ "$elapsed" -ge $((check_timeout - 1)) ]; then
  printf 'error: check "%s" timed out after %ss\n' "$check" "$check_timeout"
  if [ -n "$output" ]; then printf '%s\n' "$output"; fi
  exit 1
fi

# exit_code goes first: shai-dispatch caps tool output at 32000 bytes, keeping the head and
# the tail with an explicit truncation marker in between. Leading with the status line keeps
# it inside the head window no matter how verbose the check is.
printf 'exit_code: %d\n' "$rc"
if [ -n "$output" ]; then printf '%s\n' "$output"; fi
exit 0
