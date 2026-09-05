#!/bin/bash
# check-untracked.sh — fail-closed guard for the git-derived checks: untracked scripts must not slip past
# Usage: source tests/check-untracked.sh, then call check_no_untracked_scripts from the repo root
set -uo pipefail

# untracked_scripts: print every untracked file matching the git-derived checks' script
# predicate — `*.sh` anywhere plus any file whose first line is `#!/bin/bash` (the same
# predicate tests/lint.sh applies to tracked files, tests/lint.sh:37), extended with
# `shai-*` so conventions.sh's extensionless runtime-script universe cannot be skipped —
# one path per line, in git ls-files order. Empty output means the tree has none. A
# `git ls-files` failure is itself an error, never a silent empty result. Read-only.
untracked_scripts() {
  local listing f
  listing="$(git ls-files --others --exclude-standard 2>&1)" || {
    printf 'error: cannot list untracked files (guard must run inside a git checkout): %s\n' "$listing" >&2
    return 1
  }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      shai-* | *.sh)
        printf '%s\n' "$f"
        ;;
      *)
        if [ "$(head -n1 "$f" 2>/dev/null)" = "#!/bin/bash" ]; then
          printf '%s\n' "$f"
        fi
        ;;
    esac
  done <<<"$listing"
  return 0
}

# check_no_untracked_scripts: fail-closed gate for the git-derived checks (#413). A new
# (untracked) script is invisible to `git ls-files`, so a green banner would claim safety
# over files the check never inspected — the same false-confidence class the mutation-
# checking rule exists to prevent. Prints an error naming every invisible file to stderr
# and returns 1 when any exist — or when the untracked listing itself fails, which must
# never read as an empty tree — and returns 0 silently otherwise. Call from the repo root.
check_no_untracked_scripts() {
  local names=() n f listing
  listing="$(untracked_scripts)" || return 1
  while IFS= read -r f; do
    if [ -n "$f" ]; then
      names+=("$f")
    fi
  done <<<"$listing"
  n="${#names[@]}"
  [ "$n" -eq 0 ] && return 0
  printf 'error: %s untracked script file(s) are invisible to this check — commit them first: %s\n' \
    "$n" "${names[*]}" >&2
  return 1
}
