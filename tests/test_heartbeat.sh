#!/bin/bash
# test_heartbeat.sh — unit tests for workflows/heartbeat/run.sh
# Covers: workflows/heartbeat/run.sh — pipeline exercise, pass/fail reporting
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/heartbeat/run.sh"

make_stub_bin

# --- PASS case: valid assistant response ---
printf '{"type":"message","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

OUT=$("$DIR/workflows/heartbeat/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "heartbeat: exit 0 on valid assistant response"
assert_contains "$OUT" "PASS" "heartbeat: prints PASS"
assert_contains "$OUT" "heartbeat" "heartbeat: labels output"

# --- FAIL case: error event from API ---
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

OUT=$("$DIR/workflows/heartbeat/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 on error response"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL on error"

# --- FAIL case: curl hard-failure (still caught and reported by shai-eval itself) ---
printf '#!/bin/bash\ncat > /dev/null\nexit 7\n' >"$STUB/curl"
chmod +x "$STUB/curl"

OUT=$("$DIR/workflows/heartbeat/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 on curl hard-failure"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL on curl hard-failure"

# --- FAIL case: the pipeline itself fails (missing dependency) ---
# workflows/heartbeat/run.sh sources lib/workflow.sh via "$(dirname "$0")/../../lib/workflow.sh", and
# wf_init/wf_llm shell out to shai-prompt, shai-read, shai-context, shai-eval, shai-stamp, and
# shai-loop. Mirror that layout in a scratch dir but leave shai-loop out: wf_init still succeeds
# (it only needs shai-prompt/shai-read/shai-stamp plus prompts/system.txt), but wf_llm's
# "$DIR/shai-loop" then resolves to a nonexistent path, bash reports "No such file or directory"
# (127), and pipefail carries that non-zero status out of wf_llm — exactly the case
# heartbeat.sh's `|| { ...; exit 1; }` catch exists for.
PIPEDIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$PIPEDIR")
mkdir -p "$PIPEDIR/lib" "$PIPEDIR/workflows/heartbeat" "$PIPEDIR/prompts"
cp "$DIR/lib/workflow.sh" "$PIPEDIR/lib/workflow.sh"
cp "$DIR/workflows/heartbeat/run.sh" "$PIPEDIR/workflows/heartbeat/run.sh"
cp "$DIR/prompts/system.txt" "$PIPEDIR/prompts/system.txt"
cp "$DIR/shai-prompt" "$DIR/shai-read" "$DIR/shai-context" "$DIR/shai-eval" "$DIR/shai-stamp" "$PIPEDIR/"
chmod +x "$PIPEDIR/workflows/heartbeat/run.sh" "$PIPEDIR"/shai-*
# shai-loop is deliberately not copied here.

OUT=$("$PIPEDIR/workflows/heartbeat/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 when a pipeline dependency is missing"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL when a pipeline dependency is missing"
assert_contains "$OUT" "pipeline error" "heartbeat: FAIL message names the pipeline-error catch"

finish
