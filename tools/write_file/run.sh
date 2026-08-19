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
# An unreadable mode is harmless here (in-place truncation keeps the bits), but a failing
# chmod could mean the mode really did change, so report that instead of silencing it.
mode_note=""
if [ -n "$mode" ] && ! chmod "$mode" "$path" 2>/dev/null; then
  mode_note=" (warning: could not restore mode $mode; permission bits may have changed)"
fi
printf 'Wrote %d bytes to %s%s' "$(wc -c <"$path")" "$path" "$mode_note"
