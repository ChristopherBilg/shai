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
  local tool_name="$1" tool_input="$2" out
  # shai-dispatch derives DIR from ${BASH_SOURCE[0]}, which under eval resolves to this file's
  # own directory (tests/), not shai-dispatch's — so TOOLS_DIR must be pinned explicitly here to
  # the repo's real tools/ directory; it wins over the eval'd script's own $DIR/tools default.
  # shellcheck disable=SC2034  # consumed by the eval'd shai-dispatch code below, not directly
  local SHAI_TOOLS_DIR="$DIR/tools"
  eval "$(extract_functions)"
  out=$(check_policy "$tool_name" "$tool_input")
  # check_policy returns "<action>\t<reason>" (issue #116) so denials can name their cause; the
  # existing assertions below check the bare action, so strip the reason here. The full line is
  # exercised through run_check_policy_raw.
  printf '%s' "${out%%$'\t'*}"
}

# run_check_policy_raw <tool> <input>: the full "<action>\t<reason>" line, so tests can assert
# that a denial names the deciding policy file, distinguishes a deny rule from no rule, and
# reports the expected arg pattern on an arg-scope miss.
run_check_policy_raw() {
  local tool_name="$1" tool_input="$2"
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

# --- check_policy returns "<action>\t<reason>": denials can name the deciding source ---
# (issue #116 — previously every denial collapsed into the same three words, so an agent could
# not tell an explicit deny from "no rule at all" from an arg-scope miss)

# matched rule → reason carries the policy file path and the 1-based rule index
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"gh","action":"deny"},{"tool":"ci","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "gh" '{}')
assert_eq "$RES" "$(printf 'deny\trule:%s/policy.json:1' "$PDIR")" "reason: deny rule → deny<TAB>rule:<path>:<index>"
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "ci" '{}')
assert_eq "$RES" "$(printf 'allow\trule:%s/policy.json:2' "$PDIR")" "reason: allow rule → allow<TAB>rule:<path>:<index>"

# no rule matched, no default → unmatched reason naming every consulted file (`-` = absent)
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"gh","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "some_write_tool" '{}')
assert_contains "$RES" $'prompt\tunmatched:-:' "reason: no rule → prompt<TAB>unmatched:<overlay>:<base>"
assert_contains "$RES" "$PDIR/policy.json" "reason: no rule → base policy path named"
RES=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="/nonexistent.json" run_check_policy_raw "some_write_tool" '{}')
assert_contains "$RES" "unmatched:-:$PDIR/policy.json" "reason: nonexistent overlay not named as consulted"

# no policy file at all → nopolicy reason (distinct from "rule exists but args missed")
PDIR=$(empty_home)
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "some_write_tool" '{}')
assert_eq "$RES" $'prompt\tnopolicy' "reason: no policy file → prompt<TAB>nopolicy"

# policy default → default reason naming the file that set it
PDIR=$(setup_policy '{"version":"1.0","default":"deny","rules":[]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "some_write_tool" '{}')
assert_eq "$RES" "$(printf 'deny\tdefault:%s/policy.json' "$PDIR")" "reason: default deny → deny<TAB>default:<path>"
PDIR=$(setup_policy '{"version":"1.0","default":"prompt","rules":[]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "some_write_tool" '{}')
assert_eq "$RES" "$(printf 'prompt\tdefault:%s/policy.json' "$PDIR")" "reason: default prompt → prompt<TAB>default:<path>"

# read-only heuristic reason
PDIR=$(empty_home)
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "print_file" '{}')
assert_eq "$RES" $'allow\treadonly' "reason: read-only auto-allow → allow<TAB>readonly"

# arg-scope miss → argscope reason naming the file and the expected arg pattern
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"ci","args":{"cwd":"/tmp/*"},"action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "ci" '{"cwd":"/elsewhere"}')
assert_contains "$RES" $'prompt\targscope:' "reason: arg-scope miss → prompt<TAB>argscope:<path>:<patterns>"
assert_contains "$RES" "$PDIR/policy.json" "reason: arg-scope miss → policy file named"
assert_contains "$RES" 'cwd=/tmp/*' "reason: arg-scope miss → expected arg pattern reported"
# the same call with a matching cwd still matches the rule
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "ci" '{"cwd":"/tmp/x"}')
assert_contains "$RES" $'allow\trule:' "reason: matching cwd → allow with rule reason"

# multi-arg rule: every key/pattern is reported
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"ci","args":{"cwd":"/tmp/*","check":"tests"},"action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "ci" '{"cwd":"/elsewhere"}')
assert_contains "$RES" 'cwd=/tmp/*,check=tests' "reason: arg-scope miss → all key=pattern pairs reported"

# --- integration: the permission gate wired into run_tool, exercised through the full
#     shai-dispatch pipeline (not the extracted functions) ---

# deny produces is_error tool_result naming the deny rule and its policy file
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"deny"}]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_deny","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "deny → is_error true"
assert_contains "$result" 'Policy denied' "deny → error message"
assert_contains "$result" 'deny rule in' "deny → message names the deny rule"
assert_contains "$result" "$tmpdir/policy.json" "deny → message names the policy file"

# non-interactive prompt → fail closed with a cause-bearing Not granted (never the old
# ambiguous "Permission denied: <tool>")
tmpdir=$(setup_policy '{"version":"1.0","default":"prompt","rules":[]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_prompt","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "non-interactive prompt → is_error true"
assert_contains "$result" 'Not granted' "non-interactive prompt → denied message"
assert_contains "$result" 'policy default in' "non-interactive prompt → message names the deciding default"
assert_contains "$result" "$tmpdir/policy.json" "non-interactive prompt → message names the policy file"

# arg-scope miss → Not granted naming the required arg pattern, so the agent knows the retry
# that would work (this is the case the old three-word message made undetectable)
tmpdir=$(setup_policy '{"version":"1.0","rules":[{"tool":"ci","args":{"cwd":"/tmp/*"},"action":"allow"}]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_scope","type":"function","function":{"name":"ci","arguments":"{\"cwd\":\"/elsewhere\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "arg-scope miss → is_error true"
assert_contains "$result" 'Not granted' "arg-scope miss → denied message"
assert_contains "$result" 'requires cwd to match /tmp/*' "arg-scope miss → expected arg pattern reported"
assert_contains "$result" "$tmpdir/policy.json" "arg-scope miss → message names the policy file"

# allow executes tool normally
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"list_directory","action":"allow"}]}')
make_stub_bin
stub_dir="$STUB"
write_gh_stub
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_allow","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\"'"$tmpdir"'\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":false' "allow → executes, is_error false"

finish
