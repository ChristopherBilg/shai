#!/bin/bash
# test_workflow.sh — unit tests for shai-workflow
# Covers: shai-workflow — list, run, describe, path-traversal guard, missing workflow, usage error
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-workflow"

# --- list: shows workflows with purpose lines ---
OUT=$("$DIR/shai-workflow" list 2>&1)
RC=$?
assert_eq "$RC" "0" "list: exit 0"
assert_contains "$OUT" "heartbeat" "list: includes heartbeat workflow"

# --- describe: prints doc header ---
OUT=$("$DIR/shai-workflow" describe heartbeat 2>&1)
RC=$?
assert_eq "$RC" "0" "describe: exit 0"
assert_contains "$OUT" "Usage:" "describe: includes Usage line"
assert_contains "$OUT" "Exit:" "describe: includes Exit line"

# --- run: executes a workflow, passes through exit code ---
# heartbeat needs an API key + network, so use a fixture instead. shai-workflow resolves
# WF_DIR relative to its own $DIR (via ${BASH_SOURCE[0]}), so — mirroring the same trick
# tests/test_prompt.sh uses for shai-prompt's PROMPTS_DIR — copy shai-workflow itself into
# the fixture dir alongside a fixture workflows/ directory, so $DIR resolves to $FIX.
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/workflows" "$FIX/lib"
cp "$DIR/lib/workflow.sh" "$FIX/lib/"
cp "$DIR/shai-workflow" "$FIX/shai-workflow"
chmod +x "$FIX/shai-workflow"

cat >"$FIX/workflows/echo-test.sh" <<'FIXTURE'
#!/bin/bash
# echo-test — test fixture that prints its args
# Usage: echo-test.sh [args]
# Reads: nothing
# Writes: args to stdout
# Exit: 0
set -euo pipefail
printf 'ARGS:%s\n' "$*"
FIXTURE
chmod +x "$FIX/workflows/echo-test.sh"

cat >"$FIX/workflows/exit-code-test.sh" <<'FIXTURE'
#!/bin/bash
# exit-code-test — test fixture that always exits 7
# Usage: exit-code-test.sh
# Reads: nothing
# Writes: nothing
# Exit: 7 (always, to exercise exit-code passthrough)
set -euo pipefail
exit 7
FIXTURE
chmod +x "$FIX/workflows/exit-code-test.sh"

OUT=$("$FIX/shai-workflow" run echo-test hello world 2>&1)
RC=$?
assert_eq "$RC" "0" "run: executes fixture workflow, exit 0"
assert_contains "$OUT" "ARGS:hello world" "run: passes args through to the workflow"

OUT=$("$FIX/shai-workflow" run exit-code-test 2>&1)
RC=$?
assert_eq "$RC" "7" "run: passes through non-zero exit code"

# --- path-traversal guard ---
OUT=$("$DIR/shai-workflow" run "../etc/passwd" 2>&1) || RC=$?
assert_eq "${RC:-0}" "1" "run: path traversal rejected (exit 1)"
assert_contains "$OUT" "must not contain" "run: path traversal error message"

OUT=$("$DIR/shai-workflow" run "foo/bar" 2>&1) || RC=$?
assert_eq "${RC:-0}" "1" "run: slash in name rejected"

# --- missing workflow ---
OUT=$("$DIR/shai-workflow" run nonexistent 2>&1) || RC=$?
assert_eq "${RC:-0}" "1" "run: missing workflow exits 1"
assert_contains "$OUT" "not found" "run: missing workflow error message"

# --- unknown subcommand ---
OUT=$("$DIR/shai-workflow" frobnicate 2>&1) || RC=$?
assert_eq "${RC:-0}" "2" "usage: unknown subcommand exits 2"

# --- no subcommand ---
OUT=$("$DIR/shai-workflow" 2>&1) || RC=$?
assert_eq "${RC:-0}" "2" "usage: no subcommand exits 2"

finish
