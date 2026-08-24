#!/bin/bash
# test_runs.sh — tests for shai-runs observability filter
# Covers: run listing, session scoping, status detection, --failed, --recent, --after/--before, --json, prefix matching
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

desc "--after: filters out runs before the date"
setup_runs
make_run "run_20260809T090000_old01" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260809T090000_old01" "sess_test" "span_1" "null" "2026-08-09T12:00:00Z")"
make_run "run_20260811T090000_new01" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T090000_new01" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T090000_new01" "after filter id"

desc "--before: filters out runs after the date"
setup_runs
make_run "run_20260809T090000_old01" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260809T090000_old01" "sess_test" "span_1" "null" "2026-08-09T12:00:00Z")"
make_run "run_20260811T090000_new01" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T090000_new01" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
OUT=$("$RUNS" --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "before filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260809T090000_old01" "before filter id"

desc "--after + --before: composes as a range"
setup_runs
make_run "run_20260809T090000_old01" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260809T090000_old01" "sess_test" "span_1" "null" "2026-08-09T12:00:00Z")"
make_run "run_20260811T090000_mid01" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T090000_mid01" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
make_run "run_20260813T090000_new01" \
  "$(fixture_event "message" "assistant" '{"content":"c","finish_reason":"stop"}' \
    "run_20260813T090000_new01" "sess_test" "span_1" "null" "2026-08-13T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --before 2026-08-12 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "range filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T090000_mid01" "range filter id"

desc "--failed + --after: composes"
setup_runs
make_run "run_20260809T090000_fail1" \
  "$(fixture_event "error" "system" '{"text":"old fail"}' \
    "run_20260809T090000_fail1" "sess_test" "span_1" "null" "2026-08-09T12:00:00Z")"
make_run "run_20260811T090000_fail2" \
  "$(fixture_event "error" "system" '{"text":"new fail"}' \
    "run_20260811T090000_fail2" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
make_run "run_20260811T100000_ok001" \
  "$(fixture_event "message" "assistant" '{"content":"ok","finish_reason":"stop"}' \
    "run_20260811T100000_ok001" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
OUT=$("$RUNS" --failed --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "failed+after count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T090000_fail2" "failed+after id"

desc "--session + --after: composes"
setup_runs
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q1"}' "run_a" "$SID" "span_1" "null" "2026-08-09T12:00:00Z"
  fixture_event "message" "assistant" '{"content":"a1","finish_reason":"stop"}' "run_a" "$SID" "span_1" "null" "2026-08-09T12:05:00Z"
  fixture_event "message" "user" '{"text":"q2"}' "run_b" "$SID" "span_1" "null" "2026-08-11T12:00:00Z"
  fixture_event "message" "assistant" '{"content":"a2","finish_reason":"stop"}' "run_b" "$SID" "span_1" "null" "2026-08-11T12:05:00Z"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$RUNS" --session "$SID" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "session+after count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_b" "session+after id"

desc "date filter: exact match is inclusive"
setup_runs
make_run "run_20260810T090000_edge1" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260810T090000_edge1" "sess_test" "span_1" "null" "2026-08-10T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after exact match included"
OUT=$("$RUNS" --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "before exact match included"

desc "--recent + --after: composes"
setup_runs
make_run "run_20260809T090000_old01" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260809T090000_old01" "sess_test" "span_1" "null" "2026-08-09T12:00:00Z")"
make_run "run_20260811T090000_mid01" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T090000_mid01" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
make_run "run_20260813T090000_new01" \
  "$(fixture_event "message" "assistant" '{"content":"c","finish_reason":"stop"}' \
    "run_20260813T090000_new01" "sess_test" "span_1" "null" "2026-08-13T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent+after count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260813T090000_new01" "recent+after id"

desc "date filter: undated run excluded when a bound is active"
setup_runs
# No usable meta.timestamp (fixture_event's `:-` default makes "" unusable, so write the raw event).
mkdir -p "$SHAI_HOME/runs/run_20260809T090000_nodate"
printf '{"type":"message","source":"assistant","payload":{"content":"a","finish_reason":"stop"},"version":"1.0","meta":{"run_id":"run_20260809T090000_nodate","session_id":"sess_test","span_id":"span_1","parent_span_id":null}}\n' \
  >"$SHAI_HOME/runs/run_20260809T090000_nodate/events.jsonl"
make_run "run_20260811T090000_dated1" \
  "$(fixture_event "message" "assistant" '{"content":"b","finish_reason":"stop"}' \
    "run_20260811T090000_dated1" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "undated run excluded when bound active"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].run_id')" "run_20260811T090000_dated1" "dated run kept"
OUT=$("$RUNS" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "undated run listed without bounds"

desc "--json: date is internal, never in output"
setup_runs
make_run "run_20260811T090000_json01" \
  "$(fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' \
    "run_20260811T090000_json01" "sess_test" "span_1" "null" "2026-08-11T12:00:00Z")"
OUT=$("$RUNS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq '.[0] | has("date")')" "false" "date absent from --json output"

desc "invalid args: exit 1"
assert_exit 1 "unknown flag" -- "$RUNS" --bogus
assert_exit 1 "--after bad date" -- "$RUNS" --after not-a-date
assert_exit 1 "--before bad date" -- "$RUNS" --before 2026/08/10

finish
