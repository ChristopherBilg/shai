#!/bin/bash
# test_search_files.sh — unit tests for the search_files tool
# Covers: tools/search_files/run.sh — match, no-match, ignore_case, glob, max_results cap, binary skip, missing path, default path
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "search_files"

TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")
RUN="$DIR/tools/search_files/run.sh"

# --- fixture tree ---
mkdir -p "$TDIR/src" "$TDIR/lib" "$TDIR/.git"
printf 'hello world\ngoodbye world\nhello again\n' >"$TDIR/src/main.sh"
printf 'HELLO UPPER\nhello lower\n' >"$TDIR/src/upper.sh"
printf 'no match here\nnothing relevant\n' >"$TDIR/lib/util.sh"
printf 'hello from txt\n' >"$TDIR/src/notes.txt"
# binary file: a few NUL bytes so grep -I skips it
printf 'hello\x00binary\x00data\n' >"$TDIR/src/blob.bin"
# file inside .git should be excluded
printf 'hello from git internals\n' >"$TDIR/.git/config"

# --- basic match ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p}')" 2>&1)
assert_eq "$?" "0" "basic: exits 0"
assert_contains "$OUT" "src/main.sh" "basic: includes src/main.sh"
assert_contains "$OUT" "hello world" "basic: includes matching line"

# --- no match returns exit 0, empty output ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"zzz_no_match_zzz",path:$p}')" 2>&1)
assert_eq "$?" "0" "no match: exits 0"
assert_eq "$OUT" "" "no match: empty output"

# --- ignore_case ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,ignore_case:true}')" 2>&1)
assert_eq "$?" "0" "ignore_case: exits 0"
assert_contains "$OUT" "HELLO UPPER" "ignore_case: matches uppercase"
assert_contains "$OUT" "hello lower" "ignore_case: matches lowercase"

OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,ignore_case:false}')" 2>&1)
assert_eq "$?" "0" "case sensitive: exits 0"
# HELLO UPPER should not appear in case-sensitive search
if [[ "$OUT" == *"HELLO UPPER"* ]]; then
  echo -e "  ${RED}✗${NC} case sensitive: should not match HELLO UPPER"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} case sensitive: does not match HELLO UPPER"
fi

# --- glob filtering ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,glob:"*.sh"}')" 2>&1)
assert_eq "$?" "0" "glob: exits 0"
assert_contains "$OUT" "main.sh" "glob: includes .sh files"
if [[ "$OUT" == *"notes.txt"* ]]; then
  echo -e "  ${RED}✗${NC} glob: should exclude .txt files"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} glob: excludes .txt files"
fi

# --- max_results cap ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,max_results:2}')" 2>&1)
assert_eq "$?" "0" "max_results: exits 0"
LINES=$(printf '%s\n' "$OUT" | grep -c '.')
if [ "$LINES" -le 2 ]; then
  echo -e "  ${GREEN}✓${NC} max_results: output capped at 2 lines"
else
  echo -e "  ${RED}✗${NC} max_results: expected at most 2 lines, got $LINES"
  FAILED=1
fi

# --- binary files skipped (grep -I) ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p}')" 2>&1)
if [[ "$OUT" == *"blob.bin"* ]]; then
  echo -e "  ${RED}✗${NC} binary skip: should not include blob.bin"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} binary skip: blob.bin excluded"
fi

# --- .git directory excluded ---
if [[ "$OUT" == *".git/config"* ]]; then
  echo -e "  ${RED}✗${NC} .git exclusion: should not search .git/"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} .git exclusion: .git/ excluded"
fi

# --- missing path → exit 1 ---
OUT=$("$RUN" "$(jq -nc '{pattern:"hello",path:"/no/such/dir"}')" 2>&1)
assert_eq "$?" "1" "missing path: exits 1"
assert_contains "$OUT" "not found" "missing path: error mentions not found"

# --- pattern is required ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{path:$p}')" 2>&1)
assert_eq "$?" "1" "missing pattern: exits 1"
assert_contains "$OUT" "pattern" "missing pattern: error mentions pattern"

# --- max_results validation: must be positive integer ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,max_results:0}')" 2>&1)
assert_eq "$?" "1" "invalid max_results 0: exits 1"

OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,max_results:-5}')" 2>&1)
assert_eq "$?" "1" "invalid max_results negative: exits 1"

OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,max_results:501}')" 2>&1)
assert_eq "$?" "1" "invalid max_results >500: exits 1"

# --- path defaults to . (current directory) ---
ORIG_PWD=$PWD
cd "$TDIR" || exit 1
OUT=$("$RUN" "$(jq -nc '{pattern:"hello"}')" 2>&1)
assert_eq "$?" "0" "default path: exits 0"
assert_contains "$OUT" "main.sh" "default path: finds files in cwd"
cd "$ORIG_PWD" || exit 1

# --- output format: path:line_number: text ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello world",path:$p}')" 2>&1)
assert_eq "$?" "0" "output format: exits 0"
if [[ "$OUT" =~ src/main\.sh:[0-9]+: ]]; then
  echo -e "  ${GREEN}✓${NC} output format: matches path:line_number: pattern"
else
  echo -e "  ${RED}✗${NC} output format: expected path:line_number: pattern, got: $OUT"
  FAILED=1
fi

finish
