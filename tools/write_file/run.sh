#!/bin/bash
# write_file/run.sh — create or overwrite a file with given content
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, .content)
# Writes: file at .path; confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
content=$(printf '%s' "$input" | jq -rj '.content' && printf x) || {
  printf 'invalid JSON input'
  exit 1
}
content=${content%x}
# file_mode <path> — echo a file's octal permission bits, or nothing if unavailable.
# GNU coreutils and BSD/macOS stat disagree on flags, so try both (the repo targets both).
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf ''
}
mkdir -p -- "$(dirname "$path")" 2>&1 || {
  printf 'cannot create parent directory for %s' "$path"
  exit 1
}
# Record the existing mode before the overwrite. `>` truncates in place and so
# preserves permissions today, but overwriting an executable script must never
# drop its exec bit, so restore the mode explicitly instead of relying on
# redirect semantics.
mode=""
if [ -f "$path" ]; then
  mode=$(file_mode "$path")
fi
printf '%s' "$content" >"$path" || {
  printf 'cannot write to %s' "$path"
  exit 1
}
if [ -n "$mode" ]; then
  chmod "$mode" "$path" 2>/dev/null || true
fi
printf 'Wrote %d bytes to %s' "$(wc -c <"$path")" "$path"
