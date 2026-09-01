#!/bin/bash
# test_tools.sh — unit tests for shai-tools
# Covers: shai-tools — plugin scanning, JSON-parse and required-field validation,
#         name/run.sh/executable/capabilities validation, aggregation, capabilities stripping
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
  "parameters": {
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
assert_contains "$OUT" '"function"' "tools: output contains function wrapper"
assert_contains "$OUT" '"parameters"' "tools: output contains parameters"

# --- capabilities stripped but schema preserved ---
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].type')" "function" "tools: type is function"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].function.name')" "fake_tool" "tools: name preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].function.description')" "A fake tool for testing." "tools: description preserved"

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
OUT=$("$DIR/shai-tools" "$MDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: missing tool.json exits 1"
assert_contains "$OUT" "broken/tool.json not found" "tools: missing tool.json reports not found"

# --- tool.json is not valid JSON ---
JDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$JDIR")
mkdir -p "$JDIR/tools/badjson"
printf '{ "name": ' >"$JDIR/tools/badjson/tool.json"
cat >"$JDIR/tools/badjson/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$JDIR/tools/badjson/run.sh"
OUT=$("$DIR/shai-tools" "$JDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: invalid tool.json exits 1"
assert_contains "$OUT" "badjson/tool.json is not valid JSON" "tools: invalid tool.json reports not valid JSON"

# --- missing required field: one case per field, each must name the right field ---
for field in name description parameters; do
  REQDIR=$(mktemp -d)
  _CLEANUP_DIRS+=("$REQDIR")
  mkdir -p "$REQDIR/tools/no_${field}"
  jq -nc --arg f "$field" \
    '{name:("no_"+$f), description:"Missing required field fixture.", parameters:{type:"object",properties:{},required:[]}} | del(.[$f])' \
    >"$REQDIR/tools/no_${field}/tool.json"
  cat >"$REQDIR/tools/no_${field}/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
  chmod +x "$REQDIR/tools/no_${field}/run.sh"
  OUT=$("$DIR/shai-tools" "$REQDIR/tools" 2>&1) && rc=0 || rc=$?
  assert_eq "$rc" "1" "tools: missing required field $field exits 1"
  assert_contains "$OUT" "no_${field}/tool.json missing required field: ${field}" \
    "tools: missing required field $field names the field"
done

# --- invalid JSON that is also missing fields: the parse error must win ---
ODIR=$(mktemp -d)
_CLEANUP_DIRS+=("$ODIR")
mkdir -p "$ODIR/tools/badorder"
printf '{ "name": ' >"$ODIR/tools/badorder/tool.json"
cat >"$ODIR/tools/badorder/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$ODIR/tools/badorder/run.sh"
OUT=$("$DIR/shai-tools" "$ODIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: invalid JSON + missing fields exits 1"
assert_contains "$OUT" "badorder/tool.json is not valid JSON" "tools: invalid JSON + missing fields reports parse error"
assert_not_contains "$OUT" "missing required field" \
  "tools: parse error precedes field validation"

# --- missing run.sh ---
RDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$RDIR")
mkdir -p "$RDIR/tools/norush"
cat >"$RDIR/tools/norush/tool.json" <<'JSON'
{
  "name": "norush",
  "description": "Missing run.sh.",
  "capabilities": { "read_only": true },
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
JSON
OUT=$("$DIR/shai-tools" "$RDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: missing run.sh exits 1"
assert_contains "$OUT" "norush/run.sh not found" "tools: missing run.sh reports not found"

# --- non-executable run.sh ---
XDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$XDIR")
mkdir -p "$XDIR/tools/noexec"
cat >"$XDIR/tools/noexec/tool.json" <<'JSON'
{
  "name": "noexec",
  "description": "Non-executable run.sh.",
  "capabilities": { "read_only": true },
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$XDIR/tools/noexec/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
# deliberately NOT chmod +x
OUT=$("$DIR/shai-tools" "$XDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: non-executable run.sh exits 1"
assert_contains "$OUT" "noexec/run.sh is not executable" "tools: non-executable run.sh reports not executable"

# --- name mismatch ---
NDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$NDIR")
mkdir -p "$NDIR/tools/dir_name"
cat >"$NDIR/tools/dir_name/tool.json" <<'JSON'
{
  "name": "wrong_name",
  "description": "Name mismatch.",
  "capabilities": { "read_only": true },
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$NDIR/tools/dir_name/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$NDIR/tools/dir_name/run.sh"
OUT=$("$DIR/shai-tools" "$NDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: name mismatch exits 1"
assert_contains "$OUT" 'dir_name/tool.json name "wrong_name" does not match directory name' \
  "tools: name mismatch reports the mismatched name"

# --- invalid capabilities (non-object) ---
CDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$CDIR")
mkdir -p "$CDIR/tools/badcap"
cat >"$CDIR/tools/badcap/tool.json" <<'JSON'
{
  "name": "badcap",
  "description": "Bad capabilities.",
  "capabilities": "not_an_object",
  "parameters": { "type": "object", "properties": {}, "required": [] }
}
JSON
cat >"$CDIR/tools/badcap/run.sh" <<'SH'
#!/bin/bash
set -euo pipefail
echo "ok"
SH
chmod +x "$CDIR/tools/badcap/run.sh"
OUT=$("$DIR/shai-tools" "$CDIR/tools" 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "tools: invalid capabilities exits 1"
assert_contains "$OUT" "badcap/tool.json capabilities must be an object (got string)" \
  "tools: invalid capabilities reports non-object capabilities"

# --- multiple valid plugins ---
MLTDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$MLTDIR")
for t in alpha beta; do
  mkdir -p "$MLTDIR/tools/$t"
  jq -nc --arg n "$t" '{name:$n, description:("Tool " + $n + "."), capabilities:{read_only:true}, parameters:{type:"object",properties:{},required:[]}}' >"$MLTDIR/tools/$t/tool.json"
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
  "parameters": { "type": "object", "properties": {}, "required": [] }
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
