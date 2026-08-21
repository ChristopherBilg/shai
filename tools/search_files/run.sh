#!/bin/bash
# search_files/run.sh — search for a text pattern across files in a directory tree
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .pattern, optional .path, .glob, .ignore_case, .max_results)
# Writes: matching lines as path:line_number: text to stdout, plus a truncation marker when capped
# Exit: 0 on success (including no matches), 1 on failure (bad input, grep error, timeout)
set -euo pipefail
# The source directive is CWD-relative: tests/lint.sh invokes shellcheck from the repo root.
# shellcheck source=lib/read-only.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)/lib/read-only.sh"
input="$1"
pattern=$(printf '%s' "$input" | jq -r '.pattern // empty')
path=$(printf '%s' "$input" | jq -r '.path // empty')
glob=$(printf '%s' "$input" | jq -r '.glob // empty')
# These use `jq -c`, not `jq -r`, so JSON types survive the read: the string "true" arrives as
# `"true"` (quoted) and is rejected below, whereas -r would stringify it into a value that passes
# the boolean check. Same for max_results — the string "5" is not an integer.
ignore_case=$(printf '%s' "$input" | jq -c '.ignore_case // false')
max_results=$(printf '%s' "$input" | jq -c '.max_results // empty')

if [ -z "$pattern" ]; then
  printf 'error: pattern is required\n'
  exit 1
fi

if [ "$ignore_case" != "true" ] && [ "$ignore_case" != "false" ]; then
  printf 'error: ignore_case must be a boolean (got %s)\n' "$ignore_case"
  exit 1
fi

: "${path:=.}"

if [ ! -e "$path" ]; then
  printf 'error: path not found: %s\n' "$path"
  exit 1
fi

if [ -n "$max_results" ]; then
  if ! [[ "$max_results" =~ ^[0-9]+$ ]] || [ "$max_results" -lt 1 ] || [ "$max_results" -gt 500 ]; then
    printf 'error: max_results must be an integer between 1 and 500 (got %s)\n' "$max_results"
    exit 1
  fi
else
  max_results=100
fi

# -H so a single-file path is prefixed like a recursive hit; -I skips binaries; the
# --exclude/--exclude-dir flags from lib/read-only.sh keep VCS internals, credential paths and
# dependency noise out of the scan (see #118) — .git was the original --exclude-dir, now the
# shared list owns it alongside .ssh, .env, node_modules, ...
# Ordering matters: --include must come before --exclude. With GNU grep 3.11 an --exclude flag
# listed first disables the include filter entirely (a non-globbed search still honors every
# exclusion), so the glob is pushed to the front of the argument array.
args=(-rnIH)
if [ -n "$glob" ]; then
  args+=(--include="$glob")
fi
mapfile -t exclude_args < <(ro_grep_exclude_args)
args+=("${exclude_args[@]}")

if [ "$ignore_case" = "true" ]; then
  args+=(-i)
fi

args+=(-- "$pattern" "$path")

err=$(mktemp)
# shellcheck disable=SC2064  # expand $err now: the trap must survive the variable going out of scope
trap "rm -f '$err'" EXIT

# grep's diagnostics go to a file rather than being folded into the result rows with 2>&1, and its
# status is inspected instead of being discarded with `|| true`: 0 (matches) and 1 (no matches) are
# both successful searches, anything higher is a real error (invalid regex, unreadable directory).
# `timeout 30s` matches the other read-only tools so a huge tree cannot stall the agent loop.
# One row past the cap is read so a full page can be told apart from an exact fit; awk does the
# clipping rather than `head` because awk drains grep instead of closing the pipe on it, which
# would surface as a SIGPIPE status indistinguishable from a genuine grep failure.
status=0
matches=$(
  timeout 30s grep "${args[@]}" 2>"$err" | awk -v n="$((max_results + 1))" 'NR <= n'
  exit "${PIPESTATUS[0]}"
) || status=$?

case "$status" in
  0 | 1) ;;
  124)
    printf 'error: search timed out after 30s: %s\n' "$path"
    exit 1
    ;;
  *)
    printf 'error: search failed (exit %s)\n' "$status"
    if [ -s "$err" ]; then cat -- "$err"; fi
    exit 1
    ;;
esac

[ -n "$matches" ] || exit 0

if [ "$(printf '%s\n' "$matches" | wc -l)" -gt "$max_results" ]; then
  printf '%s\n' "$matches" | awk -v n="$max_results" 'NR <= n'
  printf '[truncated: showing first %s matches]\n' "$max_results"
else
  printf '%s\n' "$matches"
fi
