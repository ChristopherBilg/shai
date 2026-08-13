#!/bin/bash
# doctor-sync.sh — verify shai-doctor covers all tool-declared dependencies
# Usage: ./tests/doctor-sync.sh
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

# Capture shai-doctor output (stderr → stdout for grepping)
DOCTOR_OUT=$(bash "$ROOT/shai-doctor" 2>&1) || true

# Extract all requires.tools from tool.json files
for tj in "$ROOT"/tools/*/tool.json; do
  [ -f "$tj" ] || continue
  tname=$(jq -r '.name' "$tj")
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    if echo "$DOCTOR_OUT" | grep -qE "\[(OK|WARN|FAIL)\][[:space:]]+${dep}$"; then
      ok "$tname requires tool '$dep' — covered by shai-doctor"
    else
      note "$tname requires tool '$dep' — NOT found in shai-doctor output"
    fi
  done < <(jq -r '.capabilities.requires.tools // [] | .[]' "$tj" 2>/dev/null)

  # Check env vars
  while IFS= read -r env_name; do
    [ -n "$env_name" ] || continue
    if echo "$DOCTOR_OUT" | grep -qE "\[(OK|WARN|FAIL)\][[:space:]]+${env_name}$"; then
      ok "$tname requires env '$env_name' — covered by shai-doctor"
    else
      note "$tname requires env '$env_name' — NOT found in shai-doctor output"
    fi
  done < <(jq -r '.capabilities.requires.env // [] | .[].name' "$tj" 2>/dev/null)
done

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}DOCTOR SYNC OK${NC}"
  exit 0
else
  echo -e "${RED}DOCTOR SYNC FAILED${NC} — shai-doctor does not cover all tool-declared deps"
  exit 1
fi
