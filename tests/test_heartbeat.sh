#!/bin/bash
# test_heartbeat.sh — unit tests for shai-heartbeat
# Covers: shai-heartbeat — pipeline exercise, pass/fail reporting, no state left behind
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-heartbeat"

make_stub_bin

# --- PASS case: valid assistant response ---
printf '{"type":"message","content":[{"type":"text","text":"OK"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

OUT=$("$DIR/shai-heartbeat" 2>&1)
RC=$?
assert_eq "$RC" "0" "heartbeat: exit 0 on valid assistant response"
assert_contains "$OUT" "PASS" "heartbeat: prints PASS"
assert_contains "$OUT" "shai-heartbeat" "heartbeat: labels output"

# verify no session log was created
SESSION_COUNT=$(find "$TMP" -name '*.jsonl' 2>/dev/null | wc -l)
assert_eq "$SESSION_COUNT" "0" "heartbeat: no session log left behind (pass case)"

# --- FAIL case: error event from API ---
printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

OUT=$("$DIR/shai-heartbeat" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 on error response"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL on error"

SESSION_COUNT=$(find "$TMP" -name '*.jsonl' 2>/dev/null | wc -l)
assert_eq "$SESSION_COUNT" "0" "heartbeat: no session log left behind (fail case)"

# --- FAIL case: curl hard-failure (still caught and reported by shai-eval itself) ---
printf '#!/bin/bash\ncat > /dev/null\nexit 7\n' >"$STUB/curl"
chmod +x "$STUB/curl"

OUT=$("$DIR/shai-heartbeat" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 on curl hard-failure"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL on curl hard-failure"

# --- FAIL case: the pipeline itself fails (missing dependency) ---
# shai-eval treats curl failures as a loop-safe error *event* and still exits 0, so the case
# above never actually exercises shai-heartbeat's own `|| { ...; exit 1; }` catch. To trigger
# that catch for real, run a copy of shai-heartbeat from a directory where a sibling script is
# missing: DIR resolves via `dirname "${BASH_SOURCE[0]}"`, so "$DIR/shai-read" then points at a
# nonexistent file, bash reports "command not found" (127), and pipefail carries that non-zero
# status out of the whole `shai-read | shai-context | shai-eval` pipe.
PIPEDIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$PIPEDIR")
cp "$DIR/shai-heartbeat" "$DIR/shai-context" "$DIR/shai-eval" "$PIPEDIR/"
chmod +x "$PIPEDIR"/shai-*
# shai-read is deliberately not copied here.

OUT=$("$PIPEDIR/shai-heartbeat" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 when a pipeline dependency is missing"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL when a pipeline dependency is missing"
assert_contains "$OUT" "pipeline error" "heartbeat: FAIL message names the pipeline-error catch"

SESSION_COUNT=$(find "$TMP" -name '*.jsonl' 2>/dev/null | wc -l)
assert_eq "$SESSION_COUNT" "0" "heartbeat: no session log left behind (missing-dependency case)"

finish
