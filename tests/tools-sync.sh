#!/bin/bash
# tools-sync.sh — verify tool lists in docs and prompts match tools/*/tool.json
# Usage: ./tests/tools-sync.sh [root-dir]
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

mapfile -t TOOLS < <(
  for tj in tools/*/tool.json; do
    [ -f "$tj" ] || continue
    jq -r '.name' "$tj"
  done | sort
)

if [ "${#TOOLS[@]}" -eq 0 ]; then
  echo "No tools found; nothing to check."
  exit 0
fi

FILES=(
  "prompts/system.txt"
  "README.md"
  "CLAUDE.md"
)

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    note "$f not found"
    continue
  fi
  missing=()
  for tool in "${TOOLS[@]}"; do
    grep -qw "$tool" "$f" || missing+=("$tool")
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    ok "$f lists all ${#TOOLS[@]} tools"
  else
    note "$f missing ${#missing[@]} tool(s): ${missing[*]}"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}TOOLS SYNC OK${NC}"
  exit 0
else
  echo -e "${RED}TOOLS SYNC FAILED${NC} — update the file(s) above to mention all tools from tools/*/tool.json"
  exit 1
fi
