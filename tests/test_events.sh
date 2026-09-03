#!/bin/bash
# test_events.sh — tests for the shai-events event-level query tool
# Covers: event listing, --type/--source/--tool filters, AND composition, --session/--run
#         prefix matching, --after/--before date windows (file-level short-circuit),
#         --recent, --json, malformed-line tolerance, tool_call summary rendering,
#         error/array summaries, undated-event handling, truncation, ordering,
#         and argument validation
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENTS="$DIR/shai-events"

setup_events() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions"
}

# Helper: write a mixed-type session (user, assistant+tool_call, tool_result, error).
make_mixed_session() {
  local sid="$1" run="${2:-run_a}"
  {
    fixture_event "message" "user" '{"text":"hello"}' "$run" "$sid" "span_1"
    fixture_event "message" "assistant" '{"content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"print_file","arguments":"{\"path\":\"x\"}"}}],"finish_reason":"tool_calls"}' \
      "$run" "$sid" "span_1"
    fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":"file contents","is_error":false}' \
      "$run" "$sid" "span_2"
    fixture_event "error" "system" '{"text":"request failed"}' "$run" "$sid" "span_2"
  } >"$SHAI_HOME/sessions/$sid.jsonl"
}

desc "empty state: no output, exit 0"
setup_events
OUT=$("$EVENTS" 2>/dev/null)
assert_eq "$OUT" "" "empty dir produces no output"
assert_row_count "$OUT" 0 "empty dir produces 0 rows"

desc "empty state: --json produces empty array"
setup_events
OUT=$("$EVENTS" --json)
assert_eq "$OUT" "[]" "empty dir --json"

desc "single session: filter by --type"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --type message --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "type message count"
OUT=$("$EVENTS" --type tool_result --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "type tool_result count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.tool_call_id')" "tu_1" "tool_result id"
OUT=$("$EVENTS" --type error --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "type error count"

desc "single session: filter by --source"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
for pair in "user:1" "assistant:1" "tool:1" "system:1"; do
  src="${pair%%:*}"
  want="${pair##*:}"
  OUT=$("$EVENTS" --source "$src" --json)
  assert_eq "$(printf '%s' "$OUT" | jq 'length')" "$want" "source $src count"
done

desc "--tool: matches assistant tool_calls, not tool_results"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --tool print_file --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "tool filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].type')" "message" "tool match is a message"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "assistant" "tool match is assistant"

desc "--tool: no match for a tool that only appears as tool_result"
setup_events
SID="sess_20260811T090000_aabb"
fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":"did print_file","is_error":false}' \
  "run_a" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS" --tool print_file --json)
assert_eq "$OUT" "[]" "tool_result cannot match --tool"

desc "filter combination: --type + --source intersects"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --type message --source assistant --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "intersection count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].source')" "assistant" "intersection source"
OUT=$("$EVENTS" --type error --source user --json)
assert_eq "$OUT" "[]" "empty intersection"

desc "filter combination: --tool + --source composes"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --tool print_file --source assistant --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "tool+source count"
OUT=$("$EVENTS" --tool print_file --source user --json)
assert_eq "$OUT" "[]" "tool+wrong source is empty"

desc "--session: full id scopes to one file"
setup_events
S1="sess_20260811T090000_aabb"
S2="sess_20260811T100000_ccdd"
fixture_event "message" "user" '{"text":"a"}' "run_a" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_b" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --session "$S1" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "session scope count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "a" "session scope content"

desc "--session: prefix resolves; ambiguous exits 1"
setup_events
S1="sess_20260811T090000_aabb"
S2="sess_20260811T100000_ccdd"
fixture_event "message" "user" '{"text":"a"}' "run_a" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_b" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --session "sess_20260811T0900" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "unambiguous prefix resolves"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].meta.session_id')" "$S1" "resolved session id"
assert_fails 1 "error: ambiguous prefix \"sess_20260811\"" "ambiguous prefix" -- "$EVENTS" --session "sess_20260811"
assert_fails 1 "error: no match for \"sess_nope\"" "no match prefix" -- "$EVENTS" --session "sess_nope"

desc "--run: filters events by meta.run_id prefix"
setup_events
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q1"}' "run_aaa" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a1","finish_reason":"stop"}' "run_aaa" "$SID" "span_1"
  fixture_event "message" "user" '{"text":"q2"}' "run_bbb" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS" --run run_aaa --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "run filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].meta.run_id')" "run_aaa" "run filter id"
OUT=$("$EVENTS" --run run_a --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "run prefix match count"
OUT=$("$EVENTS" --run run_b --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "run b count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "q2" "run b event"

desc "--session + --run: composes"
setup_events
S1="sess_20260811T090000_aabb"
S2="sess_20260811T100000_ccdd"
fixture_event "message" "user" '{"text":"a"}' "run_aaa" "$S1" "span_1" >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_aaa" "$S2" "span_1" >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --session "$S2" --run run_aaa --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "session+run count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "b" "session+run content"

desc "--after / --before: date window, inclusive boundaries"
setup_events
S1="sess_20260809T090000_aabb"
S2="sess_20260811T090000_ccdd"
fixture_event "message" "user" '{"text":"old"}' "run_a" "$S1" "span_1" "null" "2026-08-09T12:00:00Z" \
  >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"new"}' "run_b" "$S2" "span_1" "null" "2026-08-11T12:00:00Z" \
  >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "new" "after filter event"
OUT=$("$EVENTS" --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "before filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "old" "before filter event"
OUT=$("$EVENTS" --after 2026-08-09 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "after exact boundary is inclusive"
OUT=$("$EVENTS" --before 2026-08-11 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "before exact boundary is inclusive"
OUT=$("$EVENTS" --after 2026-08-10 --before 2026-08-12 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "range filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "new" "range filter event"
OUT=$("$EVENTS" --after 2026-08-12 --json)
assert_eq "$OUT" "[]" "range with no matches is empty"

desc "date filter: out-of-window files are never opened"
setup_events
GOOD="sess_20260811T090000_aabb"
BAD="sess_20260801T090000_ccdd"
fixture_event "message" "user" '{"text":"in window"}' "run_a" "$GOOD" "span_1" "null" "2026-08-11T12:00:00Z" \
  >"$SHAI_HOME/sessions/$GOOD.jsonl"
# Malformed on purpose: with the date window active this file must be skipped
# before parsing, so it can produce no warning.
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/sessions/$BAD.jsonl"
ERR=$("$EVENTS" --after 2026-08-10 2>&1 >/dev/null)
assert_eq "$?" "0" "out-of-window malformed file does not abort (exit 0)"
if [[ "$ERR" == *"$BAD"* ]]; then
  echo -e "  ${RED}✗${NC} out-of-window malformed file is never opened (no warning)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} out-of-window malformed file is never opened (no warning)"
fi
# Positive control: without the date bound the same file IS opened and warns.
ERR=$("$EVENTS" 2>&1 >/dev/null)
assert_eq "$?" "0" "unfiltered scan still exits 0"
assert_contains "$ERR" "$BAD" "unfiltered scan does open the file (warning present)"

desc "--session + date window: out-of-window resolved file is skipped (AND composition)"
setup_events
S1="sess_20260809T090000_aabb"
# The event's own timestamp is inside the window, but the session filename date
# is not: --session + --after compose as AND, so the resolved file is dropped
# wholesale before any JSONL is parsed (documented interpretation note).
fixture_event "message" "user" '{"text":"late event in old file"}' "run_a" "$S1" "span_1" "null" "2026-08-11T12:00:00Z" \
  >"$SHAI_HOME/sessions/$S1.jsonl"
OUT=$("$EVENTS" --session "$S1" --after 2026-08-10 --json)
assert_eq "$OUT" "[]" "out-of-window resolved session file is skipped"
OUT=$("$EVENTS" --session "$S1" --after 2026-08-10)
assert_eq "$OUT" "" "human mode also empty for skipped file"

desc "malformed lines: warning on stderr, valid lines still returned"
setup_events
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"one"}' "run_a" "$SID" "span_1"
  printf '{"type":"message","source":"user","payload":{"text":"trunc\n'
  fixture_event "message" "user" '{"text":"two"}' "run_b" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS" --json 2>/dev/null)
ERR=$("$EVENTS" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed line does not abort (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "valid lines still returned"
assert_contains "$ERR" "warning" "warning printed to stderr"
assert_contains "$ERR" "parse error" "warning says parse error"
assert_contains "$ERR" "$SID" "warning names the session file"

desc "malformed lines: filtered events in a malformed file still return"
setup_events
SID="sess_20260811T090000_aabb"
{
  printf '{"type":"message","source":"user","payload":{"text":"trunc\n'
  fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":"ok","is_error":false}' \
    "run_a" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS" --type tool_result --json 2>/dev/null)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "filtered event beside a malformed line"

desc "--recent N: last N after sort and filters"
setup_events
S1="sess_20260809T090000_aabb"
S2="sess_20260811T090000_ccdd"
{
  fixture_event "message" "user" '{"text":"e1"}' "run_a" "$S1" "span_1" "null" "2026-08-09T12:00:00Z"
  fixture_event "message" "user" '{"text":"e2"}' "run_a" "$S1" "span_1" "null" "2026-08-09T12:05:00Z"
} >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"e3"}' "run_b" "$S2" "span_1" "null" "2026-08-11T12:00:00Z" \
  >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent 1 count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "e3" "recent 1 is latest"
OUT=$("$EVENTS" --type message --recent 2 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "recent after filter count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "e2" "recent 2 first"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].payload.text')" "e3" "recent 2 second"

desc "--recent 0: no events"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --recent 0 --json)
assert_eq "$OUT" "[]" "recent 0 produces empty array"
OUT=$("$EVENTS" --recent 0)
assert_eq "$OUT" "" "recent 0 human output is empty"

desc "ordering: chronological across sessions, stable within a file"
setup_events
S1="sess_20260809T090000_aabb"
S2="sess_20260811T090000_ccdd"
{
  fixture_event "message" "user" '{"text":"first"}' "run_a" "$S1" "span_1" "null" "2026-08-09T12:00:00Z"
  fixture_event "message" "user" '{"text":"second"}' "run_a" "$S1" "span_1" "null" "2026-08-09T12:00:00Z"
} >"$SHAI_HOME/sessions/$S1.jsonl"
fixture_event "message" "user" '{"text":"third"}' "run_b" "$S2" "span_1" "null" "2026-08-11T12:00:00Z" \
  >"$SHAI_HOME/sessions/$S2.jsonl"
OUT=$("$EVENTS" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text')" "first" "earlier session first"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].payload.text')" "second" "same-timestamp events keep file order"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[2].payload.text')" "third" "later session last"

desc "--json: full unmodified event objects"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "4" "array of all events"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].version')" "1.0" "version field intact"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].meta.run_id')" "run_a" "meta intact"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].payload.tool_calls[0].function.name')" "print_file" \
  "payload intact"

desc "human output: header, tool_calls as name(...), truncation"
setup_events
SID="sess_20260811T090000_aabb"
LONG="$(printf 'x%.0s' {1..200})TAILMARKER"
{
  fixture_event "message" "user" "{\"text\":\"$LONG\"}" "run_a" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"print_file","arguments":"{}"}}],"finish_reason":"tool_calls"}' \
    "run_a" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS")
assert_contains "$OUT" "TIMESTAMP" "TIMESTAMP header present"
assert_contains "$OUT" "TYPE" "TYPE header present"
assert_contains "$OUT" "SOURCE" "SOURCE header present"
assert_contains "$OUT" "SUMMARY" "SUMMARY header present"
assert_contains "$OUT" "print_file(" "tool call rendered as name(...)"
assert_row_count "$OUT" 2 "one data row per event"
if [[ "$OUT" == *"TAILMARKER"* ]]; then
  echo -e "  ${RED}✗${NC} long content is truncated (~80 chars)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} long content is truncated (~80 chars)"
fi
# JSON mode is the escape hatch: no truncation there.
OUT=$("$EVENTS" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].payload.text | length')" "210" "json output not truncated"

desc "human output: error event summary uses payload.text"
setup_events
SID="sess_20260811T090000_aabb"
fixture_event "error" "system" '{"text":"boom"}' "run_a" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS")
assert_contains "$OUT" "boom" "error summary shows payload.text"

desc "human output: array tool_result content is joined"
setup_events
SID="sess_20260811T090000_aabb"
fixture_event "tool_result" "tool" '{"tool_call_id":"tu_1","content":[{"text":"alpha"},{"text":"beta"}],"is_error":false}' \
  "run_a" "$SID" "span_1" >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS")
assert_contains "$OUT" "alpha beta" "array content joined with spaces"

desc "human output: missing meta.timestamp renders as --, excluded only when a date bound is active"
setup_events
SID="sess_20260811T090000_aabb"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"no ts"},"version":"1.0","meta":{"run_id":"run_a","session_id":"'"$SID"'","span_id":"span_1","parent_span_id":null}}' \
  >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$EVENTS")
assert_contains "$OUT" "no ts" "undated event listed without date flags"
ts_col=$(printf '%s\n' "$OUT" | awk 'NR==2 {print $1}')
assert_eq "$ts_col" "--" "missing timestamp renders as --"
OUT=$("$EVENTS" --after 2026-08-01 --json)
assert_eq "$OUT" "[]" "undated event excluded when a date bound is active"

desc "human output: empty match prints nothing"
setup_events
SID="sess_20260811T090000_aabb"
make_mixed_session "$SID"
OUT=$("$EVENTS" --type error --source user)
assert_eq "$OUT" "" "no matches -> no output"
assert_row_count "$OUT" 0 "no matches -> 0 rows"

desc "invalid args: exit 1"
assert_fails 1 "error: unknown option: --bogus" "unknown flag" -- "$EVENTS" --bogus
assert_fails 1 "error: --after date must be YYYY-MM-DD" "--after bad date" -- "$EVENTS" --after not-a-date
assert_fails 1 "error: --before date must be YYYY-MM-DD" "--before bad date" -- "$EVENTS" --before 2026/08/10
assert_fails 1 "error: --recent value must be an integer" "--recent not an integer" -- "$EVENTS" --recent nope
assert_fails 1 "error: --type requires a value" "--type missing value" -- "$EVENTS" --type
assert_fails 1 "error: --source requires a value" "--source missing value" -- "$EVENTS" --source
assert_fails 1 "error: --tool requires a value" "--tool missing value" -- "$EVENTS" --tool
assert_fails 1 "error: --session requires an ID or prefix" "--session missing value" -- "$EVENTS" --session
assert_fails 1 "error: --run requires an ID or prefix" "--run missing value" -- "$EVENTS" --run
assert_fails 1 "error: --recent requires a value" "--recent missing value" -- "$EVENTS" --recent

finish
