#!/bin/bash
# test_file_perms.sh — regression tests: the file-writing tools must preserve permission bits
# Covers: tools/patch_file/run.sh, tools/write_file/run.sh — mode preserved across patch/overwrite
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "file permission preservation"

TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")

# mode_of <path>: octal permission bits (GNU stat first, BSD/macOS fallback)
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# assert_exec <path> <description>: the file exists and carries the executable bit
assert_exec() {
  if [ -x "$1" ]; then
    echo -e "  ${GREEN}✓${NC} $2"
  else
    echo -e "  ${RED}✗${NC} $2 (mode is $(mode_of "$1"))"
    FAILED=1
  fi
}

# --- patch_file: 0755 script stays executable ---
# Regression: the patched content went to a `mktemp` file (mode 0600) and `mv` carried
# that mode onto the destination, silently dropping the exec bit (and go+r).
printf '#!/bin/bash\necho old\n' >"$TDIR/script.sh"
chmod 755 "$TDIR/script.sh"
OUT=$("$DIR/tools/patch_file/run.sh" "$(jq -nc --arg p "$TDIR/script.sh" '{path:$p,old_string:"echo old",new_string:"echo new"}')")
assert_eq "$?" "0" "patch_file: exits 0 on success"
assert_contains "$OUT" "Patched" "patch_file: output contains Patched"
assert_contains "$(cat "$TDIR/script.sh")" "echo new" "patch_file: content was patched"
assert_eq "$(mode_of "$TDIR/script.sh")" "755" "patch_file: mode 0755 preserved"
assert_exec "$TDIR/script.sh" "patch_file: patched file is still executable"

# --- patch_file: a non-executable file is not widened ---
printf 'alpha\n' >"$TDIR/private.txt"
chmod 640 "$TDIR/private.txt"
"$DIR/tools/patch_file/run.sh" "$(jq -nc --arg p "$TDIR/private.txt" '{path:$p,old_string:"alpha",new_string:"beta"}')" >/dev/null
assert_eq "$(mode_of "$TDIR/private.txt")" "640" "patch_file: mode 0640 preserved (no widening)"

# --- write_file: overwriting a 0755 script keeps it executable ---
printf '#!/bin/bash\necho first\n' >"$TDIR/entrypoint.sh"
chmod 755 "$TDIR/entrypoint.sh"
OUT=$("$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/entrypoint.sh" '{path:$p,content:"#!/bin/bash\necho second\n"}')")
assert_eq "$?" "0" "write_file: exits 0 on overwrite"
assert_contains "$OUT" "Wrote" "write_file: output reports bytes written"
assert_contains "$(cat "$TDIR/entrypoint.sh")" "echo second" "write_file: content was overwritten"
assert_eq "$(mode_of "$TDIR/entrypoint.sh")" "755" "write_file: mode 0755 preserved on overwrite"
assert_exec "$TDIR/entrypoint.sh" "write_file: overwritten file is still executable"

# --- write_file: overwriting a 0600 file does not widen it ---
printf 'secret\n' >"$TDIR/secret.txt"
chmod 600 "$TDIR/secret.txt"
"$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/secret.txt" '{path:$p,content:"other\n"}')" >/dev/null
assert_eq "$(mode_of "$TDIR/secret.txt")" "600" "write_file: mode 0600 preserved on overwrite"

# --- write_file: a newly created file is not executable ---
"$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/fresh.txt" '{path:$p,content:"new\n"}')" >/dev/null
if [ -x "$TDIR/fresh.txt" ]; then
  echo -e "  ${RED}✗${NC} write_file: new file must not be executable (mode is $(mode_of "$TDIR/fresh.txt"))"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} write_file: new file is not executable"
fi

finish
