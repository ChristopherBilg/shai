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
# pure-bash dispatchers) are skipped. "Granted" means an explicit `allow` rule: shai-dispatch's
# per-tool read-only fallback is not guaranteed — the base $SHAI_HOME/policy.json may set a
# `default` or a matching rule before the fallback ever applies — so read-only tools must be
# granted explicitly too (see issue #84). A policy with `"default": "allow"` grants every tool
# at dispatch time, so its prompt is not checked at all.
#
# Deliberate limits, so the invariant stays cheap and free of false positives:
#   - Arg scoping is out of scope: a rule like `ci` with `args.cwd: "/tmp/*"` counts here as an
#     unconditional grant, so a prompt telling the agent to call `ci` without a /tmp cwd still
#     passes even though dispatch would fail closed.
#   - The match is a bare word match, so it cannot tell "use the `ci` tool" from "you cannot run
#     the `ci` tool". A prompt that names a tool only to rule it out must therefore still be
#     backed by a grant, or must avoid naming the tool.
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
  if [ "$policy_default" = "allow" ]; then
    ok "$policy sets \"default\": \"allow\" — every tool is granted, $prompt not checked"
    continue
  fi
  ungranted=()
  for tool in "${TOOLS[@]}"; do
    grep -qw -- "$tool" "$prompt" || continue
    if jq -e --arg t "$tool" 'any(.rules[]?; .tool == $t and .action == "allow")' \
      "$policy" >/dev/null 2>&1; then
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
