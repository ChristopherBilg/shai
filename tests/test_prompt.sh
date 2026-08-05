#!/bin/bash
# test_prompt.sh — tests the shai-prompt prompt loader
# Covers: shai-prompt — happy path, bad usage, missing/empty file
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "prompt"

FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/prompts"
printf 'You are a helpful assistant.\n' > "$FIX/prompts/system.txt"
printf '' > "$FIX/prompts/empty.txt"

cp "$DIR/shai-prompt" "$FIX/shai-prompt"
chmod +x "$FIX/shai-prompt"

run_prompt() {
  OUT=$("$FIX/shai-prompt" "$@" 2>&1)
  RC=$?
}

# --- happy path ---
run_prompt system
assert_eq "$RC" "0" "valid name exits 0"
assert_contains "$OUT" "You are a helpful assistant." "valid name prints file contents"

# --- bad usage (exit 2) ---
run_prompt
assert_eq "$RC" "2" "missing NAME exits 2"

run_prompt "foo/bar"
assert_eq "$RC" "2" "slash in NAME exits 2"

run_prompt "../etc"
assert_eq "$RC" "2" "dotdot in NAME exits 2"

# --- missing / empty file (exit 3) ---
run_prompt "nonexistent"
assert_eq "$RC" "3" "nonexistent prompt exits 3"

run_prompt "empty"
assert_eq "$RC" "3" "empty prompt exits 3"

finish
