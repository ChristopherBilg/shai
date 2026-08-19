#!/bin/bash
# search_files/run.sh — search for a text pattern across files in a directory tree
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .pattern, optional .path, .glob, .ignore_case, .max_results)
# Writes: matching lines as path:line_number: text to stdout
# Exit: 0 on success (including no matches), 1 on failure
set -euo pipefail
input="$1"
pattern=$(printf '%s' "$input" | jq -r '.pattern // empty')
path=$(printf '%s' "$input" | jq -r '.path // empty')
glob=$(printf '%s' "$input" | jq -r '.glob // empty')
ignore_case=$(printf '%s' "$input" | jq -c '.ignore_case // false')
max_results=$(printf '%s' "$input" | jq -c '.max_results // empty')

if [ -z "$pattern" ]; then
  printf 'error: pattern is required\n'
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

args=(-rnI --exclude-dir=.git)

if [ "$ignore_case" = "true" ]; then
  args+=(-i)
fi

if [ -n "$glob" ]; then
  args+=(--include="$glob")
fi

args+=(-- "$pattern" "$path")

grep "${args[@]}" 2>&1 | head -n "$max_results" || true
