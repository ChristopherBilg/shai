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
}

# DONE: empty/missing history → nothing to resume, exit 0
new_home
OUT=$(SHAI_HOME="$SHOME" "$DIR/shai-retry" 2>&1)
RC=$?
assert_contains "$OUT" "nothing to resume" "retry: empty history → nothing to resume"
assert_eq "$RC" "0" "retry: empty history → exit 0"

# DONE: a completed assistant turn is not resumed and appends nothing
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"UNCALLED"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHOME/history.jsonl" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"hello"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}
JSON
BEFORE=$(wc -l <"$SHOME/history.jsonl")
OUT=$(SHAI_HOME="$SHOME" "$DIR/shai-retry" 2>&1)
AFTER=$(wc -l <"$SHOME/history.jsonl")
assert_contains "$OUT" "nothing to resume" "retry: completed turn → nothing to resume"
assert_eq "$AFTER" "$BEFORE" "retry: completed turn appends no history"

# EVAL: an error tail re-evaluates to a fresh assistant turn
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"recovered answer"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHOME/history.jsonl" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"do the thing"}}
{"type":"error","source":"system","payload":{"text":"request failed (curl)"}}
JSON
SHAI_HOME="$SHOME" "$DIR/shai-retry" >/dev/null 2>&1
assert_contains "$(cat "$SHOME/history.jsonl")" "recovered answer" "retry: error tail re-evaluates"

# EVAL: a tool_result tail re-evaluates (model owes a reply)
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"final summary"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHOME/history.jsonl" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"summarize"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"t1","content":"a\nb","is_error":false}}
JSON
SHAI_HOME="$SHOME" "$DIR/shai-retry" >/dev/null 2>&1
assert_contains "$(cat "$SHOME/history.jsonl")" "final summary" "retry: tool_result tail re-evaluates"

# DISPATCH: a dangling tool_use tail runs the tool, then re-evaluates
new_home
make_stub_bin
printf '%s' '{"type":"message","content":[{"type":"text","text":"after tool"}],"stop_reason":"end_turn"}' | write_curl_stub 200
cat >"$SHOME/history.jsonl" <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"list the dir"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}
JSON
SHAI_HOME="$SHOME" "$DIR/shai-retry" >/dev/null 2>&1
H=$(cat "$SHOME/history.jsonl")
assert_contains "$H" '"type":"tool_result"' "retry: dangling tool_use is dispatched (tool_result appended)"
assert_contains "$H" 'after tool' "retry: after dispatch, re-eval completes the turn"

finish
