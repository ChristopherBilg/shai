#!/bin/bash
# test_tools.sh — unit tests for shai-tools
# Covers: shai-tools — plugin scanning, validation, aggregation, capabilities stripping
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-tools"

# --- valid plugin directory ---
TDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TDIR")
mkdir -p "$TDIR/tools/fake_tool"
cat >"$TDIR/tools/fake_tool/tool.json" <<'JSON'
{
  "name": "fake_tool",
  "description": "A fake tool for testing.",
  "capabilities": { "read_only": true },
  "input_schema": {
    "type": "object",
    "properties": {
      "arg": { "type": "string", "description": "An argument." }
    },
    "required": ["arg"]
  }
}
JSON
cat >"$TDIR/tools/fake_tool/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$TDIR/tools/fake_tool/run.sh"

OUT=$("$DIR/shai-tools" "$TDIR/tools")
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "tools: valid plugin produces array of length 1"
assert_contains "$OUT" '"fake_tool"' "tools: output contains tool name"
assert_eq "$(printf '%s' "$OUT" | jq '.[0] | has("capabilities")')" "false" "tools: capabilities stripped from output"
assert_contains "$OUT" '"input_schema"' "tools: output contains input_schema"

# --- capabilities stripped but schema preserved ---
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].name')" "fake_tool" "tools: name preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].description')" "A fake tool for testing." "tools: description preserved"

# --- empty tools directory ---
EDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$EDIR")
mkdir -p "$EDIR/tools"
EOUT=$("$DIR/shai-tools" "$EDIR/tools")
assert_eq "$EOUT" "[]" "tools: empty dir produces []"

# --- missing tool.json ---
MDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$MDIR")
mkdir -p "$MDIR/tools/broken"
cat >"$MDIR/tools/broken/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$MDIR/tools/broken/run.sh"
if "$DIR/shai-tools" "$MDIR/tools" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} tools: missing tool.json should fail"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} tools: missing tool.json fails with non-zero exit"
fi

# --- missing run.sh ---
RDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$RDIR")
mkdir -p "$RDIR/tools/norush"
cat >"$RDIR/tools/norush/tool.json" <<'JSON'
{
  "name": "norush",
  "description": "Missing run.sh.",
  "capabilities": { "read_only": true },
  "input_schema": { "type": "object", "properties": {}, "required": [] }
}
JSON
if "$DIR/shai-tools" "$RDIR/tools" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} tools: missing run.sh should fail"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} tools: missing run.sh fails with non-zero exit"
fi

# --- non-executable run.sh ---
XDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$XDIR")
mkdir -p "$XDIR/tools/noexec"
cat >"$XDIR/tools/noexec/tool.json" <<'JSON'
{
  "name": "noexec",
  "description": "Non-executable run.sh.",
  "capabilities": { "read_only": true },
  "input_schema": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$XDIR/tools/noexec/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
# deliberately NOT chmod +x
if "$DIR/shai-tools" "$XDIR/tools" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} tools: non-executable run.sh should fail"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} tools: non-executable run.sh fails with non-zero exit"
fi

# --- name mismatch ---
NDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$NDIR")
mkdir -p "$NDIR/tools/dir_name"
cat >"$NDIR/tools/dir_name/tool.json" <<'JSON'
{
  "name": "wrong_name",
  "description": "Name mismatch.",
  "capabilities": { "read_only": true },
  "input_schema": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$NDIR/tools/dir_name/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$NDIR/tools/dir_name/run.sh"
if "$DIR/shai-tools" "$NDIR/tools" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} tools: name mismatch should fail"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} tools: name mismatch fails with non-zero exit"
fi

# --- invalid capabilities (non-object) ---
CDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$CDIR")
mkdir -p "$CDIR/tools/badcap"
cat >"$CDIR/tools/badcap/tool.json" <<'JSON'
{
  "name": "badcap",
  "description": "Bad capabilities.",
  "capabilities": "not_an_object",
  "input_schema": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$CDIR/tools/badcap/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$CDIR/tools/badcap/run.sh"
if "$DIR/shai-tools" "$CDIR/tools" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} tools: invalid capabilities should fail"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} tools: invalid capabilities (non-object) fails with non-zero exit"
fi

# --- multiple valid plugins ---
MLTDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$MLTDIR")
for t in alpha beta; do
  mkdir -p "$MLTDIR/tools/$t"
  jq -nc --arg n "$t" '{name:$n, description:("Tool " + $n + "."), capabilities:{read_only:true}, input_schema:{type:"object",properties:{},required:[]}}' >"$MLTDIR/tools/$t/tool.json"
  printf '#!/bin/bash\nset -euo pipefail\necho "ok"\n' >"$MLTDIR/tools/$t/run.sh"
  chmod +x "$MLTDIR/tools/$t/run.sh"
done
MLTOUT=$("$DIR/shai-tools" "$MLTDIR/tools")
assert_eq "$(printf '%s' "$MLTOUT" | jq 'length')" "2" "tools: multiple plugins produces array of length 2"

# --- tool.json without capabilities field (should default, not fail) ---
NCDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$NCDIR")
mkdir -p "$NCDIR/tools/nocap"
cat >"$NCDIR/tools/nocap/tool.json" <<'JSON'
{
  "name": "nocap",
  "description": "No capabilities field.",
  "input_schema": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$NCDIR/tools/nocap/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$NCDIR/tools/nocap/run.sh"
NCOUT=$("$DIR/shai-tools" "$NCDIR/tools")
assert_eq "$(printf '%s' "$NCOUT" | jq 'length')" "1" "tools: missing capabilities does not fail"
assert_eq "$(printf '%s' "$NCOUT" | jq '.[0] | has("capabilities")')" "false" "tools: missing capabilities still stripped"

finish
