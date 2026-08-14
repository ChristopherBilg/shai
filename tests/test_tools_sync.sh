#!/bin/bash
# test_tools_sync.sh — tests the tool documentation sync checker
# Covers: tests/tools-sync.sh — detection of missing tools in each file, pass on full sync, empty tools
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

# --- missing from CLAUDE.md → fail ---
echo "tools: alpha and beta" >"$FIX/prompts/system.txt"
echo "tools: alpha only" >"$FIX/CLAUDE.md"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from CLAUDE.md → exit 1"
assert_contains "$OUT" "CLAUDE.md missing" "missing from CLAUDE.md → names file"

# --- empty tools directory → pass ---
EMPTY="$(mktemp -d)"
_CLEANUP_DIRS+=("$EMPTY")
mkdir -p "$EMPTY/tools" "$EMPTY/prompts"
echo "no tools" >"$EMPTY/prompts/system.txt"
echo "no tools" >"$EMPTY/CLAUDE.md"
OUT="$(bash "$DIR/tests/tools-sync.sh" "$EMPTY" 2>&1)"
assert_eq "$?" "0" "empty tools dir → exit 0"

finish
