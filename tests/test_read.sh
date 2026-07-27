#!/bin/bash
# test_read.sh — unit tests for shai-read
# Covers: shai-read — envelope shape, source selection, empty input, multi-line
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-read"

OUT=$(echo "Hello shai" | "$DIR/shai-read")
assert_contains "$OUT" '"type":"message"' "read: envelope"
assert_contains "$OUT" '"source":"user"' "read: user source"
assert_contains "$OUT" '"text":"Hello shai"' "read: payload text"

SYSOUT=$(echo "sys prompt" | "$DIR/shai-read" --system)
assert_contains "$SYSOUT" '"source":"system"' "read: --system source"

EMPTY=$(printf '' | "$DIR/shai-read")
RC=$?
assert_eq "$EMPTY" "" "read: empty input → empty"
assert_eq "$RC" "0" "read: empty input → exit 0"

# new: a non---system first arg does not switch the source away from user
ARGOUT=$(echo "hi" | "$DIR/shai-read" not-a-flag)
assert_contains "$ARGOUT" '"source":"user"' "read: non---system arg still user source"

# new: multi-line input is preserved verbatim (JSON-encoded newline)
MULTI=$(printf 'line1\nline2' | "$DIR/shai-read")
assert_contains "$MULTI" 'line1\nline2' "read: multi-line input preserved"

finish
