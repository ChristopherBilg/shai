#!/bin/bash
# write_file/run.sh — create or overwrite a file with given content, optionally setting its mode
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .path, .content, optional .mode)
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
# An explicit mode wins over the preservation logic below: it is the only way for a caller to
# create an executable file (git hooks, tool plugins, tests/test_*.sh), since a fresh file
# otherwise lands at the process umask. Validate before touching the filesystem so a rejected
# mode never leaves a written file behind, and never hand unvalidated input to chmod — the
# pattern is deliberately strict (3-4 octal digits only: no `u+x`, no comma lists, no flags).
want_mode=$(printf '%s' "$input" | jq -r '.mode // "" | tostring') || {
  printf 'invalid JSON input'
  exit 1
}
if [ -n "$want_mode" ] && ! [[ "$want_mode" =~ ^[0-7]{3,4}$ ]]; then
  printf 'invalid mode %s: expected 3-4 octal digits, e.g. "755" (nothing was written)' "$want_mode"
  exit 1
fi
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
# redirect semantics. Skipped when the caller asked for a specific mode.
mode=""
if [ -z "$want_mode" ] && [ -f "$path" ]; then
  mode=$(file_mode "$path")
fi
printf '%s' "$content" >"$path" || {
  printf 'cannot write to %s' "$path"
  exit 1
}
# Capture the byte count before any chmod. Counting the content we just wrote (rather than
# reading the file back) keeps the confirmation correct even when a requested mode like 000
# makes the file owner-unreadable, and avoids a spurious read error.
size=$(printf '%s' "$content" | wc -c)
# A requested mode that cannot be applied is an error, not a warning: the caller asked for it
# explicitly (usually to make the file runnable), so reporting plain success would hide a file
# that does not do what was asked. The content is already on disk, so say that too.
# An unreadable preserved mode, by contrast, is harmless (in-place truncation keeps the bits),
# but a failing chmod could mean the mode really did change, so report that instead of
# silencing it.
mode_note=""
if [ -n "$want_mode" ]; then
  chmod "$want_mode" "$path" 2>/dev/null || {
    printf 'wrote %d bytes to %s but could not apply mode %s' \
      "$size" "$path" "$want_mode"
    exit 1
  }
  mode_note=" (mode $want_mode)"
elif [ -n "$mode" ] && ! chmod "$mode" "$path" 2>/dev/null; then
  mode_note=" (warning: could not restore mode $mode; permission bits may have changed)"
fi
printf 'Wrote %d bytes to %s%s' "$size" "$path" "$mode_note"
