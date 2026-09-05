#!/bin/bash
# lint.sh — the project's one lint target: ShellCheck + shfmt over every tracked shell script
# Usage: ./tests/lint.sh [--list|--write]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
cd "$ROOT"
# shellcheck source=tests/check-untracked.sh
source "$ROOT/tests/check-untracked.sh"

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

# Derived fail-closed from git, not a hand-maintained glob list: every tracked *.sh plus every
# tracked file whose first line is a #!/bin/bash shebang (the extensionless shai-* scripts). A
# future tracked shell script (e.g. hooks/*.sh) is picked up automatically instead of waiting for
# a human to remember to edit a list — which is exactly how tools/*/run.sh went unlinted (#81).
# tests/conventions.sh cross-checks that every runtime script it checks appears in this list.
mapfile -t FILES < <(
  git ls-files | while IFS= read -r f; do
    case "$f" in
      *.sh) printf '%s\n' "$f" ;;
      *) [ "$(head -n1 "$f" 2>/dev/null)" = "#!/bin/bash" ] && printf '%s\n' "$f" ;;
    esac
  done | sort -u
)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no files to lint — is $ROOT a git checkout?" >&2
  exit 1
fi

if [ "$mode" = "list" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

# Fail closed on dirty trees (#413): an untracked script is invisible to the git-derived
# FILES list above, so a green banner would claim lint safety for a file that was never
# shell-checked or formatted. --list stays a pure listing of tracked files (conventions.sh
# consumes it programmatically), but every mode that can print a green banner gates here.
check_no_untracked_scripts || exit 1

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

# Surface which binaries will actually run so a $PATH fallback (or a $SHELLCHECK/$SHFMT override)
# cannot silently substitute an unpinned linter for the checksum-verified one in ./bin.
echo "shellcheck: $SHELLCHECK"
"$SHELLCHECK" --version 2>&1 | sed -n '1,2p' || true
echo "shfmt: $SHFMT"
"$SHFMT" --version 2>&1 | sed -n '1,2p' || true

fail=0
if "$SHELLCHECK" "${FILES[@]}"; then
  echo -e "  ${GREEN}✓${NC} shellcheck: ${#FILES[@]} files clean"
else
  echo -e "  ${RED}✗${NC} shellcheck reported findings"
  fail=1
fi

if [ "$mode" = "write" ]; then
  if "$SHFMT" -w "${FILES[@]}"; then
    echo -e "  ${GREEN}✓${NC} shfmt: rewrote ${#FILES[@]} files in place"
  else
    echo -e "  ${RED}✗${NC} shfmt write failed"
    fail=1
  fi
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
