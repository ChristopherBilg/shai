#!/bin/bash
# test_delete_file.sh — unit tests for delete_file tool
# Covers: tools/delete_file/run.sh — success, missing file, directory rejection
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "delete_file"

TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")

# --- successful delete ---
echo "hello" >"$TDIR/target.txt"
OUT=$("$DIR/tools/delete_file/run.sh" "{\"path\":\"$TDIR/target.txt\"}")
assert_eq "$?" "0" "delete: exits 0 on success"
assert_contains "$OUT" "Deleted" "delete: output contains Deleted"
if [ ! -e "$TDIR/target.txt" ]; then
  echo -e "  ${GREEN}✓${NC} delete: file removed from disk"
else
  echo -e "  ${RED}✗${NC} delete: file still exists after delete"
  FAILED=1
fi

# --- error on missing file ---
OUT=$("$DIR/tools/delete_file/run.sh" "{\"path\":\"$TDIR/no_such_file\"}" 2>&1)
assert_eq "$?" "1" "delete: missing file exits 1"
assert_contains "$OUT" "file not found" "delete: missing file error message"

# --- error on directory ---
mkdir -p "$TDIR/subdir"
OUT=$("$DIR/tools/delete_file/run.sh" "{\"path\":\"$TDIR/subdir\"}" 2>&1)
assert_eq "$?" "1" "delete: directory exits 1"
assert_contains "$OUT" "cannot delete directory" "delete: directory error message"

finish
