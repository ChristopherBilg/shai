#!/bin/bash
# test_tools_sync.sh — tests the tool documentation sync checker
# Covers: tests/tools-sync.sh — detection of missing tools in each file, pass on full sync, empty
#   tools, and workflow prompts naming tools their own policy.json does not grant
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools-sync"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")

# --- fixture: two tools ---
mkdir -p "$FIX/tools/alpha" "$FIX/tools/beta" "$FIX/prompts"
cat >"$FIX/tools/alpha/tool.json" <<'EOF'
{"name":"alpha","description":"tool alpha","input_schema":{"type":"object","properties":{}}}
EOF
cat >"$FIX/tools/beta/tool.json" <<'EOF'
{"name":"beta","description":"tool beta","input_schema":{"type":"object","properties":{}}}
EOF

# --- all present → pass ---
echo "tools: alpha and beta" >"$FIX/prompts/system.txt"
echo "tools: alpha and beta" >"$FIX/README.md"
echo "tools: alpha and beta" >"$FIX/CLAUDE.md"

OUT="$(bash "$DIR/tests/tools-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "0" "all tools present → exit 0"
assert_contains "$OUT" "TOOLS SYNC OK" "all tools present → OK banner"

# --- missing from system.txt → fail ---
echo "tools: alpha only" >"$FIX/prompts/system.txt"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from system.txt → exit 1"
assert_contains "$OUT" "prompts/system.txt missing" "missing from system.txt → names file"
assert_contains "$OUT" "beta" "missing from system.txt → names tool"

# --- missing from README.md → fail ---
echo "tools: alpha and beta" >"$FIX/prompts/system.txt"
echo "tools: alpha only" >"$FIX/README.md"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from README.md → exit 1"
assert_contains "$OUT" "README.md missing" "missing from README.md → names file"

# --- missing from CLAUDE.md → fail ---
echo "tools: alpha and beta" >"$FIX/README.md"
echo "tools: alpha only" >"$FIX/CLAUDE.md"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from CLAUDE.md → exit 1"
assert_contains "$OUT" "CLAUDE.md missing" "missing from CLAUDE.md → names file"

# --- empty tools directory → pass ---
EMPTY="$(mktemp -d)"
_CLEANUP_DIRS+=("$EMPTY")
mkdir -p "$EMPTY/tools" "$EMPTY/prompts"
echo "no tools" >"$EMPTY/prompts/system.txt"
echo "no tools" >"$EMPTY/README.md"
echo "no tools" >"$EMPTY/CLAUDE.md"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$EMPTY" 2>&1)"
assert_eq "$?" "0" "empty tools dir → exit 0"

# --- workflow prompts vs. the tools their own policy.json grants ---
WF="$(mktemp -d)"
_CLEANUP_DIRS+=("$WF")
mkdir -p "$WF/tools/alpha" "$WF/tools/gamma" "$WF/prompts" \
  "$WF/workflows/wfok" "$WF/workflows/wfro" "$WF/workflows/wfmute"
cat >"$WF/tools/alpha/tool.json" <<'EOF'
{"name":"alpha","description":"write tool alpha","capabilities":{"read_only":false},"input_schema":{"type":"object","properties":{}}}
EOF
cat >"$WF/tools/gamma/tool.json" <<'EOF'
{"name":"gamma","description":"read-only tool gamma","capabilities":{"read_only":true},"input_schema":{"type":"object","properties":{}}}
EOF
for f in "$WF/prompts/system.txt" "$WF/README.md" "$WF/CLAUDE.md"; do
  echo "tools: alpha and gamma" >"$f"
done
# wfok: names a tool its policy explicitly allows.
echo '{"rules":[{"tool":"alpha","action":"allow"}]}' >"$WF/workflows/wfok/policy.json"
echo 'Call the alpha tool to do the work.' >"$WF/prompts/wfok.txt"
# wfro: names a read-only tool with no matching rule — shai-dispatch auto-allows it.
echo '{"rules":[]}' >"$WF/workflows/wfro/policy.json"
echo 'Call the gamma tool to read the file.' >"$WF/prompts/wfro.txt"
# wfmute: a policy with no prompt file at all (the pure-bash dispatchers) — skipped.
echo '{"rules":[{"tool":"alpha","action":"allow"}]}' >"$WF/workflows/wfmute/policy.json"

OUT="$(bash "$DIR/tests/tools-sync.sh" "$WF" 2>&1)"
assert_eq "$?" "0" "prompt names only granted tools → exit 0"
assert_contains "$OUT" "prompts/wfok.txt names only tools" "granted tool → per-prompt ok line"
assert_contains "$OUT" "prompts/wfro.txt names only tools" "read-only fallback counts as granted"
# Assert the wfmute skip directly: without this, a differently-handled policy-without-prompt
# case (checked against nothing, or reported) would still leave the suite green.
wfmute_mentioned=no
[[ "$OUT" == *wfmute* ]] && wfmute_mentioned=yes
assert_eq "$wfmute_mentioned" "no" "policy with no prompt → absent from the output"

# --- "default": "allow" grants every tool, so the prompt is not checked ---
mkdir -p "$WF/workflows/wfall"
echo '{"default":"allow","rules":[]}' >"$WF/workflows/wfall/policy.json"
echo 'Call the alpha tool to do the work.' >"$WF/prompts/wfall.txt"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$WF" 2>&1)"
assert_eq "$?" "0" "write tool named under default allow → exit 0"
assert_contains "$OUT" "every tool is granted" "default allow → prompt not checked"

# --- prompt names a write tool the policy does not grant → fail ---
mkdir -p "$WF/workflows/wfbad"
echo '{"rules":[{"tool":"gamma","action":"allow"}]}' >"$WF/workflows/wfbad/policy.json"
echo 'Call the alpha tool before committing.' >"$WF/prompts/wfbad.txt"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$WF" 2>&1)"
assert_eq "$?" "1" "prompt names an ungranted tool → exit 1"
assert_contains "$OUT" "prompts/wfbad.txt names 1 tool(s)" "ungranted tool → names the prompt"
assert_contains "$OUT" "does not grant: alpha" "ungranted tool → names the tool"
rm -rf "$WF/workflows/wfbad" "$WF/prompts/wfbad.txt"

# --- an explicit non-allow default removes the read-only fallback → fail ---
echo '{"default":"deny","rules":[]}' >"$WF/workflows/wfro/policy.json"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$WF" 2>&1)"
assert_eq "$?" "1" "read-only tool under default deny → exit 1"
assert_contains "$OUT" "does not grant: gamma" "default deny → read-only tool reported"

# --- the real repo satisfies the invariant ---
OUT="$(bash "$DIR/tests/tools-sync.sh" 2>&1)"
assert_eq "$?" "0" "repo: docs and workflow prompts are in sync"

finish
