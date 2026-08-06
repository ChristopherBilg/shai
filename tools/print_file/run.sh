#!/bin/bash
# print_file/run.sh — print the contents of a local file
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path)
# Writes: file contents to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
timeout 30s cat -- "$path" 2>&1
