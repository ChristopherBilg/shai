#!/bin/bash
# test_doctor_sync.sh — tests the doctor dependency sync checker
# Covers: tests/doctor-sync.sh — detection of missing deps, pass on full coverage
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "doctor-sync"

# doctor-sync.sh locates its own root via ${BASH_SOURCE[0]}, so fixtures copy the
# script itself into a temp tree alongside a stub shai-doctor and fixture tool.json
# files — the same technique test_prompt.sh uses for shai-prompt.
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/tests" "$FIX/tools/widget"
cp "$DIR/tests/doctor-sync.sh" "$FIX/tests/doctor-sync.sh"
chmod +x "$FIX/tests/doctor-sync.sh"

cat >"$FIX/tools/widget/tool.json" <<'EOF'
{
  "name": "widget",
  "description": "a fixture tool",
  "input_schema": { "type": "object", "properties": {} },
  "capabilities": {
    "read_only": true,
    "requires": {
      "tools": ["widgetcli"],
      "env": [{ "name": "WIDGET_TOKEN", "level": "conditional" }]
    }
  }
}
EOF

stub_doctor() {
  # Writes a fake shai-doctor to $FIX/shai-doctor whose "Tool-declared
  # dependencies:" section only mentions the names passed as args.
  cat >"$FIX/shai-doctor" <<EOF
#!/bin/bash
{
  echo "=== shai-doctor ==="
  echo "Tool-declared dependencies:"
$(for n in "$@"; do echo "  echo '  [OK]   $n'"; done)
} >&2
exit 0
EOF
  chmod +x "$FIX/shai-doctor"
}

# --- fixture: all declared deps covered → pass ---
stub_doctor widgetcli WIDGET_TOKEN
OUT="$(bash "$FIX/tests/doctor-sync.sh" 2>&1)"
assert_eq "$?" "0" "fixture: all deps covered → exit 0"
assert_contains "$OUT" "DOCTOR SYNC OK" "fixture: all deps covered → OK banner"

# --- fixture: missing tool dep → fail ---
stub_doctor WIDGET_TOKEN
OUT="$(bash "$FIX/tests/doctor-sync.sh" 2>&1)"
assert_eq "$?" "1" "fixture: missing tool dep → exit 1"
assert_contains "$OUT" "DOCTOR SYNC FAILED" "fixture: missing tool dep → FAILED banner"
assert_contains "$OUT" "widgetcli" "fixture: missing tool dep → names the tool"
assert_contains "$OUT" "NOT found" "fixture: missing tool dep → NOT found marker"

# --- fixture: missing env dep → fail ---
stub_doctor widgetcli
OUT="$(bash "$FIX/tests/doctor-sync.sh" 2>&1)"
assert_eq "$?" "1" "fixture: missing env dep → exit 1"
assert_contains "$OUT" "DOCTOR SYNC FAILED" "fixture: missing env dep → FAILED banner"
assert_contains "$OUT" "WIDGET_TOKEN" "fixture: missing env dep → names the env var"

# --- fixture: no deps declared → pass ---
cat >"$FIX/tools/widget/tool.json" <<'EOF'
{
  "name": "widget",
  "description": "a fixture tool with no declared deps",
  "input_schema": { "type": "object", "properties": {} }
}
EOF
stub_doctor
OUT="$(bash "$FIX/tests/doctor-sync.sh" 2>&1)"
assert_eq "$?" "0" "fixture: no declared deps → exit 0"
assert_contains "$OUT" "DOCTOR SYNC OK" "fixture: no declared deps → OK banner"

# --- shai-doctor covers all current tool deps → pass ---
OUT="$(bash "$DIR/tests/doctor-sync.sh" 2>&1)"
assert_eq "$?" "0" "live tools: doctor-sync passes"
assert_contains "$OUT" "DOCTOR SYNC OK" "live tools: OK banner"

finish
