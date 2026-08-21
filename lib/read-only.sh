#!/bin/bash
# read-only.sh — shared default path/directory exclusions for auto-allowed read-only tools
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/read-only.sh"
set -uo pipefail

# Decision from issue #118, applied uniformly to the auto-allowed read-only tools
# (list_directory, print_file, search_files):
#
#   - No root confinement. The tools keep filesystem-wide reach: a workspace root would break
#     legitimate reads (config files, sibling checkouts) and the boundary already belongs to the
#     permission gate — policy.json arg rules can deny any path. Confinement is a policy
#     decision, so it stays a policy rule, not a tool default.
#   - One shared default exclusion list instead, in this file (the single source of truth),
#     consumed in two places:
#       1. shai-dispatch's read-only auto-allow fallback: an input path that targets an excluded
#          location degrades the fallback from `allow` to `prompt` (interactive confirmation;
#          non-interactive runs fail closed). An explicit policy rule or `default` is checked
#          before the fallback and wins, so the list is a default, not a boundary.
#       2. search_files' recursive scan (ro_grep_exclude_args): excluded basenames are never
#          descended into or matched, regardless of the input path, so a search of `$HOME` or a
#          repo tree cannot stumble onto credential files or dependency noise.
#   - search_files keeps defaulting `path` to `.`: the scan-level exclusion makes the default
#     safe, and requiring an explicit path would be churn with no additional security.
#
# This is a conservative baseline of the highest-value targets (credentials, VCS internals,
# dependency noise), not a security boundary: it is a default, overridable by an explicit
# policy rule/default, and extensible here.
#
# Each entry is a basename glob matched against every path component.
RO_EXCLUDED_BASENAMES=(
  '.git'         # VCS internals; config may embed remote credentials
  '.ssh'         # private keys
  '.env'         # dotenv files (API keys / secrets)
  '.env.*'       # dotenv variants: .env.local, .env.production, ... (also .env.example)
  'node_modules' # dependency noise
  '.aws'         # AWS credentials
  '.gnupg'       # GPG keyrings
)

# ro_component_excluded <basename>: 0 when a path component is on the exclusion list.
ro_component_excluded() {
  local comp="$1"
  case "$comp" in
    .git | .ssh | .env | .env.* | node_modules | .aws | .gnupg) return 0 ;;
    *) return 1 ;;
  esac
}

# ro_path_excluded <path>: 0 when any component of <path> is on the exclusion list. Empty and
# "." (the search_files default) are never excluded — they are the caller's working tree.
ro_path_excluded() {
  local path="$1" comp
  [ -n "$path" ] || return 1
  [ "$path" != "." ] || return 1
  IFS='/' read -r -a comps <<<"$path"
  for comp in "${comps[@]}"; do
    ro_component_excluded "$comp" && return 0
  done
  return 1
}

# ro_grep_exclude_args: print the grep --exclude/--exclude-dir flags for every excluded
# basename, one per line. Both flags are emitted for each entry (a basename like `.env` can be
# either a file or a directory), so a caller can `mapfile -t` the output into grep's argument
# array. grep matches both flags against the basename of each file/directory it encounters.
ro_grep_exclude_args() {
  local entry
  for entry in "${RO_EXCLUDED_BASENAMES[@]}"; do
    printf '%s\n' "--exclude=$entry"
    printf '%s\n' "--exclude-dir=$entry"
  done
}
