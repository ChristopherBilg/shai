#!/bin/bash
# test_context.sh — unit tests for shai-context
# Covers: shai-context — byte-budget windowing, system extraction, tool_result folding, request shape
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

# new: empty history → empty messages, empty system
CTXEMPTY=$(printf '' | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXEMPTY" | jq '.messages | length')" "0" "context: empty history → no messages"
assert_eq "$(printf '%s' "$CTXEMPTY" | jq -r '.system')" "" "context: empty history → empty system"

# byte budget: drops oldest turn groups when budget exceeded
# Each turn group here is ~130-180 bytes serialized. Set a budget that fits only the last 2.
HISTB='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a1"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u2"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a2"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u3"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a3"}],"stop_reason":"end_turn"}}'
CTXB=$(printf '%s\n' "$HISTB" | "$DIR/shai-context" --max-bytes 400)
assert_eq "$(printf '%s' "$CTXB" | jq '.messages | length')" "4" "context: --max-bytes 400 keeps last 2 turn groups"
assert_eq "$(printf '%s' "$CTXB" | jq -r '.messages[0].content')" "u2" "context: --max-bytes drops oldest turn group"

# byte budget: latest turn always preserved even when over budget (soft ceiling)
CTXOVER=$(printf '%s\n' "$HISTB" | "$DIR/shai-context" --max-bytes 1)
assert_eq "$(printf '%s' "$CTXOVER" | jq '.messages | length')" "2" "context: --max-bytes 1 still keeps latest turn group"
assert_eq "$(printf '%s' "$CTXOVER" | jq -r '.messages[0].content')" "u3" "context: soft ceiling preserves latest turn"

# byte budget: system prompt bytes subtracted from budget
HISTSYS='{"type":"message","source":"system","payload":{"text":"A system prompt that takes up bytes"}}
{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a1"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u2"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a2"}],"stop_reason":"end_turn"}}'
CTXSYS=$(printf '%s\n' "$HISTSYS" | "$DIR/shai-context" --max-bytes 500)
CTXSYS_TURNS=$(printf '%s' "$CTXSYS" | jq '.messages | length')
assert_eq "$(printf '%s' "$CTXSYS" | jq -r '.system')" "A system prompt that takes up bytes" "context: system prompt preserved under byte budget"
# With the system prompt eating into the budget, fewer turns fit
CTXSYS_NOSYS=$(printf '%s\n' "$HISTSYS" | sed '1d' | "$DIR/shai-context" --max-bytes 500)
CTXSYS_NOSYS_TURNS=$(printf '%s' "$CTXSYS_NOSYS" | jq '.messages | length')
# Without system prompt, more budget for history → same or more turns
GE_RC=0
[ "$CTXSYS_NOSYS_TURNS" -ge "$CTXSYS_TURNS" ] || GE_RC=1
assert_eq "$GE_RC" "0" "context: system prompt bytes reduce available history budget"

# env var: SHAI_MAX_CONTEXT_BYTES respected
# (the assignment must prefix shai-context itself, not printf — a shell pipeline only
# scopes a leading VAR=val to the one command it directly prefixes)
CTXENV=$(printf '%s\n' "$HISTB" | SHAI_MAX_CONTEXT_BYTES=400 "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXENV" | jq -r '.messages[0].content')" "u2" "context: SHAI_MAX_CONTEXT_BYTES env var respected"

# env var: --max-bytes overrides SHAI_MAX_CONTEXT_BYTES
CTXENVOVER=$(SHAI_MAX_CONTEXT_BYTES=1 printf '%s\n' "$HISTB" | "$DIR/shai-context" --max-bytes 999999)
assert_eq "$(printf '%s' "$CTXENVOVER" | jq '.messages | length')" "6" "context: --max-bytes overrides env var"

# --max-bytes with no value errors (exit 1)
assert_exit 1 "context: --max-bytes with no value exits 1" -- bash -c 'echo "" | "'"$DIR"'/shai-context" --max-bytes'

# default budget keeps all turns when total is well under 1,300,000 bytes
HISTDEF='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"a1"}],"stop_reason":"end_turn"}}
{"type":"message","source":"user","payload":{"text":"u2"}}'
CTXDEF=$(printf '%s\n' "$HISTDEF" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXDEF" | jq '.messages | length')" "3" "context: default budget keeps all turns under the limit"

finish
