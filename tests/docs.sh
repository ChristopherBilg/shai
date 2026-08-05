#!/bin/bash
# docs.sh — fail-closed documentation checker: every tracked file must be documented
# Usage: ./tests/docs.sh [file ...]   (no args → checks `git ls-files` from repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
fail=0
note() {
  echo -e "  ${RED}✗${NC} $1"
  fail=1
}
ok() { echo -e "  ${GREEN}✓${NC} $1"; }

# Files exempt from the documentation requirement, with rationale.
EXEMPT=(
  "tests/lint-tools.sha256" # generated checksum lockfile; comment-hostile format
)

is_exempt() {
  local f="$1" e
  for e in "${EXEMPT[@]}"; do [ "$f" = "$e" ] && return 0; done
  return 1
}

# purpose_ok <file>: line 2 is `# <text>`, text >= 12 chars and not just the basename.
purpose_ok() {
  local f="$1" line text base
  line="$(sed -n '2p' "$f")"
  [[ "$line" == '# '* ]] || return 1
  text="${line#\# }"
  base="$(basename "$f")"
  [ "${#text}" -ge 12 ] || return 1
  [ "${text,,}" != "${base,,}" ] || return 1
  return 0
}

# has_tag <file> <Tag> [must_contain]: a `# Tag: value` (value >= 3 chars) in the first 15 lines.
has_tag() {
  local f="$1" tag="$2" must="${3:-}" line val re
  re="^# ${tag}:[[:space:]]*(.+)$"
  while IFS= read -r line; do
    if [[ "$line" =~ $re ]]; then
      val="${BASH_REMATCH[1]}"
      [ "${#val}" -ge 3 ] || return 1
      if [ -n "$must" ]; then [[ "$val" == *"$must"* ]] || return 1; fi
      return 0
    fi
  done < <(head -n 15 "$f")
  return 1
}

# first_nonblank <file>: echoes the first line containing a non-space character.
first_nonblank() { grep -m1 -E '\S' "$1" || true; }

md_ok() { # first non-blank line is a single-# H1 with text (## is rejected)
  local f="$1" line re='^# +[^ ]'
  line="$(first_nonblank "$f")"
  [[ "$line" =~ $re ]]
}

comment_hdr_ok() { # first non-blank line is `#` + >= 8 chars of text
  local f="$1" line text
  line="$(first_nonblank "$f")"
  [[ "$line" == '#'* ]] || return 1
  text="$(printf '%s' "${line#\#}" | sed 's/^[[:space:]]*//')"
  [ "${#text}" -ge 8 ]
}

json_ok() { # valid array; every tool and every input property has a non-empty description
  jq -e '
    type == "array"
    and all(.[];
      (.description // "" | length) > 0
      and all((.input_schema.properties // {})[]; (.description // "" | length) > 0)
    )
  ' "$1" >/dev/null 2>&1
}

# check_shell <file> <runtime|test|infra>
check_shell() {
  local f="$1" kind="$2" base bad=0
  base="$(basename "$f")"
  purpose_ok "$f" || {
    note "purpose line (line 2) missing or trivial: $f"
    bad=1
  }
  case "$kind" in
    runtime)
      has_tag "$f" Usage "$base" || {
        note "'# Usage:' missing or does not name $base: $f"
        bad=1
      }
      has_tag "$f" Reads || {
        note "'# Reads:' missing: $f"
        bad=1
      }
      has_tag "$f" Writes || {
        note "'# Writes:' missing: $f"
        bad=1
      }
      has_tag "$f" Exit || {
        note "'# Exit:' missing: $f"
        bad=1
      }
      ;;
    test)
      has_tag "$f" Covers || {
        note "'# Covers:' missing: $f"
        bad=1
      }
      ;;
    infra)
      has_tag "$f" Usage "$base" || {
        note "'# Usage:' missing or does not name $base: $f"
        bad=1
      }
      ;;
  esac
  # NOTE: never end this function on a bare `test && cmd` — under `set -e` a
  # failing test would make check_shell return 1 and abort the whole run at the
  # first bad file. Failures are recorded via the global `fail` (in note()); this
  # function must always return 0 so main() can aggregate and print the banner.
  if [ "$bad" -eq 0 ]; then ok "documented: $f"; fi
  return 0
}

check_file() {
  local f="$1"
  if is_exempt "$f"; then
    ok "exempt: $f"
    return
  fi
  case "$f" in
    *.md)
      if md_ok "$f"; then ok "md H1: $f"; else note "markdown missing '# ' H1 title: $f"; fi
      return
      ;;
    *.json)
      if json_ok "$f"; then ok "json descriptions: $f"; else note "json missing description(s): $f"; fi
      return
      ;;
    *.yml | *.yaml)
      if comment_hdr_ok "$f"; then ok "yaml header: $f"; else note "yaml missing leading purpose comment: $f"; fi
      return
      ;;
    tests/test_*.sh)
      check_shell "$f" test
      return
      ;;
    tests/*.sh)
      check_shell "$f" infra
      return
      ;;
  esac
  if [[ "$f" != */* ]] && [ "$(head -n1 "$f")" = "#!/bin/bash" ]; then
    check_shell "$f" runtime
    return
  fi
  case "$f" in
    .editorconfig | .shellcheckrc | .gitignore)
      if comment_hdr_ok "$f"; then ok "config header: $f"; else note "config missing leading purpose comment: $f"; fi
      return
      ;;
  esac
  note "UNKNOWN file type (add a rule to tests/docs.sh or add to EXEMPT with a reason): $f"
}

main() {
  local files=() f
  if [ "$#" -gt 0 ]; then
    files=("$@")
  else
    cd "$ROOT"
    mapfile -t files < <(git ls-files)
  fi
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then check_file "$f"; else note "listed file not found: $f"; fi
  done
  echo
  if [ "$fail" -eq 0 ]; then
    echo -e "${GREEN}DOCS OK${NC}"
    exit 0
  else
    echo -e "${RED}DOCS FAILED${NC}"
    exit 1
  fi
}

main "$@"
