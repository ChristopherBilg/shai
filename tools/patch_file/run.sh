#!/bin/bash
# patch_file/run.sh — replace a unique string in an existing file
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, .old_string, .new_string)
# Writes: patched file at .path; confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
old_string=$(printf '%s' "$input" | jq -rj '.old_string'; printf x)
old_string=${old_string%x}
if [ -z "$old_string" ]; then
  printf 'old_string must not be empty'
  exit 1
fi
new_string=$(printf '%s' "$input" | jq -rj '.new_string'; printf x)
new_string=${new_string%x}
if [ ! -f "$path" ]; then
  printf 'file not found: %s' "$path"
  exit 1
fi
if [ ! -s "$path" ]; then
  printf 'old_string not found in %s (file is empty)' "$path"
  exit 1
fi
count=$(OLD_STR="$old_string" awk '
  BEGIN { old = ENVIRON["OLD_STR"]; RS = "\0"; ORS = "" }
  {
    s = $0; n = 0
    while ((p = index(s, old)) > 0) { n++; s = substr(s, p + length(old)) }
    print n
  }
' "$path")
if [ "$count" -eq 0 ]; then
  printf 'old_string not found in %s' "$path"
  exit 1
fi
if [ "$count" -gt 1 ]; then
  printf 'old_string matches %d times in %s (must be unique)' "$count" "$path"
  exit 1
fi
tmpfile=$(mktemp) || {
  printf 'cannot create temp file'
  exit 1
}
OLD_STR="$old_string" NEW_STR="$new_string" awk '
  BEGIN { old = ENVIRON["OLD_STR"]; new = ENVIRON["NEW_STR"]; RS = "\0"; ORS = "" }
  {
    p = index($0, old)
    printf "%s%s%s", substr($0, 1, p - 1), new, substr($0, p + length(old))
  }
' "$path" >"$tmpfile" || {
  rm -f "$tmpfile"
  printf 'patch failed for %s' "$path"
  exit 1
}
mv -- "$tmpfile" "$path" 2>&1 || {
  rm -f "$tmpfile"
  printf 'cannot write to %s' "$path"
  exit 1
}
printf 'Patched %s' "$path"
