#!/bin/bash
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-print"

# --- ported from tests/tests.sh:203-215 (assistant text, error line, default hides
#     tool_use/tool_result, --debug shows both) ---
NOTOOL='{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}'
POUT=$(echo "$NOTOOL" | "$DIR/shai-print")
assert_eq "$POUT" "hi" "print: assistant text"
EOUT=$(echo '{"type":"error","source":"system","payload":{"text":"boom"}}' | "$DIR/shai-print")
assert_eq "$EOUT" "Error: boom" "print: error line"
TOOL_MSG='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"gh_pr_view","input":{"number":"123"}}],"stop_reason":"tool_use"}}'
assert_eq "$(echo "$TOOL_MSG" | "$DIR/shai-print")" "" "print: default hides tool_use"
TDEBUG=$(echo "$TOOL_MSG" | "$DIR/shai-print" --debug)
assert_contains "$TDEBUG" '[tool_use: gh_pr_view' "print: --debug shows tool_use"
TOOL_RES='{"type":"tool_result","source":"tool","payload":{"tool_use_id":"t1","content":"result data","is_error":false}}'
assert_eq "$(echo "$TOOL_RES" | "$DIR/shai-print")" "" "print: default hides tool_result"
TRDEBUG=$(echo "$TOOL_RES" | "$DIR/shai-print" --debug)
assert_contains "$TRDEBUG" '[tool_result:' "print: --debug shows tool_result"

# new: multiple text blocks printed in order
MULTITXT='{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}],"stop_reason":"end_turn"}}'
MTOUT=$(echo "$MULTITXT" | "$DIR/shai-print")
assert_eq "$MTOUT" "$(printf 'first\nsecond')" "print: multiple text blocks printed in order"

# new: under --debug, text precedes the tool_use annotation for the same message
MIX='{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"thinking"},{"type":"tool_use","id":"t1","name":"gh_pr_view","input":{"number":"1"}}],"stop_reason":"tool_use"}}'
MIXOUT=$(echo "$MIX" | "$DIR/shai-print" --debug)
assert_eq "$(printf '%s' "$MIXOUT" | head -n1)" "thinking" "print: --debug prints text before tool_use"
assert_contains "$MIXOUT" '[tool_use: gh_pr_view' "print: --debug shows the tool_use annotation"

finish
