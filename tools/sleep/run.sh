#!/bin/bash
# sleep/run.sh — pause execution for a specified number of seconds
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .seconds integer, 1-300)
# Writes: elapsed confirmation to stdout
# Exit: 0 on success, 1 on invalid input
set -euo pipefail
input="$1"
seconds=$(printf '%s' "$input" | jq -r '.seconds // empty' 2>/dev/null) || seconds=""

if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt 1 ] || [ "$seconds" -gt 300 ]; then
  printf 'error: seconds must be an integer between 1 and 300 (got "%s")\n' "$seconds"
  exit 1
fi

sleep "$seconds"
printf 'slept %ss\n' "$seconds"
