#!/bin/bash
# test_constants_sync.sh — tests the constants documentation sync checker
# Covers: tests/constants-sync.sh — detection of missing constants, pass on full sync
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "constants-sync"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")

# fake_exports: the runnable `export VAR=` lines the required-var quick-start checks look for.
# Those checks grep for the export form rather than the bare variable name, so every fixture
# meant to be fully synced needs them. Kept separate from each block's constants line so a
# block that deliberately omits one constant still exports all three, preserving its single
# cause.
fake_exports() {
  printf 'export SHAI_API_KEY=sk-x\nexport SHAI_API_URL=https://example.invalid/v1/chat/completions\nexport SHAI_MODEL=m\n'
}

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
fake_exports >>"$FIX/CLAUDE.md"
cat >"$FIX/README.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, head 666, tail 222
EOF
fake_exports >>"$FIX/README.md"

OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "0" "all constants present → exit 0"
assert_contains "$OUT" "CONSTANTS SYNC OK" "all constants present → OK banner"

# --- missing from CLAUDE.md → fail ---
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3
EOF
fake_exports >>"$FIX/CLAUDE.md"
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from CLAUDE.md → exit 1"
# Full label+value+file phrase, not just "shfmt version": that label is checked against exactly
# one file today, but the bare label alone doesn't pin down which file failed, so a check
# mistakenly redirected to the wrong file would still print a "missing" line containing "shfmt
# version" and this assertion would not notice.
assert_contains "$OUT" "shfmt version (v4.5.6) missing from CLAUDE.md" "missing from CLAUDE.md → names constant"

# --- missing from README.md → fail ---
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3, shfmt v4.5.6
EOF
fake_exports >>"$FIX/CLAUDE.md"
cat >"$FIX/README.md" <<'EOF'
no constants here
EOF
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from README.md → exit 1"
# Full label+value+file phrase: "truncation limit" is also checked against CLAUDE.md, which
# still passes here and prints "truncation limit (888) in CLAUDE.md" — a passing sibling line
# containing the bare label. The bare-label assertion would be satisfied by that sibling alone
# even if the README.md-targeted check never ran.
assert_contains "$OUT" "truncation limit (888) missing from README.md" "missing from README.md → names constant"

# --- missing from shai-doctor → fail ---
cat >"$FIX/README.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, head 666, tail 222
EOF
fake_exports >>"$FIX/README.md"
# Keep the pre-existing SHAI_MAX_CONTEXT_BYTES check_config line intact (only SHAI_API_URL is
# omitted) so this block has a single cause: dropping it too would incidentally also fail the
# unrelated "doctor context budget" check, which would keep exit 1 and keep "shai-doctor" in the
# output even if the required-vars-in-shai-doctor check were never run at all.
cat >"$FIX/shai-doctor" <<'SCRIPT'
check_config SHAI_API_KEY
check_config SHAI_MODEL
check_config SHAI_MAX_CONTEXT_BYTES "777"
SCRIPT
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "missing from shai-doctor → exit 1"
# Full label+value+file phrase, not just "required var SHAI_API_URL": that label is also checked
# against CLAUDE.md and README.md, both of which still pass here and print "... in CLAUDE.md" /
# "... in README.md" — passing siblings containing the bare label. The bare-label assertion was
# satisfied by those sibling lines alone, regardless of whether shai-doctor was ever checked for
# this variable (confirmed: redirecting or deleting the shai-doctor-targeted check call left this
# assertion green). Anchoring on "missing from shai-doctor" ties the assertion to the one line
# only the targeted check can produce.
assert_contains "$OUT" "required var SHAI_API_URL (SHAI_API_URL) missing from shai-doctor" "missing from shai-doctor → names constant"

# --- partial refactor drops a var from missing+=( ) silently (M9 self-maintaining guard) ---
# Reproduces the exact defect: rewriting one missing+=(NAME) call to reference a variable
# instead of a literal (missing+=("$url_var")) makes the capture-group sed no longer match that
# call, so REQUIRED_VARS silently drops SHAI_API_URL while staying non-empty (SHAI_API_KEY and
# SHAI_MODEL still extract fine from their own untouched calls) -- without a call-count guard,
# constants-sync.sh would print CONSTANTS SYNC OK despite no longer checking SHAI_API_URL
# against the docs at all. Restore shai-doctor to the fully-synced fixture first (it was left
# broken by the block above) so this block's only variable is the mutation itself.
cat >"$FIX/shai-doctor" <<'SCRIPT'
check_config SHAI_API_KEY
check_config SHAI_API_URL
check_config SHAI_MODEL
check_config SHAI_MAX_CONTEXT_BYTES "777"
SCRIPT
cat >"$FIX/shai-eval" <<'SCRIPT'
missing_config() {
  [ -n "${SHAI_API_KEY:-}" ] || missing+=(SHAI_API_KEY)
  local url_var="SHAI_API_URL"
  [ -n "${SHAI_API_URL:-}" ] || missing+=("$url_var")
  [ -n "${SHAI_MODEL:-}" ] || missing+=(SHAI_MODEL)
}
MAX_TOKENS="999"
SCRIPT
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "partial-refactor missing+=(\"\$var\") → exit 1 (self-maintaining guard fires)"
assert_contains "$OUT" "did not match every call" "partial-refactor → guard names the sed/call-count mismatch"

# --- var named in prose but no runnable export line → fail (the M5 shape) ---
# Reproduces the defect the export-form check exists for: a doc can mention a required
# variable many times in prose and still ship a quick-start block that omits it, so the
# copy-pasteable example exits 1. Here CLAUDE.md names all three variables (satisfying the
# bare-name check) and exports only two, which is exactly what shipped on this branch and was
# invisible to the gate. Restore shai-eval first — the block above left it holding the
# partial-refactor mutation, so without this the failure could come from the call-count guard
# instead of the export check.
cat >"$FIX/shai-eval" <<'SCRIPT'
missing_config() {
  [ -n "${SHAI_API_KEY:-}" ] || missing+=(SHAI_API_KEY)
  [ -n "${SHAI_API_URL:-}" ] || missing+=(SHAI_API_URL)
  [ -n "${SHAI_MODEL:-}" ] || missing+=(SHAI_MODEL)
}
MAX_TOKENS="999"
SCRIPT
cat >"$FIX/CLAUDE.md" <<'EOF'
SHAI_API_KEY, SHAI_API_URL, SHAI_MODEL, truncation 888, budget 777, head 666, tail 222, shellcheck v1.2.3, shfmt v4.5.6
export SHAI_API_KEY=sk-x
export SHAI_MODEL=m
EOF
OUT="$(bash "$DIR/tests/constants-sync.sh" "$FIX" 2>&1)"
assert_eq "$?" "1" "named in prose but not exported → exit 1"
# Full label+value+file phrase: "quick-start exports SHAI_API_URL" is checked against README.md
# too, which still passes here and prints "... in README.md" — a passing sibling carrying the
# bare label. Anchoring on "missing from CLAUDE.md" ties this to the one line only the
# CLAUDE.md-targeted export check can produce.
assert_contains "$OUT" "quick-start exports SHAI_API_URL (export SHAI_API_URL=) missing from CLAUDE.md" \
  "named in prose but not exported → names the variable and the file"
# The bare-name check still passes for that same variable, which is the whole point: the two
# checks are not redundant, and only the export-form one catches this.
assert_contains "$OUT" "required var SHAI_API_URL (SHAI_API_URL) in CLAUDE.md" \
  "named in prose but not exported → the bare-name check still passes (so it could not catch this)"

finish
