#!/bin/bash
# git-remote.sh — normalize a git remote URL into the ci.json repo key it is looked up by
# Usage: source ".../lib/git-remote.sh"
set -uo pipefail

# normalize_url <remote-url>: print the remote in the repo-key shape the ci tool looks
# configuration up by — no scheme, no credentials, no trailing '.git' (issue #344).
normalize_url() {
  local url="$1"
  url="${url#git+ssh://}"
  url="${url#ssh://}"
  url="${url#https://}"
  url="${url#http://}"
  # Strip userinfo (user or user:token) so credentials never land in the lookup key.
  # Only an '@' in the authority (before the first '/') is userinfo.
  local authority="${url%%/*}"
  if [[ "$authority" == *@* ]]; then
    url="${url#*@}"
  fi
  # Trailing slashes first, then '.git', then any slash it was hiding, so both
  # 'host/o/r.git' and 'host/o/r.git/' normalize to 'host/o/r'.
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  url="${url%.git}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done
  if [[ "$url" =~ ^([^/:]+):(.+)$ ]]; then
    url="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  printf '%s' "$url"
}
