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

# --- FAIL case: pipeline failure (broken curl) ---
printf '#!/bin/bash\nexit 7\n' >"$STUB/curl"
chmod +x "$STUB/curl"

OUT=$("$DIR/shai-heartbeat" 2>&1)
RC=$?
assert_eq "$RC" "1" "heartbeat: exit 1 on pipeline failure"
assert_contains "$OUT" "FAIL" "heartbeat: prints FAIL on pipeline failure"

finish
