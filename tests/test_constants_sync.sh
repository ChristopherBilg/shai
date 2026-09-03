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
missing_config() {
  [ -n "${SHAI_API_KEY:-}" ] || missing+=(SHAI_API_KEY)
  [ -n "${SHAI_API_URL:-}" ] || missing+=(SHAI_API_URL)
  [ -n "${SHAI_MODEL:-}" ] || missing+=(SHAI_MODEL)
}
MAX_TOKENS="999"
SCRIPT
cat >"$FIX/shai-dispatch" <<'SCRIPT'
MAX_BYTES=888
HEAD_BYTES=666
SCRIPT
cat >"$FIX/shai-context" <<'SCRIPT'
MAX_BYTES="${SHAI_MAX_CONTEXT_BYTES:-777}"
SCRIPT
cat >"$FIX/shai-doctor" <<'SCRIPT'
check_config SHAI_API_KEY
check_config SHAI_API_URL
check_config SHAI_MODEL
check_config SHAI_MAX_CONTEXT_BYTES "777"
SCRIPT
cat >"$FIX/tests/install-lint-tools.sh" <<'SCRIPT'
SHELLCHECK_VERSION="v1.2.3"
SHFMT_VERSION="v4.5.6"
SCRIPT

# --- all constants present → pass ---
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3, shfmt v4.5.6
EOF
cat >"$FIX/README.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, head 666, tail 222
EOF

OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "0" "all constants present → exit 0"
assert_contains "$OUT" "CONSTANTS SYNC OK" "all constants present → OK banner"

# --- missing from CLAUDE.md → fail ---
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3
EOF
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from CLAUDE.md → exit 1"
assert_contains "$OUT" "CLAUDE.md" "missing from CLAUDE.md → names file"
assert_contains "$OUT" "shfmt version" "missing from CLAUDE.md → names constant"

# --- missing from README.md → fail ---
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3, shfmt v4.5.6
EOF
cat >"$FIX/README.md" <<'EOF'
no constants here
EOF
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from README.md → exit 1"
assert_contains "$OUT" "README.md" "missing from README.md → names file"
assert_contains "$OUT" "truncation limit" "missing from README.md → names constant"

# --- missing from shai-doctor → fail ---
cat >"$FIX/README.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, head 666, tail 222
EOF
cat >"$FIX/shai-doctor" <<'SCRIPT'
check_config SHAI_API_KEY
check_config SHAI_MODEL
SCRIPT
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from shai-doctor → exit 1"
assert_contains "$OUT" "shai-doctor" "missing from shai-doctor → names file"
assert_contains "$OUT" "required var SHAI_API_URL" "missing from shai-doctor → names constant"

finish
