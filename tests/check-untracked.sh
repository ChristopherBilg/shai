#!/bin/bash
# check-untracked.sh — fail-closed guard for the git-derived checks: untracked scripts must not slip past
# Usage: source tests/check-untracked.sh, then call check_no_untracked_scripts from the repo root
set -uo pipefail

# untracked_scripts: print every untracked file matching the git-derived checks' script
# predicate — the same predicate tests/lint.sh applies to tracked files — one path per
# line, sorted. Empty output means the tree has none. Read-only.
untracked_scripts() {
  git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r f; do
    case "$f" in
      shai-* | install.sh | tests/*.sh | lib/*.sh | tools/*/run.sh | workflows/*/run.sh)
        printf '%s\n' "$f"
        ;;
      *)
        [ "$(head -n1 "$f" 2>/dev/null)" = "#!/bin/bash" ] && printf '%s\n' "$f"
        ;;
    esac
  done | sort -u
}

# check_no_untracked_scripts: fail-closed gate for the git-derived checks (#413). A new
# (untracked) script is invisible to `git ls-files`, so a green banner would claim safety
# over files the check never inspected — the same false-confidence class the mutation-
# checking rule exists to prevent. Prints an error naming every invisible file to stderr
# and returns 1 when any exist; returns 0 silently otherwise. Call from the repo root.
check_no_untracked_scripts() {
  local names=() n f
  while IFS= read -r f; do names+=("$f"); done < <(untracked_scripts)
  n="${#names[@]}"
  [ "$n" -eq 0 ] && return 0
  printf 'error: %s untracked script file(s) are invisible to this check — commit them first: %s\n' \
    "$n" "${names[*]}" >&2
  return 1
}
