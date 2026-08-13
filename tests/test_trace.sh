#!/bin/bash
# test_trace.sh — tests for shai-trace observability filter
# Covers: span chain rendering, run dir and session fallback, --request, --response, --verbose, --json, prefix matching
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRACE="$DIR/shai-trace"

setup_trace() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs"
}

make_run_with_dumps() {
  local run_id="$1"
  mkdir -p "$SHAI_HOME/runs/$run_id"
  shift
  for event in "$@"; do printf '%s\n' "$event"; done >"$SHAI_HOME/runs/$run_id/events.jsonl"
  printf '{"model":"claude-opus-4-8","messages":[]}' >"$SHAI_HOME/runs/$run_id/span_1-request.json"
  printf '{"message_id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5},"latency_ms":100}' \
    >"$SHAI_HOME/runs/$run_id/span_1-response.json"
}

desc "single span run: shows user input and assistant output"
setup_trace
RID="run_20260811T090000_aabb"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hello"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"text","text":"hi there"}],"stop_reason":"end_turn"}' \
    "$RID" "sess_test" "span_1" \
    '{"message_id":"msg_1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5},"latency_ms":100}')"
OUT=$("$TRACE" "$RID")
assert_contains "$OUT" "span_1" "span id shown"
assert_contains "$OUT" "hello" "user input shown"
assert_contains "$OUT" "hi there" "assistant output shown"
assert_contains "$OUT" "10" "input tokens shown"

desc "multi-span run: shows tool call chain"
setup_trace
RID="run_20260811T090000_multi"
# NOTE (deviation from the brief): the brief's fixture tagged the tool_result with span_2 (the
# *following* span), but shai-loop actually stamps a tool_result with the *same* span_id as the
# assistant tool_use message that requested it -- the span only advances afterward, in the next
# iteration of the eval/dispatch loop (see shai-loop's advance_span placement). CLAUDE.md's event
# schema table itself says SHAI_SPAN_ID covers "one eval iteration ... plus the tool results that
# eval requested". Fixed here to span_1 so this fixture matches a real span chain.
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"list files"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"tool_use","id":"tu_1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}' \
    "$RID" "sess_test" "span_1" \
    '{"message_id":"msg_1","model":"m","usage":{"input_tokens":20,"output_tokens":10},"latency_ms":200}')" \
  "$(fixture_event "tool_result" "tool" '{"tool_use_id":"tu_1","content":"file1\nfile2","is_error":false}' \
    "$RID" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"text","text":"Found 2 files"}],"stop_reason":"end_turn"}' \
    "$RID" "sess_test" "span_2" \
    '{"message_id":"msg_2","model":"m","usage":{"input_tokens":30,"output_tokens":15},"latency_ms":300}')"
OUT=$("$TRACE" "$RID")
assert_contains "$OUT" "span_1" "first span"
assert_contains "$OUT" "span_2" "second span"
assert_contains "$OUT" "list_directory" "tool name shown"
assert_contains "$OUT" "TOTAL" "total line"

desc "span ordering: numeric, not lexicographic (span_10 renders after span_2)"
setup_trace
RID="run_20260811T090000_spanorder"
mkdir -p "$SHAI_HOME/runs/$RID"
{
  fixture_event "message" "assistant" '{"content":[{"type":"text","text":"first"}],"stop_reason":"end_turn"}' "$RID" "sess_test" "span_2"
  fixture_event "message" "assistant" '{"content":[{"type":"text","text":"tenth"}],"stop_reason":"end_turn"}' "$RID" "sess_test" "span_10"
} >"$SHAI_HOME/runs/$RID/events.jsonl"
OUT=$("$TRACE" "$RID")
POS2=$(printf '%s\n' "$OUT" | grep -nx "span_2" | head -1 | cut -d: -f1)
POS10=$(printf '%s\n' "$OUT" | grep -nx "span_10" | head -1 | cut -d: -f1)
ORDER_OK=no
[ -n "$POS2" ] && [ -n "$POS10" ] && [ "$POS2" -lt "$POS10" ] && ORDER_OK=yes
assert_eq "$ORDER_OK" "yes" "span_2 renders before span_10 (numeric order, not lexicographic string order)"

desc "tool_result byte count: reports true length, not capped at 60"
setup_trace
RID="run_20260811T090000_bytecount"
LONG_RESULT=$(head -c 90 /dev/zero | tr '\0' 'y')
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"tool_use","id":"tu_1","name":"print_file","input":{"path":"x"}}],"stop_reason":"tool_use"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "tool_result" "tool" '{"tool_use_id":"tu_1","content":"'"$LONG_RESULT"'","is_error":false}' "$RID" "sess_test" "span_1")"
OUT=$("$TRACE" "$RID")
assert_contains "$OUT" "90 bytes" "byte count reflects the true 90-byte length, not a 60-char cap"

desc "--verbose: shows untruncated content; default view truncates"
setup_trace
RID="run_20260811T090000_verbose"
LONG_TEXT=$(head -c 200 /dev/zero | tr '\0' 'x')
LONG_RESULT=$(head -c 90 /dev/zero | tr '\0' 'y')
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"'"$LONG_TEXT"'"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"tool_use","id":"tu_1","name":"print_file","input":{"path":"x"}}],"stop_reason":"tool_use"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "tool_result" "tool" '{"tool_use_id":"tu_1","content":"'"$LONG_RESULT"'","is_error":false}' "$RID" "sess_test" "span_1")"
OUT_DEFAULT=$("$TRACE" "$RID")
FULL_TEXT_IN_DEFAULT=no
[[ "$OUT_DEFAULT" == *"$LONG_TEXT"* ]] && FULL_TEXT_IN_DEFAULT=yes
assert_eq "$FULL_TEXT_IN_DEFAULT" "no" "default view truncates the 200-char user text"
OUT_VERBOSE=$("$TRACE" "$RID" --verbose)
assert_contains "$OUT_VERBOSE" "$LONG_TEXT" "verbose view shows the full 200-char user text"
assert_contains "$OUT_VERBOSE" "$LONG_RESULT" "verbose view shows the full tool_result content"

desc "--json: outputs event array"
setup_trace
RID="run_20260811T090000_json"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")" \
  "$(fixture_event "message" "assistant" '{"content":[{"type":"text","text":"yo"}],"stop_reason":"end_turn"}' "$RID" "sess_test" "span_1")"
OUT=$("$TRACE" "$RID" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'type')" '"array"' "json is array"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "json has 2 events"

desc "--request: dumps request JSON"
setup_trace
RID="run_20260811T090000_req"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
OUT=$("$TRACE" "$RID" --request span_1)
assert_contains "$OUT" "model" "request has model"

desc "--request: missing span value exits 1"
setup_trace
RID="run_20260811T090000_reqmissing"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
assert_exit 1 "missing span value" -- "$TRACE" "$RID" --request

desc "--request: malformed dump file exits 1 with a clean error"
setup_trace
RID="run_20260811T090000_reqbad"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
printf '{"model":"m", invalid' >"$SHAI_HOME/runs/$RID/span_1-request.json"
ERR=$("$TRACE" "$RID" --request span_1 2>&1 >/dev/null)
assert_exit 1 "malformed request dump" -- "$TRACE" "$RID" --request span_1
assert_contains "$ERR" "not valid JSON" "clean error message for malformed request dump"

desc "--response: dumps response metadata"
setup_trace
RID="run_20260811T090000_resp"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
OUT=$("$TRACE" "$RID" --response span_1)
assert_contains "$OUT" "message_id" "response has message_id"
assert_contains "$OUT" "latency_ms" "response has latency"

desc "--response: malformed dump file exits 1 with a clean error"
setup_trace
RID="run_20260811T090000_respbad"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
printf '{"message_id": invalid' >"$SHAI_HOME/runs/$RID/span_1-response.json"
ERR=$("$TRACE" "$RID" --response span_1 2>&1 >/dev/null)
assert_exit 1 "malformed response dump" -- "$TRACE" "$RID" --response span_1
assert_contains "$ERR" "not valid JSON" "clean error message for malformed response dump"

desc "prefix matching: unambiguous prefix works"
setup_trace
RID="run_20260811T090000_prefix"
make_run_with_dumps "$RID" \
  "$(fixture_event "message" "user" '{"text":"hi"}' "$RID" "sess_test" "span_1")"
OUT=$("$TRACE" "run_20260811T090000_pre" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "prefix resolves"

desc "prefix matching: no match exits 1"
setup_trace
assert_exit 1 "no match" -- "$TRACE" "run_nonexistent"

desc "prefix matching: ambiguous run directory prefix exits 1 (not a silent fallback)"
setup_trace
mkdir -p "$SHAI_HOME/runs/run_20260811T090000_ambA" "$SHAI_HOME/runs/run_20260811T090000_ambB"
fixture_event "message" "user" '{"text":"a"}' "run_20260811T090000_ambA" "sess_test" "span_1" \
  >"$SHAI_HOME/runs/run_20260811T090000_ambA/events.jsonl"
fixture_event "message" "user" '{"text":"b"}' "run_20260811T090000_ambB" "sess_test" "span_1" \
  >"$SHAI_HOME/runs/run_20260811T090000_ambB/events.jsonl"
ERR=$("$TRACE" "run_20260811T090000_amb" 2>&1 >/dev/null)
assert_exit 1 "ambiguous run prefix" -- "$TRACE" "run_20260811T090000_amb"
assert_contains "$ERR" "ambiguous" "ambiguous run prefix reports the conflict instead of silently falling back"

desc "session fallback: warns and finds events"
setup_trace
RID="run_20260811T090000_fallback"
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"hi"}' "$RID" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' "$RID" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$TRACE" "$RID" 2>&1)
assert_contains "$OUT" "hi" "found events in session log"
assert_contains "$OUT" "error events may be missing" "fallback warning names the specific risk (acceptance criterion)"

desc "session fallback: prefix (not full run id) still finds events"
setup_trace
SID="sess_20260811T090000_pfx1"
fixture_event "message" "user" '{"text":"prefix hit"}' "run_20260811T090000_fallbackprefix" "$SID" "span_1" \
  >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$TRACE" "run_20260811T090000_fallbackpre" 2>/dev/null)
assert_contains "$OUT" "prefix hit" "fallback resolves a run-id prefix via startswith, not only an exact id"

desc "malformed session log during fallback: warns per-file, other session files still searched"
setup_trace
RID="run_20260811T090000_mixedfb"
printf '{"type":"message","source":"user","payload":{"text":"trunc' >"$SHAI_HOME/sessions/sess_20260811T080000_bad1.jsonl"
fixture_event "message" "user" '{"text":"good session event"}' "$RID" "sess_20260811T090000_good1" "span_1" \
  >"$SHAI_HOME/sessions/sess_20260811T090000_good1.jsonl"
OUT=$("$TRACE" "$RID" 2>/dev/null)
ERR=$("$TRACE" "$RID" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed session log does not abort the trace (exit 0)"
assert_contains "$OUT" "good session event" "well-formed session file still contributes events"
assert_contains "$ERR" "warning" "warning printed for the malformed session log"
assert_contains "$ERR" "sess_20260811T080000_bad1.jsonl" "warning names the malformed session file"

desc "malformed run events.jsonl: warns and still renders the well-formed prefix"
setup_trace
RID="run_20260811T090000_badrun"
mkdir -p "$SHAI_HOME/runs/$RID"
{
  fixture_event "message" "user" '{"text":"good event"}' "$RID" "sess_test" "span_1"
  printf '{"type":"message","source":"user","payload":{"text":"trunc'
} >"$SHAI_HOME/runs/$RID/events.jsonl"
OUT=$("$TRACE" "$RID" 2>/dev/null)
ERR=$("$TRACE" "$RID" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed run events.jsonl does not abort the trace (exit 0)"
assert_contains "$OUT" "good event" "well-formed prefix of the run's events is still rendered"
assert_contains "$ERR" "warning" "warning printed for the malformed events file"

desc "no events found: error"
setup_trace
assert_exit 1 "no events" -- "$TRACE" "run_20260811T090000_gone"

desc "invalid args: exit 1"
assert_exit 1 "no args" -- "$TRACE"

finish
