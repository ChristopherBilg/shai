#!/bin/bash
# print_file/run.sh — print a local file, optionally line-numbered and/or limited to a line range
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, optional .line_numbers, .start_line, .end_line)
# Writes: file contents (or the requested line range) to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
line_numbers=$(printf '%s' "$input" | jq -r '.line_numbers // false' 2>/dev/null) || line_numbers="false"
start_line=$(printf '%s' "$input" | jq -r '.start_line // empty' 2>/dev/null) || start_line=""
end_line=$(printf '%s' "$input" | jq -r '.end_line // empty' 2>/dev/null) || end_line=""

if [ "$line_numbers" != "true" ] && [ "$line_numbers" != "false" ]; then
  printf 'error: line_numbers must be a boolean (got "%s")\n' "$line_numbers"
  exit 1
fi

# require_line_number <field> <value>: reject anything that is not a 1-based line number.
require_line_number() {
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
    printf 'error: %s must be a positive integer (got "%s")\n' "$1" "$2"
    exit 1
  fi
}
if [ -n "$start_line" ]; then require_line_number start_line "$start_line"; fi
if [ -n "$end_line" ]; then require_line_number end_line "$end_line"; fi
if [ -n "$start_line" ] && [ -n "$end_line" ] && [ "$start_line" -gt "$end_line" ]; then
  printf 'error: start_line (%s) must be less than or equal to end_line (%s)\n' \
    "$start_line" "$end_line"
  exit 1
fi

# Default path: byte-identical to the pre-enhancement tool when none of the new fields is set,
# so existing callers (and the truncation behaviour they were tuned against) are unaffected.
if [ "$line_numbers" = "false" ] && [ -z "$start_line" ] && [ -z "$end_line" ]; then
  timeout 30s cat -- "$path" 2>&1
  exit 0
fi

# The numbering/range path validates the path itself instead of leaning on cat's diagnostics,
# so an unreadable file can never be mistaken for a range that simply matched no lines.
if [ ! -e "$path" ]; then
  printf 'error: file not found: %s\n' "$path"
  exit 1
fi
if [ -d "$path" ]; then
  printf 'error: cannot print a directory: %s\n' "$path"
  exit 1
fi
if [ ! -r "$path" ]; then
  printf 'error: cannot read file: %s\n' "$path"
  exit 1
fi

# One awk pass over the file:
#   - line numbers are absolute file positions, so a windowed read still yields real file:line
#     anchors (the whole point of the feature — no hand counting);
#   - the pass stops at end_line rather than scanning the rest of a large file;
#   - end=0 means "to EOF", start defaults to 1, so start_line and end_line are independent;
#   - a start_line past EOF prints nothing and exits 0 — an empty window, not an error.
# The file is fed on stdin because an awk file operand containing '=' would be parsed as a
# variable assignment rather than a filename.
timeout 30s awk \
  -v start="${start_line:-1}" \
  -v end="${end_line:-0}" \
  -v numbers="$line_numbers" '
    end > 0 && NR > end { exit }
    NR < start { next }
    numbers == "true" { printf "%6d\t%s\n", NR, $0; next }
    { print }
  ' <"$path" 2>&1
