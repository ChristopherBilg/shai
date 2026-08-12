#!/bin/bash
# constants-sync.sh — verify documented constants match their source-of-truth scripts
# Usage: ./tests/constants-sync.sh [root-dir]
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)}"
cd "$ROOT"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
fail=0
note() {
  echo -e "  ${RED}✗${NC} $1"
  fail=1
}
ok() { echo -e "  ${GREEN}✓${NC} $1"; }

DEFAULT_MODEL=$(sed -n 's/^MODEL="${SHAI_MODEL:-\(.*\)}"/\1/p' shai-eval)
MAX_BYTES=$(sed -n 's/^MAX_BYTES=\([0-9]*\)/\1/p' shai-dispatch)
CONTEXT_BUDGET=$(sed -n 's/.*SHAI_MAX_CONTEXT_BYTES:-\([0-9]*\)}.*/\1/p' shai-context)
SHELLCHECK_VER=$(sed -n 's/^SHELLCHECK_VERSION="\(.*\)"/\1/p' tests/install-lint-tools.sh)
SHFMT_VER=$(sed -n 's/^SHFMT_VERSION="\(.*\)"/\1/p' tests/install-lint-tools.sh)

check() {
  local value="$1" file="$2" label="$3"
  if [ ! -f "$file" ]; then
    note "$file not found"
    return
  fi
  if grep -qF "$value" "$file"; then
    ok "$label ($value) in $file"
  else
    note "$label ($value) missing from $file"
  fi
}

check "$DEFAULT_MODEL" CLAUDE.md "default model"
check "$MAX_BYTES" CLAUDE.md "truncation limit"
check "$MAX_BYTES" README.md "truncation limit"
check "$CONTEXT_BUDGET" CLAUDE.md "context budget"
check "$SHELLCHECK_VER" CLAUDE.md "shellcheck version"
check "$SHFMT_VER" CLAUDE.md "shfmt version"

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}CONSTANTS SYNC OK${NC}"
  exit 0
else
  echo -e "${RED}CONSTANTS SYNC FAILED${NC} — update the file(s) above to match the source scripts"
  exit 1
fi
