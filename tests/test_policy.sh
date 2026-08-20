#!/bin/bash
# test_policy.sh — unit tests for the permission gate policy matcher
# Covers: check_policy in shai-dispatch — policy file parsing, rule matching, fallbacks, overlay
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-dispatch: check_policy"

# The permission gate must be hermetic: a workflow running the suite exports
# SHAI_POLICY_OVERLAY, and an inherited overlay supersedes base rules (including
# deny), flipping deny assertions to allow. lib.sh unsets it centrally; this canary
# fails loudly if the leak ever re-appears.
if [ -n "${SHAI_POLICY_OVERLAY:-}" ]; then
  echo "FATAL: SHAI_POLICY_OVERLAY is set on entry ($SHAI_POLICY_OVERLAY); refusing to run with a leaked overlay" >&2
  exit 1
fi

# Derive read-only tool names from tool.json instead of hardcoding
mapfile -t READ_ONLY_TOOLS < <(
  for tj in "$DIR"/tools/*/tool.json; do
    jq -r 'select(.capabilities.read_only == true) | .name' "$tj"
  done | sort
)
[ "${#READ_ONLY_TOOLS[@]}" -gt 0 ] || {
  echo "FATAL: could not find any read-only tools in tools/*/tool.json" >&2
  exit 1
}

# shai-dispatch runs its dispatch loop at the global scope (no `main` guard), so it can't be
# `source`d directly without also running the loop against stdin. Extract just the function
# definitions -- everything from the top of the file up to (but not including) the loop's
# `tool_calls=0` counter -- and eval them inside a helper. Two isolation layers matter here:
#   - every call site below invokes run_check_policy inside a `$(...)` command substitution,
#     which forks a subshell, so the extracted `set -euo pipefail` can never leak into (or
#     change the behavior of) the rest of this test script;
#   - `SHAI_HOME=... run_check_policy ...` is a prefix assignment scoped to that one call, so
#     it never leaks into the environment either.
# Every test below passes an explicit temp-dir SHAI_HOME, so no test ever touches a real
# ~/.shai or hits the network.
extract_functions() {
  sed -n '1,/^tool_calls=/p' "$DIR/shai-dispatch" | head -n -1
}

run_check_policy() {
  local tool_name="$1" tool_input="$2"
  # shai-dispatch derives DIR from ${BASH_SOURCE[0]}, which under eval resolves to this file's
  # own directory (tests/), not shai-dispatch's — so TOOLS_DIR must be pinned explicitly here to
  # the repo's real tools/ directory; it wins over the eval'd script's own $DIR/tools default.
  # shellcheck disable=SC2034  # consumed by the eval'd shai-dispatch code below, not directly
  local SHAI_TOOLS_DIR="$DIR/tools"
  eval "$(extract_functions)"
  check_policy "$tool_name" "$tool_input"
}

# setup_policy <json>: temp dir containing policy.json with the given (possibly empty or
# malformed) content. Echoes the dir path.
setup_policy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _CLEANUP_DIRS+=("$tmpdir")
  printf '%s' "$1" >"$tmpdir/policy.json"
  printf '%s' "$tmpdir"
}

# empty_home: temp dir with no policy.json at all. Echoes the dir path.
empty_home() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _CLEANUP_DIRS+=("$tmpdir")
  printf '%s' "$tmpdir"
}

# --- no policy file: allow for all read-only tools, prompt for anything else ---
for t in "${READ_ONLY_TOOLS[@]}"; do
  PDIR=$(empty_home)
  RES=$(SHAI_HOME="$PDIR" run_check_policy "$t" '{}')
  assert_eq "$RES" "allow" "no policy file: $t → allow"
done

PDIR=$(empty_home)
RES=$(SHAI_HOME="$PDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "no policy file: non-read-only tool → prompt"

# --- empty policy file: read-only auto-allows, non-read-only prompts ---
PDIR=$(setup_policy '')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "empty policy file: read-only tool → allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "empty policy file: non-read-only tool → prompt"

# regression: whitespace-only is the same failure mode as zero-byte
WSDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$WSDIR")
printf '   \n\t\n' >"$WSDIR/policy.json"
RES=$(SHAI_HOME="$WSDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "whitespace-only policy file: read-only → allow"
RES=$(SHAI_HOME="$WSDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "whitespace-only policy file: non-read-only → prompt"

# --- malformed (non-JSON) policy file: falls back to read-only heuristic ---
PDIR=$(setup_policy 'not json {')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "malformed policy file: read-only → allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "malformed policy file: non-read-only → prompt"

# --- exact tool match ---
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "exact tool match, action allow → allow"

PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"gh","action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "gh" '{}')
assert_eq "$RES" "deny" "exact tool match, action deny → deny"

# --- rule with args: exact match ---
PDIR=$(setup_policy '{"version":"1.0","default":"allow","rules":[{"tool":"print_file","args":{"path":"/etc/passwd"},"action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/etc/passwd"}')
assert_eq "$RES" "deny" "args exact match → matched rule's action"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/etc/other"}')
assert_eq "$RES" "allow" "args exact match: differing value doesn't match → falls to default"

# --- rule with args: glob pattern ---
PDIR=$(setup_policy '{"version":"1.0","default":"allow","rules":[{"tool":"print_file","args":{"path":"/etc/*"},"action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/etc/passwd"}')
assert_eq "$RES" "deny" "args glob match → matched rule's action"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/home/user/file"}')
assert_eq "$RES" "allow" "args glob: non-matching path falls to default"

# --- glob compiler must escape regex-special characters -- only `*` is a wildcard ---
PDIR=$(setup_policy '{"version":"1.0","default":"allow","rules":[{"tool":"print_file","args":{"path":"foo.bar"},"action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"fooXbar"}')
assert_eq "$RES" "allow" "literal '.' must not act as regex any-char (fooXbar doesn't match foo.bar)"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"foo.bar"}')
assert_eq "$RES" "deny" "literal '.' still matches itself exactly"

# --- first-match-wins: rule order, not specificity, decides ---
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","args":{"path":"/tmp/*"},"action":"allow"},{"tool":"print_file","action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/tmp/safe"}')
assert_eq "$RES" "allow" "first-match-wins: specific allow ranked above a broad deny wins"

PDIR2=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","action":"deny"},{"tool":"print_file","args":{"path":"/tmp/*"},"action":"allow"}]}')
RES2=$(SHAI_HOME="$PDIR2" run_check_policy "print_file" '{"path":"/tmp/safe"}')
assert_eq "$RES2" "deny" "first-match-wins: reordering the same two rules flips the result"

# --- no rule matches → falls back to the policy's `default` field ---
PDIR=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"other_tool","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "deny" "no rule matches → policy default field wins"

# --- no rule matches and no `default` field → read-only heuristic ---
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"other_tool","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "no rule matches, no default: read-only → allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "no rule matches, no default: non-read-only → prompt"

# --- hermeticity: the overlay is pinned per call, never inherited from the caller ---
# A workflow running the suite exports SHAI_POLICY_OVERLAY, and overlay rules are
# checked before base rules and supersede them, including deny — so a leaked overlay
# flips the deny assertions above to allow. lib.sh unsets it centrally; these two
# pins cover the overlay-supersedes-deny behaviour on purpose instead of by accident.
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"gh","action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="" run_check_policy "gh" '{}')
assert_eq "$RES" "deny" "hermetic: no overlay (pinned) → base deny still denies"

OVERLAY=$(mktemp)
_CLEANUP_DIRS+=("$OVERLAY")
printf '{"rules":[{"tool":"gh","action":"allow"}]}' >"$OVERLAY"
RES=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="$OVERLAY" run_check_policy "gh" '{}')
assert_eq "$RES" "allow" "hermetic: fixture overlay (pinned) allow supersedes base deny"

# --- overlay: rules checked before base, base still applies for unmatched tools ---

# overlay allows a tool that base denies
ODIR=$(mktemp -d)
_CLEANUP_DIRS+=("$ODIR")
printf '{"rules":[{"tool":"print_file","action":"deny"}]}' >"$ODIR/policy.json"
OVERLAY=$(mktemp)
_CLEANUP_DIRS+=("$OVERLAY")
printf '{"rules":[{"tool":"print_file","action":"allow"}]}' >"$OVERLAY"
RES=$(SHAI_HOME="$ODIR" SHAI_POLICY_OVERLAY="$OVERLAY" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "overlay: overlay allow supersedes base deny"

# overlay doesn't match → falls through to base
ODIR2=$(mktemp -d)
_CLEANUP_DIRS+=("$ODIR2")
printf '{"rules":[{"tool":"list_directory","action":"deny"}]}' >"$ODIR2/policy.json"
OVERLAY2=$(mktemp)
_CLEANUP_DIRS+=("$OVERLAY2")
printf '{"rules":[{"tool":"print_file","action":"allow"}]}' >"$OVERLAY2"
RES=$(SHAI_HOME="$ODIR2" SHAI_POLICY_OVERLAY="$OVERLAY2" run_check_policy "list_directory" '{}')
assert_eq "$RES" "deny" "overlay: unmatched tool falls through to base"

# overlay with no base policy
ODIR3=$(empty_home)
OVERLAY3=$(mktemp)
_CLEANUP_DIRS+=("$OVERLAY3")
printf '{"rules":[{"tool":"gh","action":"allow"}]}' >"$OVERLAY3"
RES=$(SHAI_HOME="$ODIR3" SHAI_POLICY_OVERLAY="$OVERLAY3" run_check_policy "gh" '{}')
assert_eq "$RES" "allow" "overlay: works without base policy file"
RES=$(SHAI_HOME="$ODIR3" SHAI_POLICY_OVERLAY="$OVERLAY3" run_check_policy "other_tool" '{}')
assert_eq "$RES" "prompt" "overlay: unmatched tool with no base → prompt"

# overlay default supersedes base default
ODIR4=$(mktemp -d)
_CLEANUP_DIRS+=("$ODIR4")
printf '{"default":"deny","rules":[]}' >"$ODIR4/policy.json"
OVERLAY4=$(mktemp)
_CLEANUP_DIRS+=("$OVERLAY4")
printf '{"default":"allow","rules":[]}' >"$OVERLAY4"
RES=$(SHAI_HOME="$ODIR4" SHAI_POLICY_OVERLAY="$OVERLAY4" run_check_policy "any_tool" '{}')
assert_eq "$RES" "allow" "overlay: overlay default supersedes base default"

# nonexistent overlay path → ignored, base still works
ODIR5=$(setup_policy '{"rules":[{"tool":"print_file","action":"deny"}]}')
RES=$(SHAI_HOME="$ODIR5" SHAI_POLICY_OVERLAY="/nonexistent/path.json" run_check_policy "print_file" '{}')
assert_eq "$RES" "deny" "overlay: nonexistent overlay path ignored, base applies"

# --- integration: the permission gate wired into run_tool, exercised through the full
#     shai-dispatch pipeline (not the extracted functions) ---

# deny produces is_error tool_result
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"deny"}]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_deny","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "deny → is_error true"
assert_contains "$result" 'Policy denied' "deny → error message"

# non-interactive prompt → fail closed
tmpdir=$(setup_policy '{"version":"1.0","default":"prompt","rules":[]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_prompt","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "non-interactive prompt → is_error true"
assert_contains "$result" 'Permission denied' "non-interactive prompt → denied message"

# allow executes tool normally
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"allow"}]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_allow","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"'"$tmpdir"'\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":false' "allow → executes, is_error false"

finish
