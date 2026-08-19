#!/bin/bash
# lint.sh — the project's one lint target: ShellCheck + shfmt over every tracked shell script
# Usage: ./tests/lint.sh [--list|--write]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

mode="check"
case "${1:-}" in
  "") ;;
  --list) mode="list" ;;
  --write) mode="write" ;;
  *)
    echo "usage: ./tests/lint.sh [--list|--write]" >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "usage: ./tests/lint.sh [--list|--write]" >&2
  exit 2
fi

# Derived from git, not hardcoded: the same glob list used to live in .github/workflows/ci.yml,
# README.md, CLAUDE.md, and ci.json.example, and those four copies drifted — tools/*/run.sh, the
# execution surface for every model-requested action, was in none of them (#81). One list, here.
# tests/conventions.sh asserts every runtime script it checks appears in this list, so a new
# runtime category cannot be added while staying invisible to the linter.
mapfile -t FILES < <({
  git ls-files 'install.sh'
  git ls-files 'shai-*'
  git ls-files 'lib/*.sh'
  git ls-files 'tools/*/run.sh'
  git ls-files 'workflows/*/run.sh'
  git ls-files 'tests/*.sh'
} | sort -u)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no files to lint — is $ROOT a git checkout?" >&2
  exit 1
fi

if [ "$mode" = "list" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

# Prefer the pinned binaries in ./bin (tests/install-lint-tools.sh downloads them), then fall
# back to $PATH so a platform those linux_amd64 downloads do not cover can still lint with
# system-installed tools. $SHELLCHECK/$SHFMT override both.
find_tool() {
  local name="$1"
  if [ -x "./bin/$name" ]; then
    printf './bin/%s' "$name"
    return 0
  fi
  command -v "$name" 2>/dev/null || return 1
}

SHELLCHECK="${SHELLCHECK:-$(find_tool shellcheck || true)}"
SHFMT="${SHFMT:-$(find_tool shfmt || true)}"

require_tool() {
  local name="$1" path="$2"
  [ -n "$path" ] && return 0
  echo "$name not found — run ./tests/install-lint-tools.sh (or put it on \$PATH)" >&2
  return 1
}

missing=0
require_tool shellcheck "$SHELLCHECK" || missing=1
require_tool shfmt "$SHFMT" || missing=1
[ "$missing" -eq 0 ] || exit 1

fail=0
if "$SHELLCHECK" "${FILES[@]}"; then
  echo -e "  ${GREEN}✓${NC} shellcheck: ${#FILES[@]} files clean"
else
  echo -e "  ${RED}✗${NC} shellcheck reported findings"
  fail=1
fi

if [ "$mode" = "write" ]; then
  "$SHFMT" -w "${FILES[@]}"
  echo -e "  ${GREEN}✓${NC} shfmt: rewrote ${#FILES[@]} files in place"
elif "$SHFMT" -d "${FILES[@]}"; then
  echo -e "  ${GREEN}✓${NC} shfmt: ${#FILES[@]} files formatted"
else
  echo -e "  ${RED}✗${NC} shfmt reported a diff (./tests/lint.sh --write rewrites in place)"
  fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}LINT OK${NC}"
  exit 0
else
  echo -e "${RED}LINT FAILED${NC}"
  exit 1
fi
