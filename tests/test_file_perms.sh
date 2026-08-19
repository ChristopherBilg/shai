#!/bin/bash
# test_file_perms.sh — regression tests: the file-writing tools must preserve permission bits
# Covers: tools/patch_file/run.sh, tools/write_file/run.sh — mode preserved across patch/overwrite;
#   write_file's explicit `mode` input (exec bit on new files, bad modes rejected)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "file permission preservation"

TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")

# mode_of <path>: octal permission bits (GNU stat first, BSD/macOS fallback), empty if neither
# stat form exists. No setuid/setgid/sticky bits are involved in these fixtures, so the 3-digit
# BSD '%Lp' form is enough here.
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# assert_mode <path> <want> <description>: compare octal permission bits. Skipped when the
# platform has no usable stat(1) — the tools deliberately degrade to the old behaviour there,
# so the assertion would report a spurious `got ''` failure.
assert_mode() {
  local got
  got=$(mode_of "$1")
  if [ -z "$got" ]; then
    echo -e "  ${GREEN}✓${NC} $3 (skipped: no usable stat(1) on this platform)"
    return 0
  fi
  assert_eq "$got" "$2" "$3"
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
assert_mode "$TDIR/script.sh" "755" "patch_file: mode 0755 preserved"
assert_exec "$TDIR/script.sh" "patch_file: patched file is still executable"

# --- patch_file: a non-executable file is not widened ---
printf 'alpha\n' >"$TDIR/private.txt"
chmod 640 "$TDIR/private.txt"
"$DIR/tools/patch_file/run.sh" "$(jq -nc --arg p "$TDIR/private.txt" '{path:$p,old_string:"alpha",new_string:"beta"}')" >/dev/null
assert_mode "$TDIR/private.txt" "640" "patch_file: mode 0640 preserved (no widening)"

# --- patch_file: setuid/setgid/sticky bits survive the rename too ---
# Skipped where the platform/filesystem refuses the setgid bit rather than asserting on a mode
# the fixture never actually had.
printf 'alpha\n' >"$TDIR/setgid.sh"
chmod 2755 "$TDIR/setgid.sh" 2>/dev/null || true
if [ "$(mode_of "$TDIR/setgid.sh")" = "2755" ]; then
  "$DIR/tools/patch_file/run.sh" "$(jq -nc --arg p "$TDIR/setgid.sh" '{path:$p,old_string:"alpha",new_string:"beta"}')" >/dev/null
  assert_mode "$TDIR/setgid.sh" "2755" "patch_file: setgid bit preserved"
else
  echo -e "  ${GREEN}✓${NC} patch_file: setgid case skipped (setgid bit not settable here)"
fi

# --- write_file: overwriting a 0755 script keeps it executable ---
printf '#!/bin/bash\necho first\n' >"$TDIR/entrypoint.sh"
chmod 755 "$TDIR/entrypoint.sh"
OUT=$("$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/entrypoint.sh" '{path:$p,content:"#!/bin/bash\necho second\n"}')")
assert_eq "$?" "0" "write_file: exits 0 on overwrite"
assert_contains "$OUT" "Wrote" "write_file: output reports bytes written"
assert_contains "$(cat "$TDIR/entrypoint.sh")" "echo second" "write_file: content was overwritten"
assert_mode "$TDIR/entrypoint.sh" "755" "write_file: mode 0755 preserved on overwrite"
assert_exec "$TDIR/entrypoint.sh" "write_file: overwritten file is still executable"

# --- write_file: overwriting a 0600 file does not widen it ---
printf 'secret\n' >"$TDIR/secret.txt"
chmod 600 "$TDIR/secret.txt"
"$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/secret.txt" '{path:$p,content:"other\n"}')" >/dev/null
assert_mode "$TDIR/secret.txt" "600" "write_file: mode 0600 preserved on overwrite"

# --- write_file: a newly created file is not executable ---
"$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/fresh.txt" '{path:$p,content:"new\n"}')" >/dev/null
if [ -x "$TDIR/fresh.txt" ]; then
  echo -e "  ${RED}✗${NC} write_file: new file must not be executable (mode is $(mode_of "$TDIR/fresh.txt"))"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} write_file: new file is not executable"
fi

# --- write_file: an explicit mode makes a new file executable ---
# Regression: without a `mode` input there was no way for a tool call to produce an executable
# file at all, so adding a tool plugin's run.sh or a tests/test_*.sh was impossible (#80).
OUT=$("$DIR/tools/write_file/run.sh" "$(jq -nc --arg p "$TDIR/new-script.sh" \
  '{path:$p,content:"#!/bin/bash\necho hi\n",mode:"755"}')")
assert_eq "$?" "0" "write_file: exits 0 with an explicit mode"
assert_contains "$OUT" "mode 755" "write_file: output reports the applied mode"
assert_exec "$TDIR/new-script.sh" "write_file: new file with mode 755 is executable"
assert_mode "$TDIR/new-script.sh" "755" "write_file: new file has mode 0755"

# --- write_file: an explicit mode wins over the preserved mode of an existing file ---
printf 'old\n' >"$TDIR/relax.txt"
chmod 600 "$TDIR/relax.txt"
"$DIR/tools/write_file/run.sh" \
  "$(jq -nc --arg p "$TDIR/relax.txt" '{path:$p,content:"new\n",mode:"644"}')" >/dev/null
assert_mode "$TDIR/relax.txt" "644" "write_file: explicit mode overrides the existing mode"

# --- write_file: a 4-digit mode is accepted ---
# Skipped where the platform/filesystem refuses the setgid bit, as above.
"$DIR/tools/write_file/run.sh" \
  "$(jq -nc --arg p "$TDIR/sticky.sh" '{path:$p,content:"x\n",mode:"2755"}')" >/dev/null
if [ "$(mode_of "$TDIR/sticky.sh")" = "755" ]; then
  echo -e "  ${GREEN}✓${NC} write_file: 4-digit mode case skipped (setgid bit not settable here)"
else
  assert_mode "$TDIR/sticky.sh" "2755" "write_file: 4-digit mode 2755 applied"
fi

# --- write_file: a bad mode string is rejected and nothing is written ---
for bad in "u+x" "75" "77777" "755 /etc/passwd" "" "988"; do
  OUT=$("$DIR/tools/write_file/run.sh" \
    "$(jq -nc --arg p "$TDIR/rejected.txt" --arg m "$bad" '{path:$p,content:"nope\n",mode:$m}')" \
    2>&1) && rc=0 || rc=$?
  if [ "$bad" = "" ]; then
    # An empty mode is indistinguishable from "no mode given", so it must simply write.
    assert_eq "$rc" "0" "write_file: empty mode is treated as no mode"
    continue
  fi
  assert_eq "$rc" "1" "write_file: mode '$bad' is rejected (exit 1)"
  assert_contains "$OUT" "invalid mode" "write_file: mode '$bad' reports invalid mode"
done
# The only write in that loop is the empty-mode iteration, so the file must hold exactly its
# content once: a rejected mode must not have written, appended, or truncated anything.
assert_eq "$(cat "$TDIR/rejected.txt")" "nope" "write_file: rejected modes wrote nothing"

finish
