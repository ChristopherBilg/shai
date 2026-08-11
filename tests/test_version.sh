#!/bin/bash
# test_version.sh — tests for shai-repl --version flag
# Covers: shai-repl --version — VERSION file, git describe fallback, dev fallback
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai --version"

# Case 1: VERSION file exists — prints its contents
echo "v2026.01.01" >"$DIR/VERSION"
out=$("$DIR/shai-repl" --version 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "v2026.01.01" "--version: reads VERSION file"

# Case 2: no VERSION file, git stubbed to fail — prints dev
make_stub_bin
printf '#!/bin/bash\nexit 1\n' >"$STUB/git"
chmod +x "$STUB/git"
out=$("$DIR/shai-repl" --version 2>/dev/null)
assert_eq "$out" "dev" "--version: prints dev when no VERSION and git fails"

# Case 3: --version does not require ANTHROPIC_API_KEY
echo "v1.0.0" >"$DIR/VERSION"
out=$(ANTHROPIC_API_KEY="" "$DIR/shai-repl" --version 2>/dev/null)
rm -f "$DIR/VERSION"
assert_eq "$out" "v1.0.0" "--version: works without ANTHROPIC_API_KEY"

finish
