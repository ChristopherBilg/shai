#!/bin/bash
# test_constants_sync.sh — tests the constants documentation sync checker
# Covers: tests/constants-sync.sh — detection of missing constants, pass on full sync
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "constants-sync"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")

# --- fixture source scripts with extractable constants ---
mkdir -p "$FIX/tests"
cat >"$FIX/shai-eval" <<'SCRIPT'
MODEL="${SHAI_MODEL:-testmodel}"
MAX_TOKENS="999"
SCRIPT
cat >"$FIX/shai-dispatch" <<'SCRIPT'
MAX_BYTES=888
SCRIPT
cat >"$FIX/shai-context" <<'SCRIPT'
MAX_BYTES="${SHAI_MAX_CONTEXT_BYTES:-777}"
SCRIPT
cat >"$FIX/tests/install-lint-tools.sh" <<'SCRIPT'
SHELLCHECK_VERSION="v1.2.3"
SHFMT_VERSION="v4.5.6"
SCRIPT

# --- all constants present → pass ---
cat >"$FIX/CLAUDE.md" <<'EOF'
model testmodel, truncation 888, budget 777, shellcheck v1.2.3, shfmt v4.5.6
EOF

OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "0" "all constants present → exit 0"
assert_contains "$OUT" "CONSTANTS SYNC OK" "all constants present → OK banner"

# --- missing from CLAUDE.md → fail ---
cat >"$FIX/CLAUDE.md" <<'EOF'
model testmodel, truncation 888, budget 777, shellcheck v1.2.3
EOF
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from CLAUDE.md → exit 1"
assert_contains "$OUT" "CLAUDE.md" "missing from CLAUDE.md → names file"
assert_contains "$OUT" "shfmt version" "missing from CLAUDE.md → names constant"

finish
