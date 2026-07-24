#!/bin/bash
set -uo pipefail   # no -e: run every assertion even if one fails

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
DIR="$(cd "$TESTS_DIR/.." &> /dev/null && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
FAILED=0

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then echo -e "  ${GREEN}✓${NC} $3"
  else echo -e "  ${RED}✗${NC} $3"; echo "    expected substring: $2"; echo "    got: $1"; FAILED=1; fi
}
assert_eq() {
  if [ "$1" = "$2" ]; then echo -e "  ${GREEN}✓${NC} $3"
  else echo -e "  ${RED}✗${NC} $3 (got '$1', want '$2')"; FAILED=1; fi
}

# --- offline stubs: fake curl + gh on PATH ---
STUB=$(mktemp -d)
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
echo "stub gh output for: $*"
EOF
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null   # drain the -d @- payload so the producer never gets SIGPIPE
cat <<'JSON'
{"type":"message","content":[{"type":"text","text":"stub reply"}],"stop_reason":"end_turn"}
JSON
echo "200"         # emulate shai-eval's -w '\n%{http_code}'
EOF
chmod +x "$STUB/gh" "$STUB/curl"
export PATH="$STUB:$PATH"
export ANTHROPIC_API_KEY="test-key"

echo "Testing shai-read..."
OUT=$(echo "Hello shai" | "$DIR/shai-read")
assert_contains "$OUT" '"type":"message"' "read: envelope"
assert_contains "$OUT" '"source":"user"' "read: user source"
assert_contains "$OUT" '"text":"Hello shai"' "read: payload text"
SYSOUT=$(echo "sys prompt" | "$DIR/shai-read" --system)
assert_contains "$SYSOUT" '"source":"system"' "read: --system source"
EMPTY=$(printf '' | "$DIR/shai-read"); RC=$?
assert_eq "$EMPTY" "" "read: empty input → empty"
assert_eq "$RC" "0" "read: empty input → exit 0"

echo "Testing shai-context..."
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

echo "Testing shai-eval..."
DRY=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run --tools)
assert_contains "$DRY" '"model":"claude-opus-4-8"' "eval: default model"
assert_contains "$DRY" '"max_tokens":16000' "eval: default max_tokens"
assert_contains "$DRY" '"gh_pr_view"' "eval: tools.json included with --tools"
NOTOOLS=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$NOTOOLS" | jq 'has("tools")')" "false" "eval: no tools without --tools"
EV=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV" '"source":"assistant"' "eval: assistant event (stubbed curl)"
assert_contains "$EV" '"stop_reason":"end_turn"' "eval: stop_reason parsed"
assert_contains "$EV" 'stub reply' "eval: content passed through"
env -u ANTHROPIC_API_KEY "$DIR/shai-eval" --health-check 2>/dev/null; assert_eq "$?" "1" "eval: health-check fails without key"
"$DIR/shai-eval" --health-check; assert_eq "$?" "0" "eval: health-check ok with key"

# error-path coverage: temporarily shadow curl with stubs returning non-200 / bad bodies
ESTUB=$(mktemp -d)
cat > "$ESTUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"type":"error","error":{"message":"overloaded"}}'
echo "529"
EOF
chmod +x "$ESTUB/curl"
EVERR=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | PATH="$ESTUB:$PATH" "$DIR/shai-eval")
assert_contains "$EVERR" '"type":"error"' "eval: non-200 JSON body → error event"
assert_contains "$EVERR" 'overloaded' "eval: error message extracted"

cat > "$ESTUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '<html>502 Bad Gateway</html>'
echo "502"
EOF
EVHTML=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | PATH="$ESTUB:$PATH" "$DIR/shai-eval")
assert_contains "$EVHTML" '"type":"error"' "eval: non-200 non-JSON body → error event (no crash)"
assert_contains "$EVHTML" 'HTTP 502' "eval: non-JSON error falls back to HTTP code"

cat > "$ESTUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"type":"error","error":{"message":"bad-200-body"}}'
echo "200"
EOF
EV200=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | PATH="$ESTUB:$PATH" "$DIR/shai-eval")
assert_contains "$EV200" '"type":"error"' "eval: 200 body with type=error → error event"

cat > "$ESTUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null
echo 'totally not json'
echo "200"
EOF
EV200BAD=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | PATH="$ESTUB:$PATH" "$DIR/shai-eval")
assert_contains "$EV200BAD" '"type":"error"' "eval: 200 non-JSON body → error event (no crash)"

cat > "$ESTUB/curl" <<'EOF'
#!/bin/bash
cat > /dev/null
echo '{"foo":"bar"}'
echo "200"
EOF
EV200SHAPE=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | PATH="$ESTUB:$PATH" "$DIR/shai-eval")
assert_contains "$EV200SHAPE" '"type":"error"' "eval: 200 unexpected shape → error event (not fake success)"
rm -rf "$ESTUB"

echo "Testing shai-dispatch..."
NOTOOL='{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}'
echo "$NOTOOL" | "$DIR/shai-dispatch" >/dev/null; assert_eq "$?" "0" "dispatch: no-tool exit 0"
TOOL='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"gh_pr_view","input":{"number":"123"}}],"stop_reason":"tool_use"}}'
DOUT=$(echo "$TOOL" | "$DIR/shai-dispatch"); DRC=$?
assert_eq "$DRC" "1" "dispatch: tool exit 1"
assert_contains "$DOUT" '"type":"tool_result"' "dispatch: emits tool_result"
assert_contains "$DOUT" '"tool_use_id":"t1"' "dispatch: tool_use_id echoed"
assert_contains "$DOUT" 'stub gh output' "dispatch: ran stubbed gh"
UNK='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t9","name":"nope","input":{}}],"stop_reason":"tool_use"}}'
UOUT=$(echo "$UNK" | "$DIR/shai-dispatch") || true
assert_contains "$UOUT" '"is_error":true' "dispatch: unknown tool → is_error"

# truncation path: output > 8000 bytes must still emit a tool_result (SIGPIPE-safe)
BIGFILE=$(mktemp)
head -c 200000 /dev/zero | tr '\0' 'x' > "$BIGFILE"
BIGTOOL=$(jq -nc --arg p "$BIGFILE" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"tb",name:"print_file",input:{path:$p}}],stop_reason:"tool_use"}}')
BOUT=$(echo "$BIGTOOL" | "$DIR/shai-dispatch"); BRC=$?
assert_eq "$BRC" "1" "dispatch: large output still exits 1 (no SIGPIPE crash)"
assert_contains "$BOUT" '"type":"tool_result"' "dispatch: large output emits tool_result"
assert_eq "$(printf '%s' "$BOUT" | jq -r '.payload.content | length')" "8000" "dispatch: output truncated to 8000 bytes"
rm -f "$BIGFILE"

NTOUT=$(echo "$NOTOOL" | "$DIR/shai-dispatch")
assert_eq "$NTOUT" "" "dispatch: no-tool produces no output"

MULTI='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"m1","name":"list_directory","input":{"path":"."}},{"type":"tool_use","id":"m2","name":"print_file","input":{"path":"tools.json"}}],"stop_reason":"tool_use"}}'
MOUT=$(echo "$MULTI" | "$DIR/shai-dispatch"); MRC=$?
assert_eq "$MRC" "1" "dispatch: multiple tool_use → exit 1"
assert_eq "$(printf '%s' "$MOUT" | jq -s 'length')" "2" "dispatch: multiple tool_use → two tool_results"
assert_contains "$MOUT" '"tool_use_id":"m1"' "dispatch: first tool_use_id echoed"
assert_contains "$MOUT" '"tool_use_id":"m2"' "dispatch: second tool_use_id echoed"

# regression: backslash in a path must survive (no @tsv double-escaping)
SPDIR=$(mktemp -d)
BSNAME='a\b'
printf 'PASSTHRU_OK' > "$SPDIR/$BSNAME"
SPTOOL=$(jq -nc --arg p "$SPDIR/$BSNAME" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"sp",name:"print_file",input:{path:$p}}],stop_reason:"tool_use"}}')
SPOUT=$(echo "$SPTOOL" | "$DIR/shai-dispatch")
assert_contains "$SPOUT" 'PASSTHRU_OK' "dispatch: backslash path survives input passthrough"
rm -rf "$SPDIR"

# regression: a model-supplied number like --web must be positional, not a gh flag
INJ='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"inj","name":"gh_pr_view","input":{"number":"--web"}}],"stop_reason":"tool_use"}}'
IOUT=$(echo "$INJ" | "$DIR/shai-dispatch")
assert_contains "$IOUT" 'stub gh output for: pr view -- --web' "dispatch: gh number is positional (-- guards option injection)"

echo "Testing shai-print..."
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

# (later tasks append their sections above this footer)

rm -rf "$STUB"
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}ALL TESTS PASSED${NC}"; else echo -e "${RED}TESTS FAILED${NC}"; exit 1; fi
