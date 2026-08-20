#!/bin/bash
# test_stats.sh — tests for shai-stats observability filter
# Covers: aggregate metrics, session scoping, date filtering, --json, empty state, missing api data, malformed file handling
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATS="$DIR/shai-stats"

setup_stats() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs"
}

desc "empty state: --json produces zeroed object"
setup_stats
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "0" "zero sessions"
assert_eq "$(printf '%s' "$OUT" | jq '.runs')" "0" "zero runs"

desc "single session: correct aggregates"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "system" '{"text":"sys"}' "run_1" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150},"latency_ms":1000}'
  fixture_event "message" "user" '{"text":"q2"}' "run_2" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a2","finish_reason":"stop"}' \
    "run_2" "$SID" "span_1" \
    '{"message_id":"m2","model":"m","usage":{"prompt_tokens":200,"completion_tokens":100,"total_tokens":300},"latency_ms":2000}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "1 session"
assert_eq "$(printf '%s' "$OUT" | jq '.runs')" "2" "2 runs"
assert_eq "$(printf '%s' "$OUT" | jq '.tokens.input')" "300" "input tokens"
assert_eq "$(printf '%s' "$OUT" | jq '.tokens.output')" "150" "output tokens"
assert_eq "$(printf '%s' "$OUT" | jq '.tokens.total')" "450" "total tokens"

desc "status breakdown: counts by status"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_ok" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_ok" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"q2"}' "run_err" "$SID" "span_1"
  fixture_event "error" "system" '{"text":"fail"}' "run_err" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.statuses.complete')" "1" "1 complete"
assert_eq "$(printf '%s' "$OUT" | jq '.statuses.error')" "1" "1 error"

desc "tool usage: counts by tool name"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"print_file","arguments":"{}"}},{"id":"tu_2","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}' \
    "run_1" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"q2"}' "run_2" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":null,"tool_calls":[{"id":"tu_3","type":"function","function":{"name":"print_file","arguments":"{}"}}],"finish_reason":"tool_calls"}' \
    "run_2" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json | jq '.tools')
assert_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.name=="print_file") | .count')" "2" "print_file count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[] | select(.name=="list_directory") | .count')" "1" "list_directory count"

desc "--session: scopes to single session"
setup_stats
S1="sess_20260810T090000_aabb"
S2="sess_20260811T090000_ccdd"
{
  fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$S1" "span_1"
} >"$SHAI_HOME/sessions/$S1.jsonl"
{
  fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1"
  fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' "run_2" "$S2" "span_1"
} >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$STATS" --session "$S1" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "scoped to 1"
assert_eq "$(printf '%s' "$OUT" | jq '.runs')" "1" "1 run in scoped session"

desc "--after: date filtering"
setup_stats
S1="sess_20260809T090000_aabb"
S2="sess_20260811T090000_ccdd"
fixture_event "message" "user" '{"text":"a"}' "run_1" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_2" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$STATS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "after filter"

desc "no api data: tokens are 0"
setup_stats
SID="sess_20260811T090000_aabb"
fixture_event "message" "user" '{"text":"hi"}' "run_1" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.tokens.total')" "0" "no api -> 0 tokens"

desc "malformed session file: skipped with a warning, other sessions unaffected"
setup_stats
GOOD="sess_20260811T090000_good1"
BAD="sess_20260811T091000_bad001"
fixture_event "message" "user" '{"text":"hi"}' "run_1" "$GOOD" "span_1" >"$SHAI_HOME/sessions/$GOOD.jsonl"
# Simulate a crash mid-append: a truncated, unparseable trailing line with no closing braces.
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/sessions/$BAD.jsonl"
OUT=$("$STATS" --json 2>/dev/null)
ERR=$("$STATS" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed file does not abort the run (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "malformed file excluded, good session still counted"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed file"
assert_contains "$ERR" "$BAD" "warning names the malformed file"

desc "human output: contains key sections"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"hi"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"yo","finish_reason":"stop"}' "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15},"latency_ms":100}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS")
assert_contains "$OUT" "Sessions:" "has sessions line"
assert_contains "$OUT" "Runs:" "has runs line"
assert_contains "$OUT" "Tokens:" "has tokens section"

desc "invalid args: exit 1"
assert_exit 1 "unknown flag" -- "$STATS" --bogus

finish
