#!/bin/bash
# test_runs.sh — tests for shai-runs observability filter
# Covers: run listing, session scoping, status detection, --failed, --recent, --json, prefix matching
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNS="$DIR/shai-runs"

setup_runs() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs"
}

# Helper: populate a run directory with events
make_run() {
  local run_id="$1"
  shift
  mkdir -p "$SHAI_HOME/runs/$run_id"
  for event in "$@"; do
    printf '%s\n' "$event"
  done >"$SHAI_HOME/runs/$run_id/events.jsonl"
}

desc "empty state: no output"
setup_runs
OUT=$("$RUNS" 2>/dev/null)
assert_eq "$OUT" "" "empty dir no output"

desc "empty state: --json produces empty array"
setup_runs
OUT=$("$RUNS" --json)
assert_eq "$OUT" "[]" "empty --json"

desc "single complete run: correct metrics"
setup_runs
make_run "run_20260811T090000_aabb" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "run_20260811T090000_aabb" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":"hello","finish_reason":"stop"}' \
    "run_20260811T090000_aabb" "sess_test" "span_1" \
    '{"message_id":"msg_1","model":"m","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15},"latency_ms":100}')"
OUT=$("$RUNS" --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq -r '.run_id')" "run_20260811T090000_aabb" "run_id"
assert_eq "$(printf '%s' "$OUT" | jq '.spans')" "1" "span count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.status')" "complete" "status complete"
assert_eq "$(printf '%s' "$OUT" | jq '.tokens')" "15" "token total"

desc "error run: status is error"
setup_runs
make_run "run_20260811T091000_ccdd" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "run_20260811T091000_ccdd" "sess_test" "span_1")" \
  "$(fixture_event "error" "system" '{"text":"request failed"}' "run_20260811T091000_ccdd" "sess_test" "span_1")"
OUT=$("$RUNS" --json | jq -r '.[0].status')
assert_eq "$OUT" "error" "status error"

desc "incomplete run: tool_result as last event"
setup_runs
make_run "run_20260811T092000_eeff" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "run_20260811T092000_eeff" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"print_file","arguments":"{\"path\":\"x\"}"}}],"finish_reason":"tool_calls"}' \
    "run_20260811T092000_eeff" "sess_test" "span_1")" \
  "$(fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":"file contents","is_error":false}' \
    "run_20260811T092000_eeff" "sess_test" "span_2")"
OUT=$("$RUNS" --json | jq -r '.[0].status')
assert_eq "$OUT" "incomplete" "status incomplete"

desc "--failed: only error runs"
setup_runs
make_run "run_20260811T090000_ok01" \
  "$(fixture_event "message" "assistant" '{"content":"ok","finish_reason":"stop"}' \
    "run_20260811T090000_ok01" "sess_test" "span_1")"
make_run "run_20260811T091000_fail" \
  "$(fixture_event "error" "system" '{"text":"fail"}' "run_20260811T091000_fail" "sess_test" "span_1")"
OUT=$("$RUNS" --failed --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "failed filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T091000_fail" "failed filter id"

desc "--recent 1: only last run"
setup_runs
make_run "run_20260811T090000_aabb" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260811T090000_aabb" "sess_test" "span_1")"
make_run "run_20260811T100000_ccdd" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T100000_ccdd" "sess_test" "span_1")"
OUT=$("$RUNS" --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent 1 count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T100000_ccdd" "recent 1 id"

desc "--recent 0: no runs"
setup_runs
make_run "run_20260811T090000_aabb" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260811T090000_aabb" "sess_test" "span_1")"
OUT=$("$RUNS" --recent 0 --json)
assert_eq "$OUT" "[]" "recent 0 produces empty array"

desc "--session: groups by run_id from session log"
setup_runs
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q1"}' "run_a" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a1","finish_reason":"stop"}' "run_a" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"q2"}' "run_b" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a2","finish_reason":"stop"}' "run_b" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$RUNS" --session "$SID" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "session scope run count"

desc "--session prefix: resolves unambiguous prefix"
setup_runs
SID="sess_20260811T090000_aabb"
fixture_event "message" "user" '{"text":"hi"}' "run_a" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$RUNS" --session "sess_20260811" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "prefix match works"

desc "--session prefix: ambiguous produces error"
setup_runs
S1="sess_20260811T090000_aabb"
S2="sess_20260811T100000_ccdd"
fixture_event "message" "user" '{"text":"a"}' "run_a" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_b" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
assert_exit 1 "ambiguous prefix" -- "$RUNS" --session "sess_20260811"

desc "--session prefix: no match produces error"
setup_runs
SID="sess_20260811T090000_aabb"
fixture_event "message" "user" '{"text":"hi"}' "run_a" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
assert_exit 1 "no match prefix" -- "$RUNS" --session "sess_nope"

desc "tool count: counts tool_result events"
setup_runs
make_run "run_20260811T090000_tools" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "run_20260811T090000_tools" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"print_file","arguments":"{}"}}],"finish_reason":"tool_calls"}' \
    "run_20260811T090000_tools" "sess_test" "span_1")" \
  "$(fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":"x","is_error":false}' \
    "run_20260811T090000_tools" "sess_test" "span_2")" \
  "$(fixture_event "message" "assistant" '{"content":"done","finish_reason":"stop"}' \
    "run_20260811T090000_tools" "sess_test" "span_2" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"latency_ms":1}')"
OUT=$("$RUNS" --json | jq '.[0].tools')
assert_eq "$OUT" "1" "tool count"

desc "malformed run file: skipped with a warning, other runs unaffected"
setup_runs
make_run "run_20260811T090000_good1" \
  "$(fixture_event "message" "assistant" '{"content":"ok","finish_reason":"stop"}' \
    "run_20260811T090000_good1" "sess_test" "span_1")"
mkdir -p "$SHAI_HOME/runs/run_20260811T091000_bad01"
# Simulate a crash mid-append: a truncated, unparseable trailing line with no closing braces.
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/runs/run_20260811T091000_bad01/events.jsonl"
OUT=$("$RUNS" --json 2>/dev/null)
ERR=$("$RUNS" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed run file does not abort the run (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "malformed run excluded, good run still listed"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T090000_good1" "good run id still correct"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed run"
assert_contains "$ERR" "run_20260811T091000_bad01" "warning names the malformed run"

desc "malformed session file: warns, yields no runs (exit 0)"
setup_runs
SID="sess_20260811T093000_bad02"
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$RUNS" --session "$SID" --json 2>/dev/null)
ERR=$("$RUNS" --session "$SID" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed session file does not abort the run (exit 0)"
assert_eq "$OUT" "[]" "malformed session file yields no runs"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed session file"
assert_contains "$ERR" "$SID" "warning names the malformed session file"

desc "old unstamped event in session log: excluded, does not crash"
setup_runs
SID="sess_20260811T094000_mixed"
{
  printf '{"type":"message","source":"user","payload":{"text":"old, no meta"}}\n'
  fixture_event "message" "user" '{"text":"hi"}' "run_a" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"hi back","finish_reason":"stop"}' "run_a" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$RUNS" --session "$SID" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "unstamped event excluded from run listing"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_a" "remaining run still correct"

desc "human output: contains header and run id"
setup_runs
make_run "run_20260811T090000_aabb" \
  "$(fixture_event "message" "assistant" '{"content":"hi","finish_reason":"stop"}' \
    "run_20260811T090000_aabb" "sess_test" "span_1")"
OUT=$("$RUNS")
assert_contains "$OUT" "RUN" "header present"
assert_contains "$OUT" "run_20260811T090000_aabb" "run id in output"

desc "human output: zero tokens shows -- placeholder"
setup_runs
make_run "run_20260811T090000_notoks" \
  "$(fixture_event "message" "assistant" '{"content":"hi","finish_reason":"stop"}' \
    "run_20260811T090000_notoks" "sess_test" "span_1")"
OUT=$("$RUNS")
assert_contains "$OUT" "--" "human output shows -- for zero tokens"

desc "invalid args: exit 1"
assert_exit 1 "unknown flag" -- "$RUNS" --bogus

finish
