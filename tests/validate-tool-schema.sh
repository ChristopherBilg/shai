#!/bin/bash
# Validate tools.json against the Anthropic Messages API tool-definition schema.
# Usage: ./tests/validate-tool-schema.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
fail=0
note() {
  echo -e "  ${RED}✗${NC} $1"
  fail=1
}
ok() { echo -e "  ${GREEN}✓${NC} $1"; }

TOOLS="$ROOT/tools.json"

# 1. Valid JSON array
if ! jq -e 'type == "array"' "$TOOLS" >/dev/null 2>&1; then
  note "tools.json is not a valid JSON array"
  exit 1
fi
ok "valid JSON array"

# 2. No duplicate tool names
dupes=$(jq -r '[.[].name] | group_by(.) | map(select(length > 1)) | .[0][0] // empty' "$TOOLS")
if [ -n "$dupes" ]; then
  note "duplicate tool name: $dupes"
else
  ok "no duplicate tool names"
fi

# 3. Per-tool structural checks
count=$(jq 'length' "$TOOLS")
for i in $(seq 0 $((count - 1))); do
  name=$(jq -r ".[$i].name // empty" "$TOOLS")

  # name exists and matches Anthropic's pattern
  if [ -z "$name" ]; then
    note "tool[$i]: missing name"
    continue
  fi
  if ! echo "$name" | grep -qE '^[a-zA-Z0-9_-]{1,64}$'; then
    note "$name: name must match [a-zA-Z0-9_-]{1,64}"
  else
    ok "$name: valid name"
  fi

  # description exists and is non-empty
  desc=$(jq -r ".[$i].description // empty" "$TOOLS")
  if [ -z "$desc" ]; then
    note "$name: missing or empty description"
  else
    ok "$name: has description"
  fi

  # input_schema exists and is an object with type "object"
  schema_type=$(jq -r ".[$i].input_schema.type // empty" "$TOOLS")
  if [ "$schema_type" != "object" ]; then
    note "$name: input_schema.type must be \"object\" (got \"$schema_type\")"
  else
    ok "$name: input_schema.type is object"
  fi

  # properties exists and is an object
  if ! jq -e ".[$i].input_schema.properties | type == \"object\"" "$TOOLS" >/dev/null 2>&1; then
    note "$name: input_schema.properties missing or not an object"
    continue
  fi
  ok "$name: has properties object"

  # required exists and is an array of strings
  if ! jq -e ".[$i].input_schema.required | type == \"array\" and all(type == \"string\")" "$TOOLS" >/dev/null 2>&1; then
    note "$name: input_schema.required missing or not a string array"
  else
    ok "$name: has required array"
  fi

  # every required field exists in properties
  missing=$(jq -r "
    .[$i].input_schema |
    (.required // [])[] as \$r |
    select(.properties[\$r] == null) |
    \$r
  " "$TOOLS")
  if [ -n "$missing" ]; then
    note "$name: required field not in properties: $missing"
  else
    ok "$name: all required fields exist in properties"
  fi

  # every property has type and non-empty description
  bad_props=$(jq -r "
    .[$i].input_schema.properties | to_entries[] |
    select(.value.type == null or (.value.description // \"\" | length) == 0) |
    .key
  " "$TOOLS")
  if [ -n "$bad_props" ]; then
    note "$name: properties missing type or description: $bad_props"
  else
    ok "$name: all properties have type and description"
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}TOOL SCHEMA OK${NC}"
  exit 0
else
  echo -e "${RED}TOOL SCHEMA FAILED${NC}"
  exit 1
fi
