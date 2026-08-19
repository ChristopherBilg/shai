#!/bin/bash
# test_print_file.sh — unit tests for the print_file tool
# Covers: tools/print_file/run.sh — unchanged default output, line_numbers, start/end range, bad input
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "print_file"

TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")
RUN="$DIR/tools/print_file/run.sh"

FIXTURE="$TDIR/lines.txt"
printf 'alpha\nbravo\ncharlie\ndelta\necho\nfoxtrot\n' >"$FIXTURE"

# numbered <n> <text>: the cat -n style prefix the tool emits for line <n>.
numbered() { printf '%6d\t%s' "$1" "$2"; }

# --- default path: no new fields, output identical to the file itself ---
"$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p}')" >"$TDIR/default.out" 2>&1
assert_eq "$?" "0" "default: exits 0"
if cmp -s "$FIXTURE" "$TDIR/default.out"; then
  echo -e "  ${GREEN}✓${NC} default: output is byte-identical to the file"
else
  echo -e "  ${RED}✗${NC} default: output differs from the file"
  FAILED=1
fi

# --- explicit falsy/null new fields behave exactly like the default ---
"$RUN" "$(jq -nc --arg p "$FIXTURE" \
  '{path:$p,line_numbers:false,start_line:null,end_line:null}')" >"$TDIR/explicit.out" 2>&1
assert_eq "$?" "0" "default: explicit false/null fields exit 0"
if cmp -s "$FIXTURE" "$TDIR/explicit.out"; then
  echo -e "  ${GREEN}✓${NC} default: explicit false/null fields are byte-identical to the file"
else
  echo -e "  ${RED}✗${NC} default: explicit false/null fields changed the output"
  FAILED=1
fi

# --- default path on a missing file: unchanged failure behaviour ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR/no_such_file" '{path:$p}')" 2>&1)
assert_eq "$?" "1" "default: missing file exits 1"
assert_contains "$OUT" "$TDIR/no_such_file" "default: missing file error names the path"

# --- line_numbers ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,line_numbers:true}')")
assert_eq "$?" "0" "line_numbers: exits 0"
assert_contains "$OUT" "$(numbered 1 alpha)" "line_numbers: first line is numbered 1"
assert_contains "$OUT" "$(numbered 6 foxtrot)" "line_numbers: last line is numbered 6"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "6" "line_numbers: all 6 lines printed"

# --- start_line + end_line range ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:2,end_line:4}')")
assert_eq "$?" "0" "range: exits 0"
assert_eq "$OUT" "$(printf 'bravo\ncharlie\ndelta')" "range: prints only lines 2-4"

# --- range + line_numbers: numbers stay absolute file positions ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:3,end_line:4,line_numbers:true}')")
assert_eq "$?" "0" "range+line_numbers: exits 0"
assert_eq "$OUT" "$(printf '%s\n%s' "$(numbered 3 charlie)" "$(numbered 4 delta)")" \
  "range+line_numbers: numbering is absolute, not window-relative"

# --- single-line window (start_line == end_line) ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:5,end_line:5}')")
assert_eq "$?" "0" "range: start_line == end_line exits 0"
assert_eq "$OUT" "echo" "range: start_line == end_line prints exactly that line"

# --- start_line alone runs to EOF ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:5}')")
assert_eq "$?" "0" "range: start_line alone exits 0"
assert_eq "$OUT" "$(printf 'echo\nfoxtrot')" "range: start_line alone prints through EOF"

# --- end_line alone starts at line 1 ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,end_line:2}')")
assert_eq "$?" "0" "range: end_line alone exits 0"
assert_eq "$OUT" "$(printf 'alpha\nbravo')" "range: end_line alone starts at line 1"

# --- out-of-range windows: past EOF is an empty window, not an error ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:99,end_line:120}')")
assert_eq "$?" "0" "range: window past EOF exits 0"
assert_eq "$OUT" "" "range: window past EOF prints nothing"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:5,end_line:9000}')")
assert_eq "$?" "0" "range: end_line past EOF exits 0"
assert_eq "$OUT" "$(printf 'echo\nfoxtrot')" "range: end_line past EOF clamps to EOF"

# --- invalid range and line values ---
OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:4,end_line:2}')" 2>&1)
assert_eq "$?" "1" "invalid: start_line > end_line exits 1"
assert_contains "$OUT" "start_line (4) must be less than or equal to end_line (2)" \
  "invalid: start_line > end_line error message"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:0}')" 2>&1)
assert_eq "$?" "1" "invalid: start_line 0 exits 1"
assert_contains "$OUT" "start_line must be a positive integer" "invalid: start_line 0 error message"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,end_line:-3}')" 2>&1)
assert_eq "$?" "1" "invalid: negative end_line exits 1"
assert_contains "$OUT" "end_line must be a positive integer" "invalid: negative end_line error message"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,start_line:"abc"}')" 2>&1)
assert_eq "$?" "1" "invalid: non-numeric start_line exits 1"
assert_contains "$OUT" "start_line must be a positive integer" \
  "invalid: non-numeric start_line error message"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,end_line:2.5}')" 2>&1)
assert_eq "$?" "1" "invalid: fractional end_line exits 1"
assert_contains "$OUT" "end_line must be a positive integer" \
  "invalid: fractional end_line error message"

OUT=$("$RUN" "$(jq -nc --arg p "$FIXTURE" '{path:$p,line_numbers:"yes"}')" 2>&1)
assert_eq "$?" "1" "invalid: non-boolean line_numbers exits 1"
assert_contains "$OUT" "line_numbers must be a boolean" "invalid: non-boolean line_numbers message"

# --- path errors on the range path get explicit diagnostics ---
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR/no_such_file" '{path:$p,start_line:1,end_line:2}')" 2>&1)
assert_eq "$?" "1" "range: missing file exits 1"
assert_contains "$OUT" "file not found" "range: missing file error message"

mkdir -p "$TDIR/subdir"
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR/subdir" '{path:$p,line_numbers:true}')" 2>&1)
assert_eq "$?" "1" "line_numbers: directory exits 1"
assert_contains "$OUT" "cannot print a directory" "line_numbers: directory error message"

# --- an empty file yields empty output in every mode ---
: >"$TDIR/empty.txt"
OUT=$("$RUN" "$(jq -nc --arg p "$TDIR/empty.txt" '{path:$p,line_numbers:true,start_line:1}')")
assert_eq "$?" "0" "empty file: exits 0"
assert_eq "$OUT" "" "empty file: prints nothing"

finish
