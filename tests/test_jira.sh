#!/bin/bash
# test_jira.sh — unit tests for tools/jira/run.sh, the jira CLI tool plugin
# Covers: tools/jira/run.sh — argv passthrough (no -- guard), NUL-safe framing, empty-args
#   guard, timeout 120s wrapper; dispatch contract — exit 1, tool_result with tool_call_id,
#   is_error, external_data fencing with source="jira"
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools/jira/run.sh"

TOOL="$DIR/tools/jira/run.sh"

make_stub_bin
write_jira_stub

# jira is capabilities.read_only:false, so the read-only heuristic in shai-dispatch does not
# auto-allow it; the dispatch-level cases below need a permissive policy, exactly like the
# gh/git cases in test_dispatch.sh.
WRITE_HOME=$(mktemp -d)
_CLEANUP_DIRS+=("$WRITE_HOME")
printf '{"version":"1.0","default":"allow","rules":[]}' >"$WRITE_HOME/policy.json"

# --- run.sh: happy path — the args array arrives at jira as distinct argv entries ---
RUNOUT=$("$TOOL" '{"args":["issue","list"]}')
RUNRC=$?
assert_eq "$RUNRC" "0" "run.sh: jira issue list → exit 0"
assert_contains "$RUNOUT" 'stub jira output for: issue list' "run.sh: args passed to jira as argv"

# --- run.sh: empty-args guard (mutation target — dropping the guard must fail this) ---
assert_exit 1 "run.sh: empty args → exit 1" -- "$TOOL" '{"args":[]}'
EMPTYOUT=$("$TOOL" '{"args":[]}' 2>&1) || true
assert_contains "$EMPTYOUT" 'must not be empty' "run.sh: empty args → clear message"

# --- dispatch: happy path (#267 test 1) — exit 1, tool_result, tool_call_id, stub args ---
JIRATOOL='{"type":"message","source":"assistant","payload":{"content":null,"tool_calls":[{"id":"jt1","type":"function","function":{"name":"jira","arguments":"{\"args\":[\"issue\",\"list\"]}"}}],"finish_reason":"tool_calls"}}'
DOUT=$(echo "$JIRATOOL" | SHAI_HOME="$WRITE_HOME" "$DIR/shai-dispatch")
DRC=$?
assert_eq "$DRC" "1" "dispatch: jira issue list → exit 1 (tool ran)"
assert_contains "$DOUT" '"type":"tool_result"' "dispatch: emits tool_result"
assert_contains "$DOUT" '"tool_call_id":"jt1"' "dispatch: tool_call_id echoed"
assert_contains "$DOUT" 'stub jira output for: issue list' "dispatch: stub received the arguments"
assert_eq "$(printf '%s' "$DOUT" | jq -r '.payload.is_error')" "false" "dispatch: jira success → is_error false"

# --- dispatch: args passthrough (#267 test 2) — model-supplied --plain arrives as-is,
#     no `--` guard inserted before the args ---
PLAINTOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"jp1",type:"function",function:{name:"jira",arguments:({args:["issue","list","--plain"]}|tojson)}}],finish_reason:"tool_calls"}}')
PLAINOUT=$(echo "$PLAINTOOL" | SHAI_HOME="$WRITE_HOME" "$DIR/shai-dispatch")
assert_contains "$PLAINOUT" 'stub jira output for: issue list --plain' "dispatch: --plain passed through as-is"
if [[ "$PLAINOUT" == *'-- issue'* ]]; then
  echo -e "  ${RED}✗${NC} dispatch: a -- guard was inserted before the args"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} dispatch: no -- guard inserted"
fi

# --- dispatch: empty args (#267 test 3) — is_error with a clear message ---
EMPTYTOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"je1",type:"function",function:{name:"jira",arguments:({args:[]}|tojson)}}],finish_reason:"tool_calls"}}')
EMPTYOUT=$(echo "$EMPTYTOOL" | SHAI_HOME="$WRITE_HOME" "$DIR/shai-dispatch") || true
assert_contains "$EMPTYOUT" '"is_error":true' "dispatch: jira empty args → is_error true"
assert_contains "$EMPTYOUT" 'must not be empty' "dispatch: jira empty args → clear message"

# --- dispatch: external data fencing (#267 test 4) — tool_result fenced with the tool name ---
assert_contains "$DOUT" '<external_data source=\"jira\">' "dispatch: tool_result fenced with source=\"jira\""
assert_contains "$DOUT" '</external_data>' "dispatch: tool_result has a closing fence tag"

# --- dispatch: timeout wrapper (#267 test 5) — run.sh must invoke `timeout 120s jira ...`.
#     A timeout stub records its argv (proving the wrapper) and then execs the wrapped
#     command so the jira stub still produces the tool output. ---
write_timeout_stub() {
  cat >"$STUB/timeout" <<STUBEOF
#!/bin/bash
printf '%s\n' "\$*" >"$STUB/timeout.args"
shift
exec "\$@"
STUBEOF
  chmod +x "$STUB/timeout"
}
write_timeout_stub
TOUT=$(echo "$JIRATOOL" | SHAI_HOME="$WRITE_HOME" "$DIR/shai-dispatch")
assert_eq "$(cat "$STUB/timeout.args")" "120s jira issue list" "dispatch: jira invoked under timeout 120s"
assert_contains "$TOUT" 'stub jira output for: issue list' "dispatch: timeout stub still runs the jira stub"

# --- run.sh: NUL-safe framing — an argument containing a newline is one argv entry, not
#     silently split in two (the NUL-delimited mapfile framing, not newline-delimited jq) ---
write_argc_stub() {
  cat >"$STUB/jira" <<'STUBEOF'
#!/bin/bash
echo "argc=$#"
for a in "$@"; do printf 'arg=<%s>\n' "$a"; done
STUBEOF
  chmod +x "$STUB/jira"
}
write_argc_stub
NLTOOL=$(jq -nc '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"jn1",type:"function",function:{name:"jira",arguments:({args:["issue","list","line1\nline2"]}|tojson)}}],finish_reason:"tool_calls"}}')
NLOUT=$(echo "$NLTOOL" | SHAI_HOME="$WRITE_HOME" "$DIR/shai-dispatch")
assert_contains "$NLOUT" 'argc=3' "run.sh: three args arrive as three argv entries"
assert_contains "$NLOUT" 'arg=<line1' "run.sh: newline arg starts intact"
assert_contains "$NLOUT" 'line2>' "run.sh: newline arg arrives whole (not split by framing)"

finish
