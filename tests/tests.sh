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
EMPTY=$(printf '' | "$DIR/shai-read"); assert_eq "$EMPTY" "" "read: empty input → empty"

# (later tasks append their sections above this footer)

rm -rf "$STUB"
if [ "$FAILED" -eq 0 ]; then echo -e "${GREEN}ALL TESTS PASSED${NC}"; else echo -e "${RED}TESTS FAILED${NC}"; exit 1; fi
