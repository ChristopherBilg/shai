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

# (later tasks append their sections above this footer)

rm -rf "$STUB"
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}ALL TESTS PASSED${NC}"; else echo -e "${RED}TESTS FAILED${NC}"; exit 1; fi
