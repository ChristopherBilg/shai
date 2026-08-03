#!/bin/bash
# test_policy.sh — unit tests for the permission gate policy matcher
# Covers: check_policy in shai-dispatch — policy file parsing, rule matching, fallbacks
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-dispatch: check_policy"

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

# --- no policy file: allow for the four read-only tools, prompt for anything else ---
for t in print_file list_directory gh_pr_view gh_issue_view; do
  PDIR=$(empty_home)
  RES=$(SHAI_HOME="$PDIR" run_check_policy "$t" '{}')
  assert_eq "$RES" "allow" "no policy file: $t → allow"
done

PDIR=$(empty_home)
RES=$(SHAI_HOME="$PDIR" run_check_policy "some_write_tool" '{}')
assert_eq "$RES" "prompt" "no policy file: non-read-only tool → prompt"

# --- empty policy file → prompt (not a crash, not an empty string) ---
PDIR=$(setup_policy '')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "prompt" "empty policy file → prompt"

# regression: whitespace-only is the same failure mode as zero-byte (both jq calls succeed
# with zero output, so the nested ${fallback:-prompt} expansion must still catch it)
WSDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$WSDIR")
printf '   \n\t\n' >"$WSDIR/policy.json"
RES=$(SHAI_HOME="$WSDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "prompt" "whitespace-only policy file → prompt"

# --- malformed (non-JSON) policy file → prompt; must not crash the caller ---
PDIR=$(setup_policy 'not json {')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "prompt" "malformed policy file → prompt"

# --- exact tool match ---
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "allow" "exact tool match, action allow → allow"

PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"gh_pr_view","action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "gh_pr_view" '{}')
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

# --- no rule matches and no `default` field → prompt ---
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"other_tool","action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{}')
assert_eq "$RES" "prompt" "no rule matches, no default field → prompt"

finish
