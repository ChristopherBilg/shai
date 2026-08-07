#!/bin/bash
# list_directory/run.sh — list files and folders in a directory
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path)
# Writes: directory listing to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
timeout 30s ls -1 -- "$path" 2>&1
