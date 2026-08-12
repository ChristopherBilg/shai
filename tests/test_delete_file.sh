#!/bin/bash
# test_delete_file.sh — unit tests for delete_file tool
# Covers: tools/delete_file/run.sh — success, missing file, directory rejection, symlink handling
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

# --- dangling symlink deleted successfully ---
ln -s "$TDIR/nonexistent_target" "$TDIR/dangling_link"
OUT=$("$DIR/tools/delete_file/run.sh" "{\"path\":\"$TDIR/dangling_link\"}")
assert_eq "$?" "0" "delete: dangling symlink exits 0"
assert_contains "$OUT" "Deleted" "delete: dangling symlink output contains Deleted"
if [ ! -L "$TDIR/dangling_link" ]; then
  echo -e "  ${GREEN}✓${NC} delete: dangling symlink removed from disk"
else
  echo -e "  ${RED}✗${NC} delete: dangling symlink still exists after delete"
  FAILED=1
fi

# --- symlink to directory deleted (target intact) ---
mkdir -p "$TDIR/real_dir"
echo "keep" >"$TDIR/real_dir/file.txt"
ln -s "$TDIR/real_dir" "$TDIR/dir_link"
OUT=$("$DIR/tools/delete_file/run.sh" "{\"path\":\"$TDIR/dir_link\"}")
assert_eq "$?" "0" "delete: symlink-to-directory exits 0"
assert_contains "$OUT" "Deleted" "delete: symlink-to-directory output contains Deleted"
if [ ! -L "$TDIR/dir_link" ]; then
  echo -e "  ${GREEN}✓${NC} delete: symlink-to-directory removed from disk"
else
  echo -e "  ${RED}✗${NC} delete: symlink-to-directory still exists after delete"
  FAILED=1
fi
if [ -d "$TDIR/real_dir" ] && [ -f "$TDIR/real_dir/file.txt" ]; then
  echo -e "  ${GREEN}✓${NC} delete: directory target intact after symlink delete"
else
  echo -e "  ${RED}✗${NC} delete: directory target was damaged by symlink delete"
  FAILED=1
fi

finish
