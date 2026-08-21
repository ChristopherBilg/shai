#!/bin/bash
# test_search_files.sh — unit tests for the search_files tool
# Covers: tools/search_files/run.sh — match, no-match, ignore_case, glob, max_results cap and
# truncation marker, binary skip, missing path, default path, single-file path, grep failure modes
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
# default-excluded paths (see #118): dotenv files, .ssh, node_modules
printf 'hello from dotenv\nSECRET=topsecret\n' >"$TDIR/.env"
printf 'HELLO FROM ENV LOCAL\n' >"$TDIR/.env.local"
printf 'hello from env example\n' >"$TDIR/.env.example"
mkdir -p "$TDIR/.ssh"
printf 'hello from ssh key\n' >"$TDIR/.ssh/id_rsa"
mkdir -p "$TDIR/node_modules"
printf 'hello from deps\n' >"$TDIR/node_modules/pkg.js"

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

# --- max_results cap + truncation marker ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,max_results:2}')" 2>&1)
assert_eq "$?" "0" "max_results: exits 0"
LINES=$(printf '%s\n' "$OUT" | grep -c ':[0-9][0-9]*:' || true)
if [ "$LINES" -le 2 ]; then
  echo -e "  ${GREEN}✓${NC} max_results: match rows capped at 2"
else
  echo -e "  ${RED}✗${NC} max_results: expected at most 2 match rows, got $LINES"
  FAILED=1
fi
assert_contains "$OUT" "[truncated: showing first 2 matches]" "max_results: emits truncation marker"

# --- no truncation marker when the cap is not reached ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello world",path:$p}')" 2>&1)
assert_eq "$?" "0" "untruncated: exits 0"
if [[ "$OUT" == *"truncated"* ]]; then
  echo -e "  ${RED}✗${NC} untruncated: should not emit a truncation marker"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} untruncated: no truncation marker"
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

# --- default exclusions (see #118): .env, .env.*, .ssh, node_modules ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p}')" 2>&1)
assert_eq "$?" "0" "exclusions: exits 0"
for excluded in ".env" ".env.local" ".env.example" ".ssh/id_rsa" "node_modules/pkg.js"; do
  if [[ "$OUT" == *"$excluded"* ]]; then
    echo -e "  ${RED}✗${NC} exclusions: should not match $excluded"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} exclusions: $excluded excluded from results"
  fi
done

# a pattern that only exists inside an excluded file must yield no results from it
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"HELLO FROM ENV LOCAL",path:$p}')" 2>&1)
assert_eq "$?" "0" "exclusions: exclusive pattern exits 0"
assert_eq "$OUT" "" "exclusions: pattern inside excluded .env.local is not found"

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

# --- ignore_case must be a boolean (JSON string "true" is rejected, like print_file) ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"hello",path:$p,ignore_case:"true"}')" 2>&1)
assert_eq "$?" "1" "non-boolean ignore_case: exits 1"
assert_contains "$OUT" "ignore_case must be a boolean" "non-boolean ignore_case: explains why"

# --- grep failure surfaces as exit 1, not as a successful empty result ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR" '{pattern:"[",path:$p}')" 2>&1)
assert_eq "$?" "1" "invalid regex: exits 1"
assert_contains "$OUT" "error:" "invalid regex: reports an error"

# --- path may be a single file, and rows are still prefixed with the path ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR/src/main.sh" '{pattern:"hello",path:$p}')" 2>&1)
assert_eq "$?" "0" "single file: exits 0"
assert_contains "$OUT" "main.sh:1:hello world" "single file: prefixes path and line number"
if [[ "$OUT" == *"upper.sh"* ]]; then
  echo -e "  ${RED}✗${NC} single file: should not search sibling files"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} single file: only the named file is searched"
fi

finish
