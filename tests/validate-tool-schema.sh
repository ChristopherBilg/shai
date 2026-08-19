#!/bin/bash
# Validate aggregated tools from shai-tools against the Anthropic Messages API tool-definition schema.
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

TOOLS=$("$ROOT/shai-tools")

# 1. Valid JSON array
if ! printf '%s' "$TOOLS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  note "aggregated tools is not a valid JSON array"
  exit 1
fi
ok "valid JSON array"

# 2. No duplicate tool names
dupes=$(printf '%s' "$TOOLS" | jq -r '[.[].name] | group_by(.) | map(select(length > 1)) | .[0][0] // empty')
if [ -n "$dupes" ]; then
  note "duplicate tool name: $dupes"
else
  ok "no duplicate tool names"
fi

# 3. Per-tool structural checks
count=$(printf '%s' "$TOOLS" | jq 'length')
for i in $(seq 0 $((count - 1))); do
  name=$(printf '%s' "$TOOLS" | jq -r ".[$i].name // empty")

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
  desc=$(printf '%s' "$TOOLS" | jq -r ".[$i].description // empty")
  if [ -z "$desc" ]; then
    note "$name: missing or empty description"
  else
    ok "$name: has description"
  fi

  # input_schema exists and is an object with type "object"
  schema_type=$(printf '%s' "$TOOLS" | jq -r ".[$i].input_schema.type // empty")
  if [ "$schema_type" != "object" ]; then
    note "$name: input_schema.type must be \"object\" (got \"$schema_type\")"
  else
    ok "$name: input_schema.type is object"
  fi

  # properties exists and is an object
  if ! printf '%s' "$TOOLS" | jq -e ".[$i].input_schema.properties | type == \"object\"" >/dev/null 2>&1; then
    note "$name: input_schema.properties missing or not an object"
    continue
  fi
  ok "$name: has properties object"

  # required exists and is an array of strings
  if ! printf '%s' "$TOOLS" | jq -e ".[$i].input_schema.required | type == \"array\" and all(type == \"string\")" >/dev/null 2>&1; then
    note "$name: input_schema.required missing or not a string array"
  else
    ok "$name: has required array"
  fi

  # every required field exists in properties
  missing=$(printf '%s' "$TOOLS" | jq -r "
    .[$i].input_schema |
    (.required // [])[] as \$r |
    select(.properties[\$r] == null) |
    \$r
  ")
  if [ -n "$missing" ]; then
    note "$name: required field not in properties: $missing"
  else
    ok "$name: all required fields exist in properties"
  fi

  # every property has type and non-empty description
  bad_props=$(printf '%s' "$TOOLS" | jq -r "
    .[$i].input_schema.properties | to_entries[] |
    select(.value.type == null or (.value.description // \"\" | length) == 0) |
    .key
  ")
  if [ -n "$bad_props" ]; then
    note "$name: properties missing type or description: $bad_props"
  else
    ok "$name: all properties have type and description"
  fi
done

# 4. Per-tool capabilities.requires validation (reads raw tool.json, not aggregated)
for tool_dir in "$ROOT"/tools/*/; do
  [ -d "$tool_dir" ] || continue
  tj="$tool_dir/tool.json"
  [ -f "$tj" ] || continue
  tname=$(jq -r '.name' "$tj")

  # requires: must be an object if present
  req_type=$(jq -r '.capabilities.requires | type' "$tj" 2>/dev/null) || req_type="null"
  if [ "$req_type" != "null" ] && [ "$req_type" != "object" ]; then
    note "$tname: capabilities.requires must be an object (got $req_type)"
    continue
  fi

  # requires.tools: must be array of non-empty strings if present
  req_tools_type=$(jq -r '.capabilities.requires.tools | type' "$tj" 2>/dev/null) || req_tools_type="null"
  if [ "$req_tools_type" != "null" ]; then
    if [ "$req_tools_type" != "array" ]; then
      note "$tname: capabilities.requires.tools must be an array (got $req_tools_type)"
    elif ! jq -e '.capabilities.requires.tools | all(type == "string" and length > 0)' "$tj" >/dev/null 2>&1; then
      note "$tname: capabilities.requires.tools entries must be non-empty strings"
    else
      ok "$tname: requires.tools valid"
    fi
  fi

  # requires.env: must be array of {name: string, level: "core"|"conditional"} if present
  req_env_type=$(jq -r '.capabilities.requires.env | type' "$tj" 2>/dev/null) || req_env_type="null"
  if [ "$req_env_type" != "null" ]; then
    if [ "$req_env_type" != "array" ]; then
      note "$tname: capabilities.requires.env must be an array (got $req_env_type)"
    elif ! jq -e '
      .capabilities.requires.env | all(
        (.name | type == "string" and length > 0 and test("^[A-Za-z_][A-Za-z0-9_]*$"))
        and (.level == "core" or .level == "conditional")
      )
    ' "$tj" >/dev/null 2>&1; then
      note "$tname: capabilities.requires.env entries must have name (valid shell identifier) and level (core|conditional)"
    else
      ok "$tname: requires.env valid"
    fi
  fi

  # requires.files: must be array of {path, level: core|conditional} with optional
  # format ("json"), keys (top-level object whose keys shai-doctor lists), hint (fix advice)
  req_files_type=$(jq -r '.capabilities.requires.files | type' "$tj" 2>/dev/null) || req_files_type="null"
  if [ "$req_files_type" != "null" ]; then
    if [ "$req_files_type" != "array" ]; then
      note "$tname: capabilities.requires.files must be an array (got $req_files_type)"
    elif ! jq -e '
      .capabilities.requires.files | all(
        (.path | type == "string" and length > 0)
        and (.level == "core" or .level == "conditional")
        and ((.format // "json") == "json")
        and ((.keys // "unset") | type == "string" and length > 0)
        and ((.hint // "unset") | type == "string" and length > 0)
      )
    ' "$tj" >/dev/null 2>&1; then
      note "$tname: capabilities.requires.files entries must have path (non-empty string) and level (core|conditional), with optional format (\"json\"), keys, hint non-empty strings"
    else
      ok "$tname: requires.files valid"
    fi
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
