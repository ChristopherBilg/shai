#!/bin/bash
# test_retry.sh — tests for shai-retry
# Covers: shai-retry — tail classification (DISPATCH/EVAL/DONE), resume actions, no-op cases
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-retry"

new_home() {
  SHOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SHOME")
  mkdir -p "$SHOME/sessions"
  SHIST="$SHOME/sessions/test.jsonl"
}

# DONE: empty/missing history → nothing to resume, exit 0
new_home
OUT=$(SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" 2>&1)
RC=$?
assert_contains "$OUT" "nothing to resume" "retry: empty history → nothing to resume"
assert_eq "$RC" "0" "retry: empty history → exit 0"

# DONE: a completed assistant turn is not resumed and appends nothing
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"UNCALLED"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"hello"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}
JSON
BEFORE=$(wc -l <"$SHIST")
OUT=$(SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" 2>&1)
AFTER=$(wc -l <"$SHIST")
assert_contains "$OUT" "nothing to resume" "retry: completed turn → nothing to resume"
assert_eq "$AFTER" "$BEFORE" "retry: completed turn appends no history"

# a blank/garbled tail must be a no-op, not a fall-through that dispatches stale latest.json
BLANKH="$(mktemp -d)"
_CLEANUP_DIRS+=("$BLANKH")
mkdir -p "$BLANKH/sessions"
{
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}'
  printf '\n'
} >"$BLANKH/sessions/test.jsonl"
# latest.json stays as-is (it's not session-partitioned)
printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"stale1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}' >"$BLANKH/latest.json"
BLANKBEFORE=$(wc -l <"$BLANKH/sessions/test.jsonl")
BLANKOUT=$(SHAI_HOME="$BLANKH" SHAI_SESSION_ID=test "$DIR/shai-retry" 2>&1)
assert_contains "$BLANKOUT" "nothing to resume" "retry: blank tail is a no-op"
assert_eq "$(wc -l <"$BLANKH/sessions/test.jsonl")" "$BLANKBEFORE" "retry: blank tail appends nothing"

# EVAL: an error tail re-evaluates to a fresh assistant turn
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"recovered answer"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"do the thing"}}
{"type":"error","source":"system","payload":{"text":"request failed (curl)"}}
JSON
SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
assert_contains "$(cat "$SHIST")" "recovered answer" "retry: error tail re-evaluates"

# EVAL: a tool_result tail re-evaluates (model owes a reply)
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"final summary"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"summarize"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"t1","content":"a\nb","is_error":false}}
JSON
SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
assert_contains "$(cat "$SHIST")" "final summary" "retry: tool_result tail re-evaluates"

# DISPATCH: a dangling tool_use tail runs the tool, then re-evaluates
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"after tool"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"list the dir"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}
JSON
SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
H=$(cat "$SHIST")
assert_contains "$H" '"type":"tool_result"' "retry: dangling tool_use is dispatched (tool_result appended)"
assert_contains "$H" 'after tool' "retry: after dispatch, re-eval completes the turn"

# no API key + nothing to resume: the no-op path must NOT be gated by the health-check (exit 0)
new_home
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"hello"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}
JSON
OUT=$(env -u ANTHROPIC_API_KEY SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" 2>&1)
RC=$?
assert_contains "$OUT" "nothing to resume" "retry: complete turn + no key → nothing to resume"
assert_eq "$RC" "0" "retry: complete turn + no key → exit 0 (health-check not gating no-op)"

# no API key + work pending: fail fast at the health-check (exit 1)
new_home
cat >"$SHIST" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"do the thing"}}
{"type":"error","source":"system","payload":{"text":"boom"}}
JSON
assert_exit 1 "retry: work pending + no key → exit 1" -- env -u ANTHROPIC_API_KEY SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry"

# --- envelope + trace propagation on resume ----------------------------------
RTH="$(mktemp -d)"
_CLEANUP_DIRS+=("$RTH")
mkdir -p "$RTH/sessions"
write_roundtrip_curl_stub "$STUB"
# a deliberately UNSTAMPED history, as written by a pre-envelope shai: resume must still work
{
  printf '%s\n' '{"type":"message","source":"system","payload":{"text":"SYS"}}'
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}'
  printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"tu1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}'
} >"$RTH/sessions/sess_resume.jsonl"

SHAI_HOME="$RTH" SHAI_SESSION_ID=sess_resume "$DIR/shai-retry" -q >/dev/null 2>&1
unset SHAI_ROUND_COUNT

# the pre-existing unstamped events are untouched; only new ones are stamped
UNSTAMPED=$(jq -r 'select(has("meta") | not) | .type' "$RTH/sessions/sess_resume.jsonl" | wc -l)
assert_eq "$UNSTAMPED" "3" "retry: pre-envelope history left as-is (backward compatible)"

# the recovered dispatch opens span_1 of the NEW run
FIRSTNEW=$(jq -r 'select(has("meta")) | .meta.span_id' "$RTH/sessions/sess_resume.jsonl" | head -n1)
assert_eq "$FIRSTNEW" "span_1" "retry: recovered tool_result opens span_1"

# the resume is a new run, and every new event shares it
NEWRUNS=$(jq -r 'select(has("meta")) | .meta.run_id' "$RTH/sessions/sess_resume.jsonl" | sort -u | wc -l)
assert_eq "$NEWRUNS" "1" "retry: one fresh run_id for the whole resume"

# session id is inherited, not re-minted
RSESS=$(jq -r 'select(has("meta")) | .meta.session_id' "$RTH/sessions/sess_resume.jsonl" | sort -u)
assert_eq "$RSESS" "sess_resume" "retry: inherited session id honored"

# the loop advanced past span_1, proving dispatch's exit-1 survived | shai-stamp
MAXSPAN=$(jq -r 'select(has("meta")) | .meta.span_id' "$RTH/sessions/sess_resume.jsonl" | sort -u | tail -n1)
assert_eq "$MAXSPAN" "span_3" "retry: loop advanced to span_3 (dispatch signal survived stamp)"

# the resume wrote its own run log
RRUN=$(jq -r 'select(has("meta")) | .meta.run_id' "$RTH/sessions/sess_resume.jsonl" | head -n1)
assert_eq "$([ -f "$RTH/runs/$RRUN/events.jsonl" ] && echo yes)" "yes" \
  "retry: runs/<new_run_id>/events.jsonl created"

# --- a no-op resume must not create a run directory ---
NOOPH="$(mktemp -d)"
_CLEANUP_DIRS+=("$NOOPH")
SHAI_HOME="$NOOPH" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
assert_eq "$(find "$NOOPH/runs" -mindepth 1 -type d 2>/dev/null | wc -l)" "0" "retry: empty history creates no run dir"

DONEH="$(mktemp -d)"
_CLEANUP_DIRS+=("$DONEH")
mkdir -p "$DONEH/sessions"
{
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}'
  printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}'
} >"$DONEH/sessions/test.jsonl"
SHAI_HOME="$DONEH" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
assert_eq "$(find "$DONEH/runs" -mindepth 1 -type d 2>/dev/null | wc -l)" "0" "retry: completed history creates no run dir"

# --- pending work but no API key must not create a run dir either ---
NOKEYH="$(mktemp -d)"
_CLEANUP_DIRS+=("$NOKEYH")
mkdir -p "$NOKEYH/sessions"
{
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}'
  printf '%s\n' '{"type":"error","source":"system","payload":{"text":"boom"}}'
} >"$NOKEYH/sessions/test.jsonl"
env -u ANTHROPIC_API_KEY SHAI_HOME="$NOKEYH" SHAI_SESSION_ID=test "$DIR/shai-retry" >/dev/null 2>&1
assert_eq "$(find "$NOKEYH/runs" -mindepth 1 -type d 2>/dev/null | wc -l)" "0" "retry: missing key creates no run dir"

finish
