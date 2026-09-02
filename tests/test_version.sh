#!/bin/bash
# test_version.sh — tests for the standalone shai-version script
# Covers: shai-version — VERSION file, git describe fallback, dev fallback, always exit 0
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-version"

# Case 1: VERSION file exists — prints its contents
echo "v2026.01.01" >"$DIR/VERSION"
out=$("$DIR/shai-version" 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "v2026.01.01" "shai-version: reads VERSION file"

# Case 2: no VERSION file, git stubbed to fail — prints dev
make_stub_bin
printf '#!/bin/bash\nexit 1\n' >"$STUB/git"
chmod +x "$STUB/git"
out=$("$DIR/shai-version" 2>/dev/null)
assert_eq "$out" "dev" "shai-version: prints dev when no VERSION and git fails"

# Case 3: exit 0 even when every resolution source fails (git still stubbed to fail)
assert_exit 0 "shai-version: exits 0 on the dev fallback" -- "$DIR/shai-version"

# Case 4: does not require SHAI_API_KEY
echo "v1.0.0" >"$DIR/VERSION"
out=$(SHAI_API_KEY="" "$DIR/shai-version" 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "v1.0.0" "shai-version: works without SHAI_API_KEY"

# Case 5: empty VERSION file falls through to the dev fallback
make_stub_bin
printf '#!/bin/bash\nexit 1\n' >"$STUB/git"
chmod +x "$STUB/git"
printf '' >"$DIR/VERSION"
out=$("$DIR/shai-version" 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "dev" "shai-version: empty VERSION falls through to dev"

# Case 6: unreadable VERSION file falls through gracefully (exit 0)
if [ "$(id -u)" != "0" ]; then
  echo "v1.0.0" >"$DIR/VERSION"
  chmod 000 "$DIR/VERSION"
  rc=0
  out=$("$DIR/shai-version" 2>/dev/null) || rc=$?
  rm -f "$DIR/VERSION"
  assert_eq "$rc" "0" "shai-version: unreadable VERSION still exits 0"
  assert_eq "$out" "dev" "shai-version: unreadable VERSION falls through to dev"
fi

# Case 7: shai-repl rejects --version with a usage error (version querying lives in shai-version)
rc=0
err=$("$DIR/shai-repl" --version 2>&1) || rc=$?
assert_eq "$rc" "2" "shai-repl: --version exits 2 (unknown option)"
assert_contains "$err" "unknown option" "shai-repl: --version prints unknown-option error"

finish
