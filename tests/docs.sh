#!/bin/bash
# docs.sh — fail-closed documentation checker: every tracked file must be documented
# Usage: ./tests/docs.sh [file ...]   (no args → checks `git ls-files` from repo root, failing
#        first if untracked script files would be invisible to it)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
# shellcheck source=tests/check-untracked.sh
source "$ROOT/tests/check-untracked.sh"

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

json_ok() { # valid non-empty array; every tool and every input property has a non-empty description
  jq -e '
    type == "array"
    and length > 0
    and all(.[];
      (.description // "" | length) > 0
      and (.parameters.properties | type == "object" and length > 0)
      and all(.parameters.properties[]; (.description // "" | length) > 0)
    )
  ' "$1" >/dev/null 2>&1
}

json_example_ok() { # valid JSON with a non-empty top-level "_comment" (JSON has no comments)
  jq -e 'type == "object" and ((._comment // "") | type == "string" and length >= 12)' \
    "$1" >/dev/null 2>&1
}

tool_json_ok() { # single tool object; tool + every input property has a non-empty description
  jq -e '
    type == "object"
    and ((.description // "") | length) > 0
    and (.parameters.properties | type == "object" and length > 0)
    and all(.parameters.properties[]; (.description // "" | length) > 0)
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
  # Fail-closed: unrecognized file types fail the check (the final catch-all
  # emits an error). Adding a new file type requires a new branch
  # here plus a fixture in tests/test_docs.sh. This is intentional — see #29.
  case "$f" in
    *.md)
      if md_ok "$f"; then ok "md H1: $f"; else note "markdown missing '# ' H1 title: $f"; fi
      return
      ;;
    tools/*/run.sh)
      check_shell "$f" runtime
      return
      ;;
    tools/*/tool.json)
      if tool_json_ok "$f"; then
        ok "tool schema: $f"
      elif jq -e 'type == "object" and ((.description // "") | length) > 0 and (.parameters.properties | type != "object" or length == 0)' "$f" >/dev/null 2>&1; then
        note "tool schema parameters.properties missing or empty (renamed or absent parameters/properties key?): $f"
      else
        note "tool schema missing description(s): $f"
      fi
      return
      ;;
    workflows/*/policy.json)
      if jq -e '.rules | type == "array"' "$f" >/dev/null 2>&1; then
        ok "policy: $f"
      else
        note "policy file missing .rules array: $f"
      fi
      return
      ;;
    # Shape and manifest-integrity checks only. Repo-wide coverage (every
    # git-tracked shai-* script has an entry, every parsed flag is declared)
    # is #320's scope (`shai-completions check` + tests/completions-sync.sh),
    # which needs the git context this per-file walker lacks in fixture runs.
    completions.json | */completions.json)
      if jq -e '
        def described: type == "string" and length > 0;
        type == "object"
        and ((.scripts | type) == "object" and (.scripts | length) > 0)
        and ((.types | type) == "object" and (.types | length) > 0)
        and (["session_id", "run_id", "workflow_name", "prompt_name", "file", "date"] - (.types | keys) | length == 0)
        and all(.scripts[];
          ((.description // "") | described)
          and ((.flags | type) == "object")
          and all(.flags[]; ((.description // "") | described))
          and all((.subcommands // {}) | .[];
            ((.description // "") | described)
            and ((.flags | type) == "object")
            and all(.flags[]; ((.description // "") | described))))
        and (([
          .scripts[] |
            [ .flags[] | .arg_type // empty ],
            [ (.positional // [])[] | .type // empty ],
            [ (.subcommands // {})[] | .flags[] | .arg_type // empty ],
            [ (.subcommands // {})[] | (.positional // [])[] | .type // empty ]
        ] | flatten | unique) - (.types | keys) | length == 0)
      ' "$f" >/dev/null 2>&1; then
        ok "completions manifest: $f"
      else
        note "completions manifest must have non-empty scripts/types, all six required types, described scripts/subcommands/flags, and type references that resolve: $f"
      fi
      return
      ;;
    # Generated completion scripts — never hand-edited; the header marker is the contract.
    completions/*)
      if head -n 5 "$f" | grep -q 'Generated by shai-completions generate'; then
        ok "generated completions: $f"
      else
        note "generated completions file missing its 'Generated by shai-completions generate' header: $f"
      fi
      return
      ;;
    *.json.example)
      if json_example_ok "$f"; then
        ok "json example: $f"
      else
        note "json example must be valid JSON with a '_comment' string explaining it: $f"
      fi
      return
      ;;
    *.json)
      if json_ok "$f"; then
        ok "json descriptions: $f"
      elif jq -e 'type == "array" and length > 0 and all(.[]; (.description // "" | length) > 0) and any(.[]; (.parameters.properties | type != "object" or length == 0))' "$f" >/dev/null 2>&1; then
        note "json parameters.properties missing or empty (renamed or absent parameters/properties key?): $f"
      else
        note "json missing description(s): $f"
      fi
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
    prompts/*.txt)
      if [ -s "$f" ]; then ok "prompt ok: $f"; else note "empty prompt file: $f"; fi
      return
      ;;
    workflows/*/run.sh)
      check_shell "$f" runtime
      return
      ;;
    lib/*.sh)
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
    # Fail closed on dirty trees (#413): an untracked script is invisible to `git ls-files`,
    # so the DOCS OK banner could go green over a script whose doc header was never checked.
    # Explicit file arguments are unaffected — they name exactly what is being checked.
    check_no_untracked_scripts || exit 1
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
