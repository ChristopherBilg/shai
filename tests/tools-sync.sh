#!/bin/bash
# tools-sync.sh — verify tool mentions in docs, prompts, and workflow policies stay in sync
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

# A workflow's prompt may only name tools its own policy.json grants: the prompt is the
# instruction set and policy.json is the capability set, so a tool named in one and absent from
# the other is an instruction the workflow cannot follow (see issue #74). The prompt for
# workflows/<name>/policy.json is prompts/<name>.txt; workflows with no prompt file (the
# pure-bash dispatchers) are skipped. "Granted" means an explicit `allow` rule, or — when the
# policy sets no `default` — a read-only tool, which shai-dispatch auto-allows as its per-tool
# fallback.
found_policy=0
for policy in workflows/*/policy.json; do
  [ -f "$policy" ] || continue
  found_policy=1
  wf="$(basename "$(dirname "$policy")")"
  prompt="prompts/$wf.txt"
  [ -f "$prompt" ] || continue
  if ! jq empty "$policy" >/dev/null 2>&1; then
    note "$policy is not valid JSON"
    continue
  fi
  policy_default="$(jq -r '.default // ""' "$policy")" || policy_default=""
  ro_allowed=no
  if [ -z "$policy_default" ] || [ "$policy_default" = "allow" ]; then
    ro_allowed=yes
  fi
  ungranted=()
  for tool in "${TOOLS[@]}"; do
    grep -qw -- "$tool" "$prompt" || continue
    if jq -e --arg t "$tool" 'any(.rules[]?; .tool == $t and .action == "allow")' \
      "$policy" >/dev/null 2>&1; then
      continue
    fi
    read_only="$(jq -r '.capabilities.read_only // false' "tools/$tool/tool.json" 2>/dev/null)" ||
      read_only=false
    if [ "$ro_allowed" = "yes" ] && [ "$read_only" = "true" ]; then
      continue
    fi
    ungranted+=("$tool")
  done
  if [ "${#ungranted[@]}" -eq 0 ]; then
    ok "$prompt names only tools $policy grants"
  else
    note "$prompt names ${#ungranted[@]} tool(s) $policy does not grant: ${ungranted[*]}"
  fi
done
if [ "$found_policy" -eq 0 ]; then
  ok "no workflow policies to check"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}TOOLS SYNC OK${NC}"
  exit 0
else
  echo -e "${RED}TOOLS SYNC FAILED${NC} — mention every tool from tools/*/tool.json in the file(s) above, and keep each workflow prompt to the tools its own policy.json grants"
  exit 1
fi
