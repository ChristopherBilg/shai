#!/bin/bash
# test_context.sh — unit tests for shai-context
# Covers: shai-context — byte-budget windowing, system extraction, tool_result messages, request shape
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-context"

HIST='{"type":"message","source":"system","payload":{"text":"SYS"}}
{"type":"message","source":"user","payload":{"text":"hi"}}
{"type":"message","source":"assistant","payload":{"content":"hello","finish_reason":"stop"}}'
CTX=$(printf '%s\n' "$HIST" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[0].role')" "system" "context: system prompt as first message"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[0].content')" "SYS" "context: system extraction"
assert_eq "$(printf '%s' "$CTX" | jq 'has("system")')" "false" "context: no top-level system key"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[1].role')" "user" "context: user role after system"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[1].content')" "hi" "context: user content"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[2].role')" "assistant" "context: assistant role"
assert_eq "$(printf '%s' "$CTX" | jq -r '.messages[2].content')" "hello" "context: assistant content is a string"

HIST2='{"type":"message","source":"user","payload":{"text":"read file"}}
{"type":"message","source":"assistant","payload":{"content":null,"tool_calls":[{"id":"t1","type":"function","function":{"name":"print_file","arguments":"{\"path\":\"x\"}"}}],"finish_reason":"tool_calls"}}
{"type":"tool_result","source":"tool","payload":{"tool_call_id":"t1","content":"FILEDATA","is_error":false}}'
CTX2=$(printf '%s\n' "$HIST2" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].role')" "tool" "context: tool_result becomes its own tool message"
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].tool_call_id')" "t1" "context: tool_call_id pairing"
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[2].content')" "FILEDATA" "context: tool message content"
assert_eq "$(printf '%s' "$CTX2" | jq -r '.messages[1].tool_calls[0].id')" "t1" "context: assistant tool_calls preserved"

HISTM='this is not json
{"type":"message","source":"user","payload":{"text":"hi"}}
{"type":"message","source":"user","payload":"shape-bad"}
{"type":"message","source":"assistant","payload":{"content":"ok","finish_reason":"stop"}}'
CTXM=$(printf '%s\n' "$HISTM" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXM" | jq -r '.messages[0].content')" "hi" "context: malformed + shape-bad lines skipped"
assert_eq "$(printf '%s' "$CTXM" | jq '.messages | length')" "2" "context: only valid events reduced"

# new: two consecutive tool_results become TWO separate tool messages (no folding)
HISTTR='{"type":"message","source":"user","payload":{"text":"go"}}
{"type":"message","source":"assistant","payload":{"content":null,"tool_calls":[{"id":"a","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}},{"id":"b","type":"function","function":{"name":"print_file","arguments":"{\"path\":\"x\"}"}}],"finish_reason":"tool_calls"}}
{"type":"tool_result","source":"tool","payload":{"tool_call_id":"a","content":"LS","is_error":false}}
{"type":"tool_result","source":"tool","payload":{"tool_call_id":"b","content":"FILE","is_error":false}}'
CTXTR=$(printf '%s\n' "$HISTTR" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXTR" | jq '.messages | length')" "4" "context: two tool_results produce four total messages (user, assistant, tool, tool)"
assert_eq "$(printf '%s' "$CTXTR" | jq -r '.messages[2].role')" "tool" "context: first tool_result is its own tool message"
assert_eq "$(printf '%s' "$CTXTR" | jq -r '.messages[2].tool_call_id')" "a" "context: first tool message tool_call_id"
assert_eq "$(printf '%s' "$CTXTR" | jq -r '.messages[3].role')" "tool" "context: second tool_result is its own tool message"
assert_eq "$(printf '%s' "$CTXTR" | jq -r '.messages[3].tool_call_id')" "b" "context: second tool message tool_call_id"

# new: empty history → empty messages
CTXEMPTY=$(printf '' | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXEMPTY" | jq '.messages | length')" "0" "context: empty history → no messages"
assert_eq "$(printf '%s' "$CTXEMPTY" | jq 'has("system")')" "false" "context: empty history → no top-level system key"

# byte budget: drops oldest turn groups when budget exceeded
# Each turn group here is ~130-180 bytes serialized. Set a budget that fits only the last 2.
HISTB='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":"a1","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"u2"}}
{"type":"message","source":"assistant","payload":{"content":"a2","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"u3"}}
{"type":"message","source":"assistant","payload":{"content":"a3","finish_reason":"stop"}}'
CTXB=$(printf '%s\n' "$HISTB" | "$DIR/shai-context" --max-bytes 400)
assert_eq "$(printf '%s' "$CTXB" | jq '.messages | length')" "4" "context: --max-bytes 400 keeps last 2 turn groups"
assert_eq "$(printf '%s' "$CTXB" | jq -r '.messages[0].content')" "u2" "context: --max-bytes drops oldest turn group"

# byte budget: latest turn always preserved even when over budget (soft ceiling)
CTXOVER=$(printf '%s\n' "$HISTB" | "$DIR/shai-context" --max-bytes 1)
assert_eq "$(printf '%s' "$CTXOVER" | jq '.messages | length')" "2" "context: --max-bytes 1 still keeps latest turn group"
assert_eq "$(printf '%s' "$CTXOVER" | jq -r '.messages[0].content')" "u3" "context: soft ceiling preserves latest turn"

# non-monotonic turn sizes: a large middle turn (~2180B) fails the budget, but the reduce
# must not keep walking past it just because an even-older, smaller turn (~189B) would fit
# on its own — that would drag the skipped large turn back in via the contiguous slice.
HISTNM='{"type":"message","source":"user","payload":{"text":"short1"}}
{"type":"message","source":"assistant","payload":{"content":"short reply 1","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"'"$(head -c 2000 /dev/zero | tr '\0' 'x')"'"}}
{"type":"message","source":"assistant","payload":{"content":"long reply","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"short3"}}
{"type":"message","source":"assistant","payload":{"content":"short reply 3","finish_reason":"stop"}}'
CTXNM=$(printf '%s\n' "$HISTNM" | "$DIR/shai-context" --max-bytes 600)
assert_eq "$(printf '%s' "$CTXNM" | jq '.messages | length')" "2" "context: non-monotonic sizes drop everything before the oversized turn"
assert_eq "$(printf '%s' "$CTXNM" | jq -r '.messages[0].content')" "short3" "context: non-monotonic sizes do not pull back oversized turns"

# byte budget: system prompt bytes subtracted from budget
HISTSYS='{"type":"message","source":"system","payload":{"text":"A system prompt that takes up bytes"}}
{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":"a1","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"u2"}}
{"type":"message","source":"assistant","payload":{"content":"a2","finish_reason":"stop"}}'
CTXSYS=$(printf '%s\n' "$HISTSYS" | "$DIR/shai-context" --max-bytes 500)
# Count only non-system messages: the system prompt now occupies a message slot of its
# own, so raw `.messages | length` would conflate "history that fit" with "system message
# present or not." Excluding it restores the original comparison (history capacity only).
CTXSYS_TURNS=$(printf '%s' "$CTXSYS" | jq '[.messages[] | select(.role != "system")] | length')
assert_eq "$(printf '%s' "$CTXSYS" | jq -r '.messages[0].role')" "system" "context: system prompt preserved under byte budget"
assert_eq "$(printf '%s' "$CTXSYS" | jq -r '.messages[0].content')" "A system prompt that takes up bytes" "context: system prompt content preserved under byte budget"
# With the system prompt eating into the budget, fewer turns fit
CTXSYS_NOSYS=$(printf '%s\n' "$HISTSYS" | sed '1d' | "$DIR/shai-context" --max-bytes 500)
CTXSYS_NOSYS_TURNS=$(printf '%s' "$CTXSYS_NOSYS" | jq '[.messages[] | select(.role != "system")] | length')
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
CTXENVOVER=$(printf '%s\n' "$HISTB" | SHAI_MAX_CONTEXT_BYTES=1 "$DIR/shai-context" --max-bytes 999999)
assert_eq "$(printf '%s' "$CTXENVOVER" | jq '.messages | length')" "6" "context: --max-bytes overrides env var"

# --max-bytes with no value errors (exit 1)
assert_exit 1 "context: --max-bytes with no value exits 1" -- bash -c 'echo "" | "$1/shai-context" --max-bytes' _ "$DIR"

# --max-bytes / SHAI_MAX_CONTEXT_BYTES validation: non-integer and zero rejected
assert_exit 1 "context: --max-bytes non-integer exits 1" -- bash -c 'echo "" | "$1/shai-context" --max-bytes abc' _ "$DIR"
assert_exit 1 "context: --max-bytes zero exits 1" -- bash -c 'echo "" | "$1/shai-context" --max-bytes 0' _ "$DIR"
assert_exit 1 "context: SHAI_MAX_CONTEXT_BYTES non-integer exits 1" -- bash -c 'echo "" | SHAI_MAX_CONTEXT_BYTES=notanumber "$1/shai-context"' _ "$DIR"

# regression (#154): a checkout path containing shell metacharacters must survive the
# bash -c boundary. The path is passed positionally so the inner shell never re-expands
# it; with the old string-splice, a literal `$$` in the path became a PID, the script
# path stopped resolving, and the suite failed with 127 instead of the expected 1.
META_DIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$META_DIR")
META_PATH="$META_DIR/issue-worker-\$\$"
mkdir -p "$META_PATH"
ln -s "$DIR/shai-context" "$META_PATH/shai-context"
assert_exit 1 "context: metacharacter path survives bash -c boundary (exit 1, not 127)" -- bash -c 'echo "" | "$1/shai-context" --max-bytes' _ "$META_PATH"

# default budget keeps all turns when total is well under 1,300,000 bytes
HISTDEF='{"type":"message","source":"user","payload":{"text":"u1"}}
{"type":"message","source":"assistant","payload":{"content":"a1","finish_reason":"stop"}}
{"type":"message","source":"user","payload":{"text":"u2"}}'
CTXDEF=$(printf '%s\n' "$HISTDEF" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXDEF" | jq '.messages | length')" "3" "context: default budget keeps all turns under the limit"

finish
