# Task 3: prompt_user + gate in run_tool

**Goal:** Wire the permission gate into `run_tool` — call `check_policy`, handle `prompt`/`deny` actions, and integrate `prompt_user` for interactive approval.

**Files:**
- Modify: `shai-dispatch` (add `prompt_user` function after `check_policy`; modify `run_tool` to insert gate before tool `case` block)
- Modify: `tests/test_policy.sh` (add integration tests for deny/prompt producing `tool_result` events)

**Acceptance Criteria:**
- [ ] `prompt_user` renders tool name and args to `/dev/tty` and reads Y/N
- [ ] `prompt_user` defaults to N (deny) on empty input
- [ ] `run_tool` calls `check_policy` before the tool `case` block
- [ ] `allow` action proceeds to execution unchanged
- [ ] `deny` action prints error message and returns 1 without executing the tool
- [ ] `prompt` + interactive (`[ -t 2 ]`) + user types y/Y → executes
- [ ] `prompt` + interactive + user types n/N/empty → returns 1
- [ ] `prompt` + non-interactive → returns 1 (fail closed)
- [ ] Denied/failed-closed tool calls produce well-formed `tool_result` JSON events with `is_error: true`
- [ ] Existing `tests/test_dispatch.sh` still passes (backward compat: no policy file + read-only tools = `allow`)

**Verify:** `bash tests/test_policy.sh && ./tests/run.sh` → all pass

## Current State of shai-dispatch

`check_policy` is already at lines 13-44. `run_tool` starts at line 46. The dispatch loop starts at line 74.

## Implementation — prompt_user function

Insert after `check_policy` (after line 44), before `run_tool`:

```bash
prompt_user() {
  local tool_name="$1" tool_input="$2"
  if ! [ -t 2 ]; then
    return 1
  fi
  printf '\n⚠ shai wants to execute:\n' >/dev/tty
  printf '  tool:  %s\n' "$tool_name" >/dev/tty
  printf '%s' "$tool_input" | jq -r 'to_entries[] | "  \(.key):  \(.value)"' >/dev/tty 2>/dev/null
  printf '\n  Allow? [y/N] ' >/dev/tty
  local answer
  read -r answer </dev/tty 2>/dev/null || answer=""
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) return 1 ;;
  esac
}
```

## Implementation — gate in run_tool

Replace the current `run_tool` function header (lines 46-47) to insert the gate:

```bash
run_tool() {
  local name="$1" input="$2"
  local policy_action
  policy_action=$(check_policy "$name" "$input")
  case "$policy_action" in
    allow) ;;
    deny)
      printf 'Policy denied: %s' "$name"
      return 1
      ;;
    prompt)
      if ! prompt_user "$name" "$input"; then
        printf 'Permission denied: %s' "$name"
        return 1
      fi
      ;;
  esac
  local number repo path
  case "$name" in
```

The rest of `run_tool` (the tool `case` branches starting with `gh_pr_view`) stays unchanged.

## Integration Tests to Add to tests/test_policy.sh

Add these tests before the `finish` call:

### deny produces is_error tool_result
```bash
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"deny"}]}')
stub_dir=$(make_stub_bin)
write_gh_stub "$stub_dir"
event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_deny","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "deny → is_error true"
assert_contains "$result" 'Policy denied' "deny → error message"
```

### non-interactive prompt → fail closed
```bash
tmpdir=$(setup_policy '{"version":"1.0","default":"prompt","rules":[]}')
stub_dir=$(make_stub_bin)
write_gh_stub "$stub_dir"
event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_prompt","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "non-interactive prompt → is_error true"
assert_contains "$result" 'Permission denied' "non-interactive prompt → denied message"
```

### allow executes tool normally
```bash
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"allow"}]}')
stub_dir=$(make_stub_bin)
write_gh_stub "$stub_dir"
event='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"test_allow","name":"list_directory","input":{"path":"'"$tmpdir"'"}}],"stop_reason":"tool_use"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":false' "allow → executes, is_error false"
```

## Critical: Backward Compatibility

Existing `test_dispatch.sh` tests run WITHOUT a policy file. `check_policy` already returns `allow` for the 4 built-in read-only tools when no policy file exists (implemented in Task 1). So existing tests should pass unchanged. **Verify this by running `./tests/run.sh` after making changes.**
