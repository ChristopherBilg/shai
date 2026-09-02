#!/bin/bash
# test_print.sh — unit tests for shai-print
# Covers: shai-print — event rendering, --debug and --dispatches show/hide
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-print"

# --- ported from tests/tests.sh:203-215 (assistant text, error line, default hides
#     tool_use/tool_result, --debug shows both) ---
NOTOOL='{"type":"message","source":"assistant","payload":{"content":"hi","finish_reason":"stop"}}'
POUT=$(echo "$NOTOOL" | "$DIR/shai-print")
assert_eq "$POUT" "hi" "print: assistant text"
EOUT=$(echo '{"type":"error","source":"system","payload":{"text":"boom"}}' | "$DIR/shai-print")
assert_eq "$EOUT" "Error: boom" "print: error line"
TOOL_MSG='{"type":"message","source":"assistant","payload":{"content":null,"tool_calls":[{"id":"t1","type":"function","function":{"name":"gh","arguments":"{\"args\":[\"pr\",\"view\",\"123\"]}"}}],"finish_reason":"tool_calls"}}'
assert_eq "$(echo "$TOOL_MSG" | "$DIR/shai-print")" "" "print: default hides tool_use"
TDEBUG=$(echo "$TOOL_MSG" | "$DIR/shai-print" --debug)
assert_contains "$TDEBUG" '[tool_use: gh' "print: --debug shows tool_use"
TOOL_RES='{"type":"tool_result","source":"tool","payload":{"tool_call_id":"t1","content":"result data","is_error":false}}'
assert_eq "$(echo "$TOOL_RES" | "$DIR/shai-print")" "" "print: default hides tool_result"
TRDEBUG=$(echo "$TOOL_RES" | "$DIR/shai-print" --debug)
assert_contains "$TRDEBUG" '[tool_result:' "print: --debug shows tool_result"

# new: content is a single string now — the OpenAI-compatible schema has no multi-text-block
# concept, so there is nothing analogous to the old "multiple text blocks in one message" case
# to port.
SINGLETXT='{"type":"message","source":"assistant","payload":{"content":"first","finish_reason":"stop"}}'
STOUT=$(echo "$SINGLETXT" | "$DIR/shai-print")
assert_eq "$STOUT" "first" "print: single string content printed"

# new: under --debug, text precedes the tool_use annotation for the same message
MIX='{"type":"message","source":"assistant","payload":{"content":"thinking","tool_calls":[{"id":"t1","type":"function","function":{"name":"gh","arguments":"{\"args\":[\"pr\",\"view\",\"1\"]}"}}],"finish_reason":"tool_calls"}}'
MIXOUT=$(echo "$MIX" | "$DIR/shai-print" --debug)
assert_eq "$(printf '%s' "$MIXOUT" | head -n1)" "thinking" "print: --debug prints text before tool_use"
assert_contains "$MIXOUT" '[tool_use: gh' "print: --debug shows the tool_use annotation"

# new: --dispatches renders tool_use as a tidy "⏺ name(args)" line
DISP=$(echo "$TOOL_MSG" | "$DIR/shai-print" --dispatches)
assert_eq "$DISP" '⏺ gh(args: ["pr","view","123"])' "print: --dispatches renders tool_use as marker line"

# new: --dispatches still prints assistant text
assert_eq "$(echo "$NOTOOL" | "$DIR/shai-print" --dispatches)" "hi" "print: --dispatches still prints assistant text"

# new: --dispatches prints text before the marker in a mixed message
MIXDISP=$(echo "$MIX" | "$DIR/shai-print" --dispatches)
assert_eq "$(printf '%s' "$MIXDISP" | head -n1)" "thinking" "print: --dispatches prints text before the marker"
assert_contains "$MIXDISP" '⏺ gh(args: ["pr","view","1"])' "print: --dispatches marker follows text"

# new: --dispatches hides tool_result (results are never shown)
assert_eq "$(echo "$TOOL_RES" | "$DIR/shai-print" --dispatches)" "" "print: --dispatches hides tool_result"

# new: --dispatches handles empty tool input
EMPTY_TOOL='{"type":"message","source":"assistant","payload":{"content":null,"tool_calls":[{"id":"t2","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}}'
assert_eq "$(echo "$EMPTY_TOOL" | "$DIR/shai-print" --dispatches)" "⏺ list_directory()" "print: --dispatches handles empty input"

finish
