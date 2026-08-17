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

# Case 4: does not require ANTHROPIC_API_KEY
echo "v1.0.0" >"$DIR/VERSION"
out=$(ANTHROPIC_API_KEY="" "$DIR/shai-version" 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "v1.0.0" "shai-version: works without ANTHROPIC_API_KEY"

# Case 5: shai-repl no longer answers --version (version querying lives in shai-version)
REPL_HOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$REPL_HOME")
echo "v1.0.0" >"$DIR/VERSION"
out=$(SHAI_HOME="$REPL_HOME" SHAI_SESSION_ID=test "$DIR/shai-repl" --version </dev/null 2>/dev/null || true)
rm -f "$DIR/VERSION"
assert_eq "$(printf '%s' "$out" | grep -c 'v1\.0\.0' || true)" "0" \
  "shai-repl: --version no longer prints the version"

finish
