#!/bin/bash
# test_sessions.sh — tests for shai-sessions observability filter
# Covers: session listing, date filtering, --recent, --json, graceful degradation, argument validation
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SESSIONS="$DIR/shai-sessions"

# --- Fixtures ---
setup_sessions() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions"
}

# --- Tests ---
desc "empty state: no output"
setup_sessions
OUT=$("$SESSIONS" 2>/dev/null)
assert_eq "$OUT" "" "empty dir produces no output"

desc "empty state: --json produces empty array"
setup_sessions
OUT=$("$SESSIONS" --json)
assert_eq "$OUT" "[]" "empty dir --json"

desc "single session: correct metrics"
setup_sessions
SID="sess_20260810T140000_aabbccdd"
{
  fixture_event "message" "system" '{"text":"system prompt"}' "run_1" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"hello"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"hi","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" '{"message_id":"msg_1","model":"test-model","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150},"latency_ms":1000}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$SESSIONS" --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq -r '.session_id')" "$SID" "session_id"
assert_eq "$(printf '%s' "$OUT" | jq '.events')" "3" "event count"
assert_eq "$(printf '%s' "$OUT" | jq '.runs')" "1" "run count"
assert_eq "$(printf '%s' "$OUT" | jq '.tokens')" "150" "token total"

desc "multiple sessions: sorted by timestamp"
setup_sessions
S1="sess_20260810T140000_aabbccdd"
S2="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$SESSIONS" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "$S1" "first is earlier"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].session_id')" "$S2" "second is later"

desc "--recent 1: only last session"
setup_sessions
S1="sess_20260810T140000_aabbccdd"
S2="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$SESSIONS" --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent 1 count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "$S2" "recent 1 is latest"

desc "--recent 0: no sessions"
setup_sessions
S1="sess_20260810T140000_aabbccdd"
S2="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$SESSIONS" --recent 0 --json)
assert_eq "$OUT" "[]" "recent 0 produces empty array"

desc "--after: filters by date"
setup_sessions
S1="sess_20260809T140000_aabbccdd"
S2="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$SESSIONS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "$S2" "after filter id"

desc "--before: filters by date"
setup_sessions
S1="sess_20260809T140000_aabbccdd"
S2="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$SESSIONS" --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "before filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "$S1" "before filter id"

desc "no api data: tokens is 0 in json"
setup_sessions
SID="sess_20260810T140000_aabbccdd"
fixture_event "message" "user" '{"text":"hello"}' "run_1" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$SESSIONS" --json | jq '.[0].tokens')
assert_eq "$OUT" "0" "no api -> tokens 0"

desc "no meta: runs is 0 in json"
setup_sessions
SID="sess_20260810T140000_aabbccdd"
printf '{"type":"message","source":"user","payload":{"text":"old"}}\n' >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$SESSIONS" --json | jq '.[0].runs')
assert_eq "$OUT" "0" "no meta -> runs 0"

desc "malformed session file: skipped with a warning, other sessions unaffected"
setup_sessions
GOOD="sess_20260810T140000_aabbccdd"
BAD="sess_20260811T090000_eeff0011"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$GOOD" "span_1" >"$SHAI_HOME/sessions/$GOOD.jsonl"
# Simulate a crash mid-append: a truncated, unparseable trailing line with no closing braces.
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/sessions/$BAD.jsonl"
OUT=$("$SESSIONS" --json 2>/dev/null)
ERR=$("$SESSIONS" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed file does not abort the run (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "malformed file excluded, good session still listed"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "$GOOD" "good session id still correct"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed file"
assert_contains "$ERR" "$BAD" "warning names the malformed file"

desc "human output: contains session id and header"
setup_sessions
SID="sess_20260810T140000_aabbccdd"
fixture_event "message" "user" '{"text":"hello"}' "run_1" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$SESSIONS")
assert_contains "$OUT" "SESSION" "header present"
assert_contains "$OUT" "$SID" "session id in output"

desc "human output: no api/meta shows -- placeholders"
setup_sessions
SID="sess_20260810T140000_aabbccdd"
printf '{"type":"message","source":"user","payload":{"text":"old"}}\n' >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$SESSIONS")
assert_contains "$OUT" "--" "human output shows -- for missing runs/tokens"

desc "invalid args: each error branch asserts its distinct message"
assert_fails 1 "error: --recent requires a value" "--recent missing value" -- "$SESSIONS" --recent
assert_fails 1 "error: --recent value must be an integer" "--recent non-integer value" -- "$SESSIONS" --recent abc
assert_fails 1 "error: --after requires a date (YYYY-MM-DD)" "--after missing value" -- "$SESSIONS" --after
assert_fails 1 "error: --after date must be YYYY-MM-DD" "--after bad date" -- "$SESSIONS" --after not-a-date
assert_fails 1 "error: --before requires a date (YYYY-MM-DD)" "--before missing value" -- "$SESSIONS" --before
assert_fails 1 "error: --before date must be YYYY-MM-DD" "--before bad date" -- "$SESSIONS" --before 2026/08/10
assert_fails 1 "error: unknown option: --bogus" "unknown flag" -- "$SESSIONS" --bogus

finish
