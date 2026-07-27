#!/bin/bash
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-context"

HIST='{"type":"message","source":"system","payload":{"text":"SYS"}}
{"type":"message","source":"user","payload":{"text":"hi"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hello"}],"stop_reason":"end_turn"}}'
CTX=$(printf '%s\n' "$HIST" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTX" | jq -r '.system')" "SYS" "context: system extraction"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[0].role')" "user" "context: first role user"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[0].content')" "hi" "context: user content"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[1].role')" "assistant" "context: assistant role"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[1].content[0].text')" "hello" "context: assistant blocks preserved"

HIST2='{"type":"message","source":"user","payload":{"text":"read file"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"print_file","input":{"path":"x"}}],"stop_reason":"tool_use"}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"t1","content":"FILEDATA","is_error":false}}'
CTX2=$(printf '%s\n' "$HIST2" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].content[0].type')" "tool_result" "context: tool_result folded"
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].content[0].tool_use_id')" "t1" "context: tool_use_id pairing"
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].role')" "user" "context: tool_result in user turn"

HISTW='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a1"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u2"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a2"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u3"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a3"}],"stop_reason":"end_turn"}}'
CTXW=$(printf '%s\n' "$HISTW" | "$DIR/shai-context" --window 1)
assert_eq "$(printf '%s' "$CTXW" | jq '.messages | length')" "2" "context: --window 1 keeps last turn only"
assert_eq "$(printf '%s' "$CTXW" | jq -r '.messages[0].content')" "u3" "context: --window 1 starts at last user turn"
CTXZERO=$(printf '%s\n' "$HISTW" | "$DIR/shai-context" --window 0)
assert_eq "$(printf '%s' "$CTXZERO" | jq '.messages | length')" "0" "context: --window 0 keeps no turns"

HISTM='this is not json
{"type":"message","source":"user","payload":{"text":"hi"}}
{"type":"message","source":"user","payload":"shape-bad"}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}}'
CTXM=$(printf '%s\n' "$HISTM" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXM" | jq -r '.messages[0].content')" "hi" "context: malformed + shape-bad lines skipped"
assert_eq "$(printf '%s' "$CTXM" | jq '.messages | length')" "2" "context: only valid events reduced"

# new: two consecutive tool_results fold into ONE user turn
HISTTR='{"type":"message","source":"user","payload":{"text":"go"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"a","name":"list_directory","input":{"path":"."}},{"type":"tool_use","id":"b","name":"print_file","input":{"path":"x"}}],"stop_reason":"tool_use"}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"a","content":"LS","is_error":false}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"b","content":"FILE","is_error":false}}'
CTXTR=$(printf '%s\n' "$HISTTR" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXTR" | jq '.messages[-1].content | length')" "2" "context: consecutive tool_results fold into one user turn"
assert_eq "$(printf '%s' "$CTXTR" | jq -r '.messages[-1].role')" "user" "context: folded tool_results are a user turn"

# new: --window with no value errors (exit 1)
assert_exit 1 "context: --window with no value exits 1" -- bash -c 'echo "" | "'"$DIR"'/shai-context" --window'

# new: empty history → empty messages, empty system
CTXEMPTY=$(printf '' | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXEMPTY" | jq '.messages | length')" "0" "context: empty history → no messages"
assert_eq "$(printf '%s' "$CTXEMPTY" | jq -r '.system')" "" "context: empty history → empty system"

# new: default window keeps all turns when fewer than 10 user turns exist
HISTDEF='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a1"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u2"}}'
CTXDEF=$(printf '%s\n' "$HISTDEF" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXDEF" | jq '.messages | length')" "3" "context: default window keeps all turns under the limit"

finish
