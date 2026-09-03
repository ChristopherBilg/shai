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

MAX_BYTES=$(sed -n 's/^MAX_BYTES=\([0-9]*\)/\1/p' shai-dispatch)
HEAD_BYTES=$(sed -n 's/^HEAD_BYTES=\([0-9]*\)/\1/p' shai-dispatch)
# TAIL_BYTES is derived in shai-dispatch (MAX_BYTES - HEAD_BYTES), so derive it here too instead
# of grepping a literal: that keeps the documented head/tail split honest without adding a
# second source of truth.
TAIL_BYTES=""
if [ -n "$MAX_BYTES" ] && [ -n "$HEAD_BYTES" ]; then TAIL_BYTES=$((MAX_BYTES - HEAD_BYTES)); fi
CONTEXT_BUDGET=$(sed -n 's/.*SHAI_MAX_CONTEXT_BYTES:-\([0-9]*\)}.*/\1/p' shai-context)
SHELLCHECK_VER=$(sed -n 's/^SHELLCHECK_VERSION="\(.*\)"/\1/p' tests/install-lint-tools.sh)
SHFMT_VER=$(sed -n 's/^SHFMT_VERSION="\(.*\)"/\1/p' tests/install-lint-tools.sh)

check() {
  local value="$1" file="$2" label="$3"
  if [ -z "$value" ]; then
    note "could not extract $label — check the sed pattern"
    return
  fi
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

# The required provider variables are a public interface documented in shai-doctor, CLAUDE.md
# and README.md. Extract the names from shai-eval (the source of truth: it is what refuses to
# run without them) and assert each is documented, so a rename cannot silently desync the docs
# the way the old hardcoded default could.
# Match the missing+=(NAME) lines in missing_config rather than the surrounding test syntax:
# the name is the only part that must stay in sync with the docs, and anchoring on the guard's
# shape would break the next time that condition is reworded.
REQUIRED_VARS=$(sed -n 's/.*missing+=(\([A-Z_]*\)).*/\1/p' shai-eval)
# Self-maintaining guard: the capture group above only matches a literal ALL_CAPS name inside
# missing+=(...). A refactor that swaps in a variable instead of a literal (e.g.
# missing+=("$url_var")) makes that one call stop matching the pattern -- REQUIRED_VARS then
# silently loses that name while staying non-empty (the sibling calls still extract fine), so
# the "could not extract" guard above never fires and the dropped variable's docs just stop
# being checked, with no failure anywhere. Comparing the extracted count against the number of
# missing+=( call sites in the file closes that gap without hardcoding how many there are today.
MISSING_CALLS=$(grep -c 'missing+=(' shai-eval || true)
EXTRACTED_COUNT=0
if [ -n "$REQUIRED_VARS" ]; then
  EXTRACTED_COUNT=$(printf '%s\n' "$REQUIRED_VARS" | wc -l)
fi
if [ -z "$REQUIRED_VARS" ]; then
  note "could not extract the required provider variables from shai-eval — check the sed pattern"
elif [ "$EXTRACTED_COUNT" -ne "$MISSING_CALLS" ]; then
  note "extracted $EXTRACTED_COUNT required-var name(s) from shai-eval but found $MISSING_CALLS 'missing+=(' call site(s) — the sed pattern did not match every call (e.g. a variable instead of a literal name); fix the pattern or the call so every required provider variable stays covered"
else
  for v in $REQUIRED_VARS; do
    check "$v" shai-doctor "required var $v"
    check "$v" CLAUDE.md "required var $v"
    check "$v" README.md "required var $v"
  done
fi
check "$MAX_BYTES" CLAUDE.md "truncation limit"
check "$MAX_BYTES" README.md "truncation limit"
check "$HEAD_BYTES" CLAUDE.md "truncation head window"
check "$HEAD_BYTES" README.md "truncation head window"
check "$TAIL_BYTES" CLAUDE.md "truncation tail window"
check "$TAIL_BYTES" README.md "truncation tail window"
check "$CONTEXT_BUDGET" CLAUDE.md "context budget"
check "$CONTEXT_BUDGET" shai-doctor "doctor context budget"
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
