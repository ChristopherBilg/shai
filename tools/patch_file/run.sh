#!/bin/bash
# patch_file/run.sh — replace a unique string in an existing file
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, .old_string, .new_string)
# Writes: patched file at .path; confirmation to stdout
# Exit: 0 on success, 1 on failure
set -euo pipefail
input="$1"
path=$(printf '%s' "$input" | jq -r '.path')
old_string=$(printf '%s' "$input" | jq -rj '.old_string' && printf x) || {
  printf 'invalid JSON input'
  exit 1
}
old_string=${old_string%x}
if [ -z "$old_string" ]; then
  printf 'old_string must not be empty'
  exit 1
fi
new_string=$(printf '%s' "$input" | jq -rj '.new_string' && printf x) || {
  printf 'invalid JSON input'
  exit 1
}
new_string=${new_string%x}
# file_mode <path> — echo a file's octal permission bits, or nothing if unavailable.
# GNU coreutils and BSD/macOS stat disagree on flags, so try both (the repo targets both).
# GNU '%a' already includes the setuid/setgid/sticky bits; on BSD those live in '%Mp' and the
# user/group/other bits in '%Lp', so concatenate them (zero-padding the low bits to 3 digits)
# instead of using '%Lp' alone, which would silently drop setuid/setgid/sticky on macOS.
# Always returns 0: the caller assigns via command substitution, and a non-zero status there
# would abort the script under `set -e`.
file_mode() {
  local mode high low
  if mode=$(stat -c '%a' "$1" 2>/dev/null); then
    printf '%s' "$mode"
  elif high=$(stat -f '%Mp' "$1" 2>/dev/null) && low=$(stat -f '%Lp' "$1" 2>/dev/null); then
    while [ "${#low}" -lt 3 ]; do low="0$low"; done
    printf '%s%s' "$high" "$low"
  fi
  return 0
}
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
  if grep -q 'external_data' "$path" 2>/dev/null; then
    printf 'old_string not found in %s (the file contains external_data tags, which are escaped in tool output — re-read and use surrounding text as the anchor)' "$path"
  else
    printf 'old_string not found in %s' "$path"
  fi
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
# mktemp creates the temp file 0600 and `mv` carries the source mode to the
# destination, so without this the rename would silently drop the target's
# permission bits (executable scripts become non-executable). Copy the mode
# before the rename so the write stays atomic.
# A mode that cannot be read or applied means the rename falls back to the buggy behaviour
# (target left at the temp file's 0600), so say so in the output rather than failing the edit
# or losing the bits silently.
mode=$(file_mode "$path")
mode_note=""
if [ -z "$mode" ]; then
  mode_note=" (warning: could not read the original permission bits; they may have changed)"
elif ! chmod "$mode" "$tmpfile" 2>/dev/null; then
  mode_note=" (warning: could not restore mode $mode; permission bits may have changed)"
fi
mv -- "$tmpfile" "$path" 2>&1 || {
  rm -f "$tmpfile"
  printf 'cannot write to %s' "$path"
  exit 1
}
printf 'Patched %s%s' "$path" "$mode_note"
