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
  # shai-dispatch sources lib/read-only.sh and lib/failure.sh via its own $DIR, which under
  # eval resolves to this test's directory (tests/) — rewrite both source paths to the real
  # repo lib so the eval'd check_policy can use the shared exclusion list (see #118) and the
  # failure-store instrumentation (lib/failure.sh) without resolving tests/lib/.
  sed -n '1,/^tool_calls=/p' "$DIR/shai-dispatch" | head -n -1 |
    sed -e "s|\$DIR/lib/read-only.sh|$DIR/lib/read-only.sh|g" \
      -e "s|\$DIR/lib/failure.sh|$DIR/lib/failure.sh|g"
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

# --- default exclusions (see #118): the read-only auto-allow fallback degrades to `prompt`
#     when the input path targets an excluded location — any entry in RO_EXCLUDED_BASENAMES in
#     lib/read-only.sh (credentials, VCS internals, dependency noise). Exclusions are a default,
#     not a boundary: an explicit rule or `default` is checked first and wins. ---
PDIR=$(empty_home)
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/.env"}')
assert_eq "$RES" "prompt" "exclusions: print_file targeting .env → prompt, not auto-allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/home/user/.ssh/id_rsa"}')
assert_eq "$RES" "prompt" "exclusions: print_file under .ssh → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/node_modules/pkg/index.js"}')
assert_eq "$RES" "prompt" "exclusions: print_file under node_modules → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "list_directory" '{"path":"/repo/.git"}')
assert_eq "$RES" "prompt" "exclusions: list_directory .git → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "search_files" '{"pattern":"x","path":"/home/user/.aws"}')
assert_eq "$RES" "prompt" "exclusions: search_files targeting .aws → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"./proj/.env.local"}')
assert_eq "$RES" "prompt" "exclusions: relative path into .env.* → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"../.ssh/id_rsa"}')
assert_eq "$RES" "prompt" "exclusions: relative path into .ssh → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/home/user/.netrc"}')
assert_eq "$RES" "prompt" "exclusions: print_file on .netrc → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "search_files" '{"pattern":"x","path":"/home/user/.npmrc"}')
assert_eq "$RES" "prompt" "exclusions: search_files targeting .npmrc → prompt"
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/src/main.c"}')
assert_eq "$RES" "allow" "exclusions: print_file on a plain path → still allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "list_directory" '{"path":"/repo"}')
assert_eq "$RES" "allow" "exclusions: list_directory on a plain path → still allow"
RES=$(SHAI_HOME="$PDIR" run_check_policy "search_files" '{"pattern":"x","path":"/repo"}')
assert_eq "$RES" "allow" "exclusions: search_files on a plain path → still allow"
# search_files defaults path to . — the caller's working tree, never excluded
RES=$(SHAI_HOME="$PDIR" run_check_policy "search_files" '{"pattern":"x"}')
assert_eq "$RES" "allow" "exclusions: search_files default path (.) → allow"
# path-less read-only tools are unaffected
RES=$(SHAI_HOME="$PDIR" run_check_policy "sleep" '{"seconds":1}')
assert_eq "$RES" "allow" "exclusions: sleep (no path) → allow"

# an explicit policy rule wins over the exclusion default (rules are checked before the fallback)
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","args":{"path":"/repo/.env"},"action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/.env"}')
assert_eq "$RES" "allow" "exclusions: explicit allow rule beats the exclusion default"
# a deny rule still denies (it is a rule, checked before the fallback)
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"print_file","args":{"path":"/repo/src/*"},"action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/src/main.c"}')
assert_eq "$RES" "deny" "exclusions: explicit deny rule still denies"
# an explicit default wins over the exclusion default
PDIR=$(setup_policy '{"version":"1.0","default":"allow","rules":[]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy "print_file" '{"path":"/repo/.env"}')
assert_eq "$RES" "allow" "exclusions: explicit default beats the exclusion default"

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

# array-typed input args (e.g. the jira tool's `args` array): the pattern matches the input's
# JSON rendering, so scoping to ["issue","view",*] allows the read-only view verb only
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"jira","args":{"args":"[\"issue\",\"view\",*]"},"action":"allow"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "jira" '{"args":["issue","view","PROJ-123"]}')
assert_contains "$RES" $'allow\trule:' "array-typed args: issue view matches the scoped rule"
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "jira" '{"args":["issue","edit","PROJ-123"]}')
assert_contains "$RES" $'prompt\targscope:' "array-typed args: write verb → arg-scope miss"
assert_contains "$RES" 'args=["issue","view",*]' "array-typed args: arg-scope miss reports the expected pattern"

# a deny rule with args that miss is NOT an arg-scope miss: retrying to match its pattern
# would land on the deny rule, so report unmatched instead of suggesting a fixable retry
PDIR=$(setup_policy '{"version":"1.0","rules":[{"tool":"ci","args":{"cwd":"/tmp/*"},"action":"deny"}]}')
RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "ci" '{"cwd":"/elsewhere"}')
assert_contains "$RES" $'prompt\tunmatched:' "reason: deny rule with args that miss → unmatched, not argscope"
assert_contains "$RES" "$PDIR/policy.json" "reason: deny rule with args that miss → base policy named"

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

# read-only exclusion (see #118): with no policy file, an excluded path degrades the auto-allow
# to prompt, and a non-interactive prompt fails closed — the tool never executes
tmpdir=$(empty_home)
make_stub_bin
stub_dir="$STUB"
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"test_excl","type":"function","function":{"name":"print_file","arguments":"{\"path\":\"/repo/.env\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null) || true
assert_contains "$result" '"is_error":true' "exclusions integration: excluded path → is_error true (fail closed)"
assert_contains "$result" 'Not granted' "exclusions integration: excluded path → denied message, tool not executed"

# --- determinism (#294): identical calls must produce identical verdicts, every time ---
# Regression for #294: policy enforcement gave different verdicts for identical out-of-policy
# tool calls (same tool, same path, same old/new string — granted, granted, denied, granted).
# Two properties are asserted here:
#   1. Repeated identical calls → byte-identical verdict + reason, and the expected denial
#      every time: argscope for an out-of-policy write tool, unmatched for a tool with no
#      rules at all (a no-rule-matched call is always denied).
#   2. First-match-wins is deterministic even when MANY rules match. Root cause of #294: the
#      rule-match/arg-scope lookups piped jq's multi-line output into `head -n 1` under
#      `set -o pipefail` — head closed the pipe after the first line, jq could die with
#      SIGPIPE (141), pipefail then reported the pipeline failed, and the `|| match=""`
#      guard discarded a VALID match, so the call fell through to the fallback and the
#      verdict flipped with process timing. The lookup now takes the first element inside
#      jq ([...][0] // empty), so the pipeline emits at most one line and a match can never
#      be lost to a broken pipe.

# (1a) the issue_worker policy shape (#294): a single patch_file allow rule scoped to /tmp/*,
# no default. A call targeting e.g. $SHAI_HOME/ci.json is out of policy and must be denied
# identically every single time — same verdict, same argscope reason naming the policy file
# and the required pattern.
PDIR=$(setup_policy '{"rules":[{"tool":"patch_file","args":{"path":"/tmp/*"},"action":"allow"}]}')
FIRST_VERDICT=""
for i in $(seq 1 25); do
  RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "patch_file" \
    '{"path":"/home/user/.shai/ci.json","old_string":"a","new_string":"b"}')
  if [ -z "$FIRST_VERDICT" ]; then
    FIRST_VERDICT="$RES"
  else
    assert_eq "$RES" "$FIRST_VERDICT" \
      "determinism: out-of-policy patch_file → identical verdict+reason every time (iter $i)"
  fi
done
assert_eq "$FIRST_VERDICT" "$(printf 'prompt\targscope:%s/policy.json:path=/tmp/*' "$PDIR")" \
  "determinism: out-of-policy patch_file → argscope denial naming the policy and pattern"

# (1b) a write tool with no rule at all (and no default) → unmatched prompt every time
# (headless dispatch fails closed, so the call is always denied)
PDIR=$(setup_policy '{"rules":[{"tool":"patch_file","args":{"path":"/tmp/*"},"action":"allow"}]}')
FIRST_NO_RULE=""
for i in $(seq 1 25); do
  RES=$(SHAI_HOME="$PDIR" run_check_policy_raw "some_write_tool" '{"path":"/tmp/x"}')
  if [ -z "$FIRST_NO_RULE" ]; then
    FIRST_NO_RULE="$RES"
  else
    assert_eq "$RES" "$FIRST_NO_RULE" \
      "determinism: no-rule-matched write tool → identical verdict+reason every time (iter $i)"
  fi
done
assert_contains "$FIRST_NO_RULE" $'prompt\tunmatched:' \
  "determinism: no-rule-matched write tool → unmatched (always denied headless)"
assert_contains "$FIRST_NO_RULE" "$PDIR/policy.json" \
  "determinism: no-rule-matched write tool → reason names the consulted policy"

# (2) first-match-wins must hold deterministically with many matching rules. Generate enough
# matching rules that the old jq|head pipeline's multi-line output would overflow the pipe
# buffer, so head's early close and jq's SIGPIPE were guaranteed and the valid match was
# always discarded (verdict flipped to the default deny). The first rule's action must win,
# identically, every time.
BIGDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$BIGDIR")
{
  printf '{"default":"deny","rules":['
  for i in $(seq 1 20000); do
    printf '{"tool":"race_tool","args":{"path":"/tmp/*"},"action":"allow"},'
  done
  printf '{"tool":"race_tool","action":"deny"}]}'
} >"$BIGDIR/policy.json"
for i in $(seq 1 3); do
  RES=$(SHAI_HOME="$BIGDIR" run_check_policy_raw "race_tool" '{"path":"/tmp/x"}')
  assert_eq "$RES" "$(printf 'allow\trule:%s/policy.json:1' "$BIGDIR")" \
    "determinism: first-match-wins with 20001 matching rules, never lost to a broken pipe (iter $i)"
done

# (3) integration: repeated identical out-of-policy calls through the full dispatch pipeline
# produce the same Not granted denial every time, the tool never executes, and the policy
# decision is logged to stderr — a denial (or, symmetrically, a grant) is never silent.
# The target lives OUTSIDE the /tmp/* allow root (like $SHAI_HOME/ci.json in #294), so the
# call is out of policy even though the policy file itself sits in a /tmp temp dir.
tmpdir=$(setup_policy '{"rules":[{"tool":"patch_file","args":{"path":"/tmp/*"},"action":"allow"}]}')
OUTROOT=$(mktemp -d /var/tmp/shai294.XXXXXX)
_CLEANUP_DIRS+=("$OUTROOT")
CIJSON="$OUTROOT/ci.json"
printf '{"checks":{"scratch":true}}' >"$CIJSON"
event=$(jq -nc --arg p "$CIJSON" '{type:"message",source:"assistant",payload:{content:null,tool_calls:[{id:"det1",type:"function",function:{name:"patch_file",arguments:({path:$p,old_string:"scratch",new_string:"replaced"}|tojson)}}],finish_reason:"tool_calls"}}')
FIRST_DENIAL=""
for i in $(seq 1 10); do
  result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" "$DIR/shai-dispatch" 2>&1) || true
  if [ -z "$FIRST_DENIAL" ]; then
    FIRST_DENIAL="$result"
  else
    assert_eq "$result" "$FIRST_DENIAL" \
      "determinism: dispatch of identical out-of-policy call → identical output+stderr every time (iter $i)"
  fi
done
assert_contains "$FIRST_DENIAL" '"is_error":true' "determinism: dispatch of out-of-policy call → is_error true"
assert_contains "$FIRST_DENIAL" 'Not granted' "determinism: dispatch of out-of-policy call → denied message"
assert_contains "$FIRST_DENIAL" 'requires path to match /tmp/*' "determinism: dispatch of out-of-policy call → argscope denial names the pattern"
assert_contains "$FIRST_DENIAL" "policy: prompt patch_file (argscope:$tmpdir/policy.json:path=/tmp/*)" \
  "determinism: dispatch of out-of-policy call → policy decision logged to stderr"
assert_eq "$(cat "$CIJSON")" '{"checks":{"scratch":true}}' \
  "determinism: dispatch of out-of-policy call → tool never executed, file unchanged"

# a deny rule's decision is logged to stderr naming the rule that matched
tmpdir=$(setup_policy '{"rules":[{"tool":"list_directory","action":"deny"}]}')
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"det2","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" "$DIR/shai-dispatch" 2>&1) || true
assert_contains "$result" "policy: deny list_directory (rule:$tmpdir/policy.json:1)" \
  "determinism: deny rule decision logged to stderr naming the rule"

# an allow from the policy default is logged to stderr — a grant outside every rule is visible
tmpdir=$(setup_policy '{"default":"allow","rules":[]}')
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"det3","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" "$DIR/shai-dispatch" 2>&1) || true
assert_contains "$result" "policy: allow list_directory (default:$tmpdir/policy.json)" \
  "determinism: default-allow decision logged to stderr naming the deciding default"
assert_contains "$result" '"is_error":false' "determinism: default-allow decision → tool executes"

# an allow granted by a matched rule is logged to stderr naming the rule — the exact
# "grant is never silent" path: the allow comes from rule:<file>:<idx>, not a default
tmpdir=$(setup_policy '{"rules":[{"tool":"list_directory","action":"allow"}]}')
event='{"type":"message","source":"assistant","payload":{"tool_calls":[{"id":"det4","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}  }],"finish_reason":"tool_calls"}}'
result=$(printf '%s\n' "$event" | SHAI_HOME="$tmpdir" "$DIR/shai-dispatch" 2>&1) || true
assert_contains "$result" "policy: allow list_directory (rule:$tmpdir/policy.json:1)" \
  "determinism: rule-allow decision logged to stderr naming the rule"
assert_contains "$result" '"is_error":false' "determinism: rule-allow decision → tool executes"

finish
