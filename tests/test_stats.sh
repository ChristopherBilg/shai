#!/bin/bash
# test_stats.sh — tests for shai-stats observability filter
# Covers: aggregate metrics, session scoping, date filtering, --json, empty state, missing api data, malformed file handling, failure-store stats
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STATS="$DIR/shai-stats"

setup_stats() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs" "$SHAI_HOME/failures"
}

# fixture_failure <category> <workflow> [ts] [summary]
# One failure-store record (lib/failure.sh schema) on stdout.
fixture_failure() {
  local category="$1" workflow="$2" ts="${3:-2026-08-11T12:00:00Z}" summary="${4:-failure}"
  jq -nc --arg ts "$ts" --arg wf "$workflow" --arg cat "$category" --arg sum "$summary" \
    '{ts:$ts, workflow:$wf, run_id:null, session_id:null, category:$cat, summary:$sum, context:{}}'
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

desc "cache tokens: --json includes cache hit/miss"
setup_stats
SID="sess_20260811T090000_cache"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"prompt_cache_hit_tokens":80,"prompt_cache_miss_tokens":20},"latency_ms":100}'
  fixture_event "message" "user" '{"text":"q2"}' "run_2" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a2","finish_reason":"stop"}' \
    "run_2" "$SID" "span_1" \
    '{"message_id":"m2","model":"m","usage":{"prompt_tokens":200,"completion_tokens":100,"total_tokens":300,"prompt_cache_hit_tokens":150,"prompt_cache_miss_tokens":50},"latency_ms":200}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.cache.hit')" "230" "cache hit tokens aggregated"
assert_eq "$(printf '%s' "$OUT" | jq '.cache.miss')" "70" "cache miss tokens aggregated"

desc "cache tokens: human output shows cache when nonzero"
setup_stats
SID="sess_20260811T090000_cacheh"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150,"prompt_cache_hit_tokens":80,"prompt_cache_miss_tokens":20},"latency_ms":100}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS")
assert_contains "$OUT" "cache hit:" "human output shows cache hit"
assert_contains "$OUT" "cache miss:" "human output shows cache miss"

desc "cache tokens: human output omits cache when zero"
setup_stats
SID="sess_20260811T090000_nocacheh"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150},"latency_ms":100}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS")
CACHED_IN_OUTPUT=no
[[ "$OUT" == *"cache"* ]] && CACHED_IN_OUTPUT=yes
assert_eq "$CACHED_IN_OUTPUT" "no" "no cache lines when fields absent"

desc "cache tokens: --json has zeroes when no cache fields"
setup_stats
SID="sess_20260811T090000_nocachej"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" \
    '{"content":"a","finish_reason":"stop"}' \
    "run_1" "$SID" "span_1" \
    '{"message_id":"m","model":"m","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150},"latency_ms":100}'
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.cache.hit')" "0" "cache hit 0 when absent"
assert_eq "$(printf '%s' "$OUT" | jq '.cache.miss')" "0" "cache miss 0 when absent"

desc "failures: --json includes failures key with correct structure"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
{
  fixture_failure "api_error" "wf_a" "2026-08-11T09:00:00Z"
  fixture_failure "api_error" "wf_a" "2026-08-12T09:00:00Z"
  fixture_failure "policy_denial" "wf_a" "2026-08-13T09:00:00Z"
} >"$SHAI_HOME/failures/wf_a.jsonl"
{
  fixture_failure "tool_error" "wf_b" "2026-08-11T09:00:00Z"
} >"$SHAI_HOME/failures/wf_b.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "4" "failures total"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.by_category | length')" "3" "three categories"
assert_eq "$(printf '%s' "$OUT" | jq -r '.failures.by_category[] | select(.category=="api_error") | .count')" "2" "api_error count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.failures.by_category[] | select(.category=="api_error") | .percent')" "50" "api_error percent"
assert_eq "$(printf '%s' "$OUT" | jq -r '.failures.by_category[] | select(.category=="tool_error") | .percent')" "25" "tool_error percent"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.by_workflow | length')" "2" "two workflows"
assert_eq "$(printf '%s' "$OUT" | jq -r '.failures.by_workflow[] | select(.workflow=="wf_a") | .count')" "3" "wf_a count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.failures.by_workflow[] | select(.workflow=="wf_b") | .count')" "1" "wf_b count"
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "session stats unaffected"

desc "failures: human output shows section with breakdowns"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
{
  fixture_failure "api_error" "wf_a" "2026-08-11T09:00:00Z"
  fixture_failure "api_error" "wf_a" "2026-08-12T09:00:00Z"
} >"$SHAI_HOME/failures/wf_a.jsonl"
{
  fixture_failure "tool_error" "wf_b" "2026-08-11T09:00:00Z"
} >"$SHAI_HOME/failures/wf_b.jsonl"
OUT=$("$STATS")
assert_contains "$OUT" "Failures:" "has failures header"
assert_contains "$OUT" "api_error: 2 (66%)" "category with count and percent"
assert_contains "$OUT" "tool_error: 1 (33%)" "second category with count and percent"
assert_contains "$OUT" "wf_a: 2" "workflow breakdown wf_a"
assert_contains "$OUT" "wf_b: 1" "workflow breakdown wf_b"

desc "failures: empty failure store → zeroed json, no human section"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "0" "zero failures total"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.by_category | length')" "0" "no categories"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.by_workflow | length')" "0" "no workflows"
HOUT=$("$STATS")
NO_FAILURES=no
[[ "$HOUT" == *"Failures:"* ]] && NO_FAILURES=yes
assert_eq "$NO_FAILURES" "no" "no failures section in human output"

desc "failures: --after/--before filter failure data"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
{
  fixture_failure "api_error" "wf_a" "2026-08-09T09:00:00Z"
  fixture_failure "api_error" "wf_a" "2026-08-11T09:00:00Z"
  fixture_failure "tool_error" "wf_a" "2026-08-13T09:00:00Z"
} >"$SHAI_HOME/failures/wf_a.jsonl"
OUT=$("$STATS" --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "2" "after filter on failures"
OUT=$("$STATS" --before 2026-08-12 --json)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "2" "before filter on failures"
OUT=$("$STATS" --after 2026-08-10 --before 2026-08-12 --json)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "1" "after+before window on failures"

desc "failures: --session scoping does not filter failures"
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
fixture_failure "api_error" "wf_a" "2026-08-11T09:00:00Z" >"$SHAI_HOME/failures/wf_a.jsonl"
fixture_failure "tool_error" "wf_b" "2026-08-11T09:00:00Z" >"$SHAI_HOME/failures/wf_b.jsonl"
OUT=$("$STATS" --session "$S1" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "1" "session scoped to 1"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "2" "failures unscoped by --session"

desc "failures: malformed failure file skipped with warning"
setup_stats
SID="sess_20260811T090000_aabb"
{
  fixture_event "message" "user" '{"text":"q"}' "run_1" "$SID" "span_1"
  fixture_event "message" "assistant" '{"content":"a","finish_reason":"stop"}' "run_1" "$SID" "span_1"
} >"$SHAI_HOME/sessions/$SID.jsonl"
fixture_failure "api_error" "wf_good" "2026-08-11T09:00:00Z" >"$SHAI_HOME/failures/wf_good.jsonl"
# Simulate a crash mid-append: a truncated, unparseable trailing line.
printf '{"ts":"2026-08-11T09:00:00Z","workflow":"wf_bad","category":"api_error","summary":"trunc' >"$SHAI_HOME/failures/wf_bad.jsonl"
OUT=$("$STATS" --json 2>/dev/null)
ERR=$("$STATS" 2>&1 >/dev/null)
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "1" "malformed failure file excluded, good file still counted"
assert_contains "$ERR" "wf_bad" "warning names the malformed failure file"

desc "failures: peer source — failures shown with no sessions"
setup_stats
fixture_failure "api_error" "wf_a" "2026-08-11T09:00:00Z" >"$SHAI_HOME/failures/wf_a.jsonl"
OUT=$("$STATS" --json)
assert_eq "$(printf '%s' "$OUT" | jq '.sessions')" "0" "zero sessions"
assert_eq "$(printf '%s' "$OUT" | jq '.failures.total')" "1" "failures still counted"
HOUT=$("$STATS")
assert_contains "$HOUT" "No sessions found." "no sessions message"
assert_contains "$HOUT" "Failures:" "failures section still shown"

desc "invalid args: exit 1"
assert_exit 1 "unknown flag" -- "$STATS" --bogus

finish
