#!/bin/bash
# test_config.sh — unit tests for shai-config policy list|add|remove|test and ci list|add|remove
# Covers: shai-config — noun/verb dispatch and usage errors (exit 2), policy list (human
#         table + --json, overlay FILE column, effective default line), policy add (append,
#         --args objects, duplicate --args key refusal, --before insertion and leading-zero
#         normalization, shadow refusal naming the shadowing index and writing nothing —
#         no-args and empty-args-object blankets — --force, file creation when absent),
#         policy remove (list index, out-of-range index, corrupt file untouched), policy
#         test (verdicts from lib/policy.sh check_policy — rule/default/readonly reasons,
#         tostring echo, --overlay, --json), corrupt-policy parse-before-write and atomic
#         temp-file writes preserving the existing mode; ci list (human + --json, resolved
#         key naming), ci add (origin-derived and --repo keys normalized through
#         lib/git-remote.sh, file creation with version 1.0 and no _comment, --timeout/
#         --env storage and validation, existing-check refusal), ci remove (single-check
#         removal leaving the repo entry and checks: {}, unknown check listing available
#         names), corrupt-ci.json parse-before-write, no-git-remote exit 1, and the
#         round-trip against tools/ci/run.sh
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-config policy"

# Env neutralization (mirroring #333): a workflow running the suite exports
# SHAI_POLICY_OVERLAY, and an inherited overlay supersedes base rules (including deny),
# which would silently flip every `policy test` verdict below. lib.sh unsets it centrally;
# this canary fails loudly if the leak ever re-appears.
if [ -n "${SHAI_POLICY_OVERLAY:-}" ]; then
  echo "FATAL: SHAI_POLICY_OVERLAY is set on entry ($SHAI_POLICY_OVERLAY); refusing to run with a leaked overlay" >&2
  exit 1
fi

CFG="$DIR/shai-config"

# policy_home <json>: temp dir whose policy.json contains the given content; echoes the path.
policy_home() {
  local d
  d=$(mktemp -d)
  _CLEANUP_DIRS+=("$d")
  printf '%s' "$1" >"$d/policy.json"
  printf '%s' "$d"
}

# empty_home: temp dir with no policy.json at all; echoes the path.
empty_home() {
  local d
  d=$(mktemp -d)
  _CLEANUP_DIRS+=("$d")
  printf '%s' "$d"
}

# --- usage dispatch: exit 2 for unknown noun/verb/flag, missing required options ---
assert_exit 2 "no arguments is a usage error" -- "$CFG"
assert_exit 2 "unknown noun is a usage error" -- "$CFG" bogus list
assert_exit 2 "unknown verb is a usage error" -- "$CFG" policy bogus
assert_exit 2 "policy without a verb is a usage error" -- "$CFG" policy
assert_exit 2 "list: unknown flag is a usage error" -- "$CFG" policy list --bogus
assert_exit 2 "add: unknown flag is a usage error" -- "$CFG" policy add --bogus
assert_exit 2 "add: missing --tool is a usage error" -- "$CFG" policy add --action allow
assert_exit 2 "add: missing --action is a usage error" -- "$CFG" policy add --tool gh
assert_exit 2 "test: missing --input is a usage error" -- "$CFG" policy test --tool gh
assert_exit 2 "remove: flag-like argument is a usage error" -- "$CFG" policy remove --json

# --- policy list: human table ---
PDIR=$(policy_home '{"version":"1.0","default":"prompt","rules":[{"tool":"gh","action":"allow"},{"tool":"ci","args":{"cwd":"/tmp/*"},"action":"deny"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy list)
assert_contains "$OUT" '  1  allow   gh' "list: first rule row (index, action, tool)"
assert_contains "$OUT" '{"cwd":"/tmp/*"}' "list: args rendered compact"
assert_contains "$OUT" "default: prompt" "list: effective default line"
assert_contains "$OUT" "IDX  ACTION  TOOL" "list: header row"

OUT=$(SHAI_HOME="$PDIR" "$CFG" policy list --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules | length')" "2" "list --json: two rules"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].index')" "1" "list --json: per-file 1-based index"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].tool')" "gh" "list --json: tool"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].action')" "allow" "list --json: action"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].file')" "$PDIR/policy.json" "list --json: file names the base policy"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].args | type')" "null" "list --json: no-args rule has null args"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[1].args.cwd')" "/tmp/*" "list --json: args preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.default')" "prompt" "list --json: default"
assert_eq "$(printf '%s' "$OUT" | jq -r '.default_file')" "$PDIR/policy.json" "list --json: default_file"

# --- policy list: overlay FILE column + overlay default wins the default line ---
OV=$(mktemp)
_CLEANUP_DIRS+=("$OV")
printf '{"default":"deny","rules":[{"tool":"sleep","action":"allow"}]}' >"$OV"
OUT=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="$OV" "$CFG" policy list)
assert_contains "$OUT" '  1  allow   sleep' "list: overlay rules listed"
assert_contains "$OUT" "$OV" "list: FILE column names the overlay path"
assert_contains "$OUT" "$PDIR/policy.json" "list: FILE column names the base path"
assert_contains "$OUT" "default: deny" "list: overlay default wins the default line"
# consultation order: the overlay row (FILE column carries the overlay path) precedes the
# base row (FILE column carries the base path)
FIRST=$(printf '%s\n' "$OUT" | grep -nF "$OV" | head -n1 | cut -d: -f1)
SECOND=$(printf '%s\n' "$OUT" | grep -nF "$PDIR/policy.json" | head -n1 | cut -d: -f1)
assert_eq "$([ "$FIRST" -lt "$SECOND" ] && echo first)" "first" \
  "list: overlay rules are listed before base rules (consultation order)"

OUT=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="$OV" "$CFG" policy list --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules | length')" "3" "list --json: overlay + base rules"
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules[0].file')" "$OV" "list --json: first rule is the overlay's"
assert_eq "$(printf '%s' "$OUT" | jq -r '.default_file')" "$OV" "list --json: default_file is the overlay's"

# nonexistent overlay path is ignored, like check_policy
OUT=$(SHAI_HOME="$PDIR" SHAI_POLICY_OVERLAY="/nonexistent/overlay.json" "$CFG" policy list --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules | length')" "2" "list: nonexistent overlay ignored"

# --- policy list: no files / no rules / corrupt ---
AD=$(empty_home)
OUT=$(SHAI_HOME="$AD" "$CFG" policy list)
assert_contains "$OUT" "(no policy files)" "list: no policy files at all"
OUT=$(SHAI_HOME="$AD" "$CFG" policy list --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.rules | length')" "0" "list --json: empty rules when nothing exists"

PDIR=$(policy_home '{"default":"allow","rules":[]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy list)
assert_contains "$OUT" "(no rules)" "list: no rules"
assert_contains "$OUT" "default: allow" "list: default shown with no rules"

CDIR=$(policy_home '{nope')
OUT=$(SHAI_HOME="$CDIR" "$CFG" policy list 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "list: corrupt policy → exit 1"
assert_contains "$OUT" "error:" "list: corrupt policy → own error: prefix"
assert_contains "$OUT" "shai-doctor" "list: corrupt policy → shai-doctor pointer"

# --- policy add: creates the file when absent ---
AD=$(empty_home)
OUT=$(SHAI_HOME="$AD" "$CFG" policy add --tool gh --action allow) && rc=0 || rc=$?
assert_eq "$rc" "0" "add: exits 0"
assert_eq "$(test -f "$AD/policy.json" && echo yes)" "yes" "add: creates policy.json when absent"
assert_eq "$(jq -r '.rules | length' "$AD/policy.json")" "1" "add: one rule"
assert_eq "$(jq -r '.rules[0].tool' "$AD/policy.json")" "gh" "add: tool stored"
assert_eq "$(jq -r '.rules[0] | has("args")' "$AD/policy.json")" "false" "add: no args key when --args absent"
assert_contains "$OUT" "added rule 1" "add: reports the new rule's list index"

# --- policy add: appends and preserves unrelated fields ---
PDIR=$(policy_home '{"version":"1.0","default":"deny","rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool git --action deny) && rc=0 || rc=$?
assert_eq "$rc" "0" "add: append exits 0"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "2" "add: appended"
assert_eq "$(jq -r '.rules[1].tool' "$PDIR/policy.json")" "git" "add: appended rule is at list index 2"
assert_eq "$(jq -r '.version' "$PDIR/policy.json")" "1.0" "add: unrelated top-level fields preserved"
assert_eq "$(jq -r '.default' "$PDIR/policy.json")" "deny" "add: default preserved"

# --- policy add: --args builds the args object (values are verbatim pattern strings) ---
PDIR=$(policy_home '{"rules":[]}')
SHAI_HOME="$PDIR" "$CFG" policy add --tool jira --action allow --args 'args=["issue","view",*]'
assert_eq "$(jq -r '.rules[0].args.args' "$PDIR/policy.json")" '["issue","view",*]' \
  "add: --args value stored verbatim (array-rendering pattern)"
SHAI_HOME="$PDIR" "$CFG" policy add --tool ci --action deny --args cwd=/tmp/x --args check=test
assert_eq "$(jq -r '.rules[1].args.cwd' "$PDIR/policy.json")" "/tmp/x" "add: first --args pair"
assert_eq "$(jq -r '.rules[1].args.check' "$PDIR/policy.json")" "test" "add: second --args pair"
assert_eq "$(jq -r '.rules[1].args | keys | length' "$PDIR/policy.json")" "2" "add: both --args pairs stored"

# --- policy add: shadow refusal — an earlier same-tool no-args rule decides every call ---
# The three absence/zero assertions in this block were mutation-checked: (1) deleting the
# shadow guard in cmd_add lets the rule append and the rules-length assertion below goes
# red; (2) deleting the parse-before-write check makes `add` replace a corrupt file, and
# the byte-identical assertion in the corrupt block goes red; (3) making the guard ignore
# --force turns the positive control in the next block red.
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action deny --args 'args=pr merge*' 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: shadowed rule is refused (exit 1)"
assert_contains "$OUT" "error: rule would never match — rules[0]" \
  "add: shadow refusal names the shadowing index (own error: prefix)"
assert_contains "$OUT" '{"tool":"gh","action":"allow"}' "add: shadow refusal shows the shadowing rule"
assert_contains "$OUT" "Retry with --before 0, or --force to append anyway." \
  "add: shadow refusal names both escape hatches"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "1" \
  "add: shadow refusal writes nothing (rules length unchanged — mutation-checked)"
assert_eq "$(cat "$PDIR/policy.json")" '{"rules":[{"tool":"gh","action":"allow"}]}' \
  "add: shadow refusal leaves the file byte-identical"

# --- policy add: --force appends anyway (positive control, adjacent to the refusal) ---
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action deny --args 'args=pr merge*' --force) && rc=0 || rc=$?
assert_eq "$rc" "0" "add --force: exits 0"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "2" \
  "add --force: appends anyway (positive control — mutation-checked)"
assert_eq "$(jq -r '.rules[1].tool' "$PDIR/policy.json")" "gh" "add --force: the forced rule is present"
# …and the blanket allow still decides it (first-match-wins) — the forced rule is inert by design
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{"args":["pr","merge","1"]}')
assert_contains "$OUT" "verdict: allow" "add --force: rules[0] still decides the call"

# --- policy add: shadow refusal also catches a hand-edited empty args object ---
# check_policy's `to_entries | all` is vacuously true on "args": {}, so an earlier empty-args
# rule is a blanket rule exactly like a missing args key — equally decidable, so refused too.
# The rules-length and byte-identical assertions in this block were mutation-checked:
# dropping the empty-object clause from the shadow filter lets the rule append and turns
# them red; the adjacent --force call stays green either way (positive control).
PDIR=$(policy_home '{"rules":[{"tool":"gh","args":{},"action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action deny --args 'args=pr merge*' 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: empty-args-object shadowed rule is refused (exit 1)"
assert_contains "$OUT" "error: rule would never match — rules[0]" \
  "add: empty-args shadow refusal names the shadowing index (own error: prefix)"
assert_contains "$OUT" '{"tool":"gh","args":{},"action":"allow"}' \
  "add: empty-args shadow refusal shows the shadowing rule"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "1" \
  "add: empty-args shadow refusal writes nothing (rules length unchanged — mutation-checked)"
assert_eq "$(cat "$PDIR/policy.json")" '{"rules":[{"tool":"gh","args":{},"action":"allow"}]}' \
  "add: empty-args shadow refusal leaves the file byte-identical"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{"args":["pr","merge","1"]}')
assert_contains "$OUT" "verdict: allow" "empty-args blanket: rules[0] decides even a specific call"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action deny --args 'args=pr merge*' --force) && rc=0 || rc=$?
assert_eq "$rc" "0" "add --force: appends past the empty-args blanket (positive control)"

# --- policy add: --before N inserts at the 0-based position ---
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action deny --before 0) && rc=0 || rc=$?
assert_eq "$rc" "0" "add --before 0: exits 0 (not shadow-refused)"
assert_eq "$(jq -r '.rules[0].action' "$PDIR/policy.json")" "deny" "add --before 0: new rule inserted first"
assert_contains "$OUT" "added rule 1" "add --before 0: reports the inserted position"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{}')
assert_contains "$OUT" "verdict: deny" "add --before 0: the new deny now decides"

PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"},{"tool":"git","action":"allow"}]}')
SHAI_HOME="$PDIR" "$CFG" policy add --tool sleep --action allow --before 1
assert_eq "$(jq -r '.rules[1].tool' "$PDIR/policy.json")" "sleep" "add --before 1: inserted mid-file"

# --- policy add: --before leading zeros normalize to a plain decimal ---
# "09"/"00" pass the digit check but are invalid octal for bash arithmetic and invalid JSON
# for jq --argjson, which used to surface as a raw jq error; they must normalize instead.
PDIR=$(policy_home "$(jq -nc '{rules: [range(0;10) | {tool: ("t" + tostring), action: "allow"}]}')")
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --before 09) && rc=0 || rc=$?
assert_eq "$rc" "0" "add --before 09: normalized to 9, exits 0 (no raw jq error)"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "11" "add --before 09: one rule appended"
assert_eq "$(jq -r '.rules[9].tool' "$PDIR/policy.json")" "gh" "add --before 09: inserted at 0-based position 9"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool git --action allow --before 00) && rc=0 || rc=$?
assert_eq "$rc" "0" "add --before 00: normalized to 0, exits 0"
assert_eq "$(jq -r '.rules[0].tool' "$PDIR/policy.json")" "git" "add --before 00: inserted at 0-based position 0"
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --before 09 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add --before 09 out of range → exit 1 (clean validation, not a raw jq error)"
assert_contains "$OUT" "error: --before 9 is out of range" "add: out-of-range leading zero → own error: prefix"

# --- policy add: value validation ---
PDIR=$(policy_home '{"rules":[]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action frobnicate 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: invalid action → exit 1"
assert_contains "$OUT" 'error: invalid action "frobnicate"' "add: invalid action → own error: prefix"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --before 5 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: --before out of range → exit 1"
assert_contains "$OUT" "error: --before 5 is out of range" "add: out-of-range --before → own error: prefix"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --before x 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: non-integer --before → exit 1"
assert_contains "$OUT" "error: --before must be a non-negative integer" "add: bad --before → own error: prefix"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --args noequals 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: --args without = → exit 1"
assert_contains "$OUT" "error: --args expects K=V" "add: bad --args → own error: prefix"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy add --tool gh --action allow --args k=A --args k=B 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: duplicate --args key → exit 1"
assert_contains "$OUT" 'error: duplicate --args key "k"' "add: duplicate --args → own error: prefix"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "0" "add: every rejected value wrote nothing"

# --- policy add/remove: corrupt policy aborts with exit 1, byte-identical ---
CDIR=$(policy_home 'not json {')
SNAPSHOT=$(cat "$CDIR/policy.json")
OUT=$(SHAI_HOME="$CDIR" "$CFG" policy add --tool gh --action allow 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: corrupt policy → exit 1"
assert_contains "$OUT" "error:" "add: corrupt policy → own error: prefix"
assert_contains "$OUT" "shai-doctor" "add: corrupt policy → shai-doctor pointer"
assert_eq "$(cat "$CDIR/policy.json")" "$SNAPSHOT" \
  "add: corrupt policy left byte-identical (mutation-checked)"
assert_eq "$(ls -A "$CDIR")" "policy.json" "add: corrupt abort leaves no temp file behind"

OUT=$(SHAI_HOME="$CDIR" "$CFG" policy remove 1 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: corrupt policy → exit 1"
assert_contains "$OUT" "error:" "remove: corrupt policy → own error: prefix"
assert_contains "$OUT" "shai-doctor" "remove: corrupt policy → shai-doctor pointer"
assert_eq "$(cat "$CDIR/policy.json")" "$SNAPSHOT" "remove: corrupt policy left byte-identical"
assert_eq "$(ls -A "$CDIR")" "policy.json" "remove: corrupt abort leaves no temp file behind"

# --- policy add/remove: an existing file's mode survives the atomic rewrite ---
# mktemp creates the temp file 0600 and mv carries that mode onto the policy, so without
# preservation a successful rewrite silently tightens a hand-edited 0644 file. The 644
# assertions were mutation-checked: deleting the chmod in write_policy makes add/remove
# leave the file at 600 and turns them red.
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
chmod 644 "$PDIR/policy.json"
SHAI_HOME="$PDIR" "$CFG" policy add --tool git --action deny
assert_eq "$(stat -c '%a' "$PDIR/policy.json")" "644" "add: existing 0644 mode preserved across the rewrite"
SHAI_HOME="$PDIR" "$CFG" policy remove 2
assert_eq "$(stat -c '%a' "$PDIR/policy.json")" "644" "remove: existing 0644 mode preserved across the rewrite"

# --- policy remove: list index addressing ---
PDIR=$(policy_home '{"default":"allow","rules":[{"tool":"gh","action":"allow"},{"tool":"git","action":"deny"},{"tool":"jira","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy remove 2) && rc=0 || rc=$?
assert_eq "$rc" "0" "remove: exits 0"
assert_contains "$OUT" "removed rule 2" "remove: reports the removed index"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "2" "remove: rule 2 removed"
assert_eq "$(jq -r '.rules[0].tool' "$PDIR/policy.json")" "gh" "remove: earlier rule kept"
assert_eq "$(jq -r '.rules[1].tool' "$PDIR/policy.json")" "jira" "remove: later rules shift down"
assert_eq "$(jq -r '.default' "$PDIR/policy.json")" "allow" "remove: default preserved"

OUT=$(SHAI_HOME="$PDIR" "$CFG" policy remove 9 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: unknown index → exit 1"
assert_contains "$OUT" "error: no rule at index 9" \
  "remove: unknown index → own error: prefix with the index"
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "2" "remove: unknown index wrote nothing"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy remove zero 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: non-integer index → exit 1"
assert_contains "$OUT" "error: index must be a positive integer" "remove: non-integer → own error: prefix"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy remove 0 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: index 0 → exit 1"

PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
SHAI_HOME="$PDIR" "$CFG" policy remove 1
assert_eq "$(jq -r '.rules | length' "$PDIR/policy.json")" "0" "remove: last rule leaves an empty rules array"
assert_eq "$(jq empty "$PDIR/policy.json" >/dev/null 2>&1 && echo ok)" "ok" "remove: file still valid JSON"

AD=$(empty_home)
OUT=$(SHAI_HOME="$AD" "$CFG" policy remove 1 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: no policy file → exit 1"
assert_contains "$OUT" "error: no policy file" "remove: missing file → own error: prefix"

# --- policy test: verdicts come from lib/policy.sh check_policy ---
# Drift cross-check with tests/test_policy.sh: that suite asserts shai-dispatch prints
# `policy: deny list_directory (rule:<tmp>/policy.json:1)` on stderr for this exact fixture;
# `policy test` must report the identical reason string — one function, two callers — so a
# future re-divergence is visible here instead of silent.
PDIR=$(policy_home '{"rules":[{"tool":"list_directory","action":"deny"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool list_directory --input '{}')
assert_contains "$OUT" "verdict: deny" "test: deny rule verdict"
assert_contains "$OUT" "reason:  rule:$PDIR/policy.json:1" \
  "test: reason identical to the dispatch stderr fixture (drift cross-check)"
assert_contains "$OUT" 'matched: {"tool":"list_directory","action":"deny"}' \
  "test: matched shows the deciding rule"

# --- policy test: the tostring echo shows the JSON rendering patterns must match ---
PDIR=$(policy_home '{"rules":[{"tool":"jira","args":{"args":"[\"issue\",\"view\",*]"},"action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool jira --input '{"args":["issue","view","PROJ-1"]}')
assert_contains "$OUT" 'input.args (tostring) = ["issue","view","PROJ-1"]' \
  "test: echoes the tostring'd value (an array rendering, never a command line)"
assert_contains "$OUT" "verdict: allow" "test: scoped allow rule matched"
assert_contains "$OUT" "reason:  rule:$PDIR/policy.json:1" "test: reason names the matched rule"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool jira --input '{"args":["issue","edit","PROJ-1"]}')
assert_contains "$OUT" "verdict: prompt" "test: non-matching call falls through"
assert_contains "$OUT" "argscope:" "test: arg-scope miss reports check_policy's argscope reason"

# --- policy test: default, readonly fallback, no-policy reasons ---
PDIR=$(policy_home '{"default":"deny","rules":[]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{}')
assert_contains "$OUT" "verdict: deny" "test: default deny verdict"
assert_contains "$OUT" "reason:  default:$PDIR/policy.json" "test: default reason names the file"
assert_contains "$OUT" "matched: (none)" "test: no matched rule for a default verdict"

AD=$(empty_home)
OUT=$(SHAI_HOME="$AD" "$CFG" policy test --tool print_file --input '{"path":"/tmp/x"}')
assert_contains "$OUT" "verdict: allow" "test: read-only fallback allows with no policy"
assert_contains "$OUT" "readonly" "test: readonly reason"
OUT=$(SHAI_HOME="$AD" "$CFG" policy test --tool write_file --input '{"path":"/tmp/x","content":"x"}')
assert_contains "$OUT" "verdict: prompt" "test: no policy → write tool prompts"
assert_contains "$OUT" "nopolicy" "test: nopolicy reason"

# --- policy test: --overlay pins the overlay for this call; full overlay+base stack ---
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"deny"}]}')
OV=$(mktemp)
_CLEANUP_DIRS+=("$OV")
printf '{"rules":[{"tool":"gh","action":"allow"}]}' >"$OV"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{}' --overlay "$OV")
assert_contains "$OUT" "verdict: allow" "test --overlay: overlay allow supersedes base deny"
assert_contains "$OUT" "reason:  rule:$OV:1" "test --overlay: reason names the overlay rule"
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool git --input '{}' --overlay "$OV")
assert_contains "$OUT" "verdict: prompt" "test --overlay: unmatched tool falls through to base"
assert_contains "$OUT" "unmatched:" "test --overlay: unmatched reason names the consulted stack"

# --- policy test: --json ---
PDIR=$(policy_home '{"rules":[{"tool":"gh","action":"allow"}]}')
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input '{"args":["pr","view"]}' --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.verdict')" "allow" "test --json: verdict"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason')" "rule:$PDIR/policy.json:1" "test --json: reason"
assert_eq "$(printf '%s' "$OUT" | jq -r '.matched.tool')" "gh" "test --json: matched rule"
assert_eq "$(printf '%s' "$OUT" | jq -r '.tostring.args')" '["pr","view"]' "test --json: tostring map"
assert_eq "$(printf '%s' "$OUT" | jq -r '.input.args[0]')" "pr" "test --json: input preserved"

# --- policy test: invalid input JSON is a validation failure ---
OUT=$(SHAI_HOME="$PDIR" "$CFG" policy test --tool gh --input 'nope {' 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "test: invalid --input JSON → exit 1"
assert_contains "$OUT" "error: --input is not valid JSON" "test: invalid --input → own error: prefix"

# ================================ ci half ================================
echo "shai-config ci"

# ci_home <json>: temp dir whose ci.json contains the given content; echoes the path.
ci_home() {
  local d
  d=$(mktemp -d)
  _CLEANUP_DIRS+=("$d")
  printf '%s' "$1" >"$d/ci.json"
  printf '%s' "$d"
}

# empty_ci_home: temp dir with no ci.json at all; echoes the path.
empty_ci_home() {
  local d
  d=$(mktemp -d)
  _CLEANUP_DIRS+=("$d")
  printf '%s' "$d"
}

# git_repo <remote-url>: temp dir holding a git repository whose origin remote is
# <remote-url>; echoes the path. Local only — git init + git remote add needs no network.
git_repo() {
  local url="$1" d
  d=$(mktemp -d)
  _CLEANUP_DIRS+=("$d")
  git -C "$d" init -q
  git -C "$d" remote add origin "$url"
  printf '%s' "$d"
}

# --- usage dispatch: exit 2 for unknown noun/verb/flag, missing required options ---
assert_exit 2 "ci without a verb is a usage error" -- "$CFG" ci
assert_exit 2 "ci unknown verb is a usage error" -- "$CFG" ci bogus
assert_exit 2 "ci list: unknown flag is a usage error" -- "$CFG" ci list --bogus
assert_exit 2 "ci add: unknown flag is a usage error" -- "$CFG" ci add --bogus
assert_exit 2 "ci add: missing --name is a usage error" -- "$CFG" ci add --command c
assert_exit 2 "ci add: missing --command is a usage error" -- "$CFG" ci add --name n
assert_exit 2 "ci remove: no name is a usage error" -- "$CFG" ci remove
assert_exit 2 "ci remove: flag-like name is a usage error" -- "$CFG" ci remove --json
assert_exit 2 "ci list: --repo without a value is a usage error" -- "$CFG" ci list --repo

# --- ci add: derives the key from the origin remote, via lib/git-remote.sh ---
REPO=$(git_repo "https://github.com/ChristopherBilg/shai.git")
CIHOME=$(empty_ci_home)
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name tests --command ./tests/run.sh --timeout 900) && rc=0 || rc=$?
assert_eq "$rc" "0" "add: exits 0"
assert_contains "$OUT" "repo: github.com/ChristopherBilg/shai  (from origin)" \
  "add: prints the derived key and where it came from"
assert_contains "$OUT" 'added check "tests"' "add: reports the added check"
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests.command' "$CIHOME/ci.json")" "./tests/run.sh" \
  "add: command stored under the normalized origin key"
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests.timeout' "$CIHOME/ci.json")" "900" \
  "add: --timeout stored"
assert_eq "$(jq -r '.version' "$CIHOME/ci.json")" "1.0" "add: created file carries version 1.0"
# Absence assertions, mutation-checked: creating the file by copying ci.json.example
# instead of the fresh {"version":"1.0","repos":{}} literal makes both go red.
assert_eq "$(jq -r 'has("_comment")' "$CIHOME/ci.json")" "false" \
  "add: the written file carries no _comment (the example's is not copied)"
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests | has("env")' "$CIHOME/ci.json")" "false" \
  "add: no env key when --env omitted"

REPO_SCP=$(git_repo "git@github.com:scp/repo.git")
CIHOME_SCP=$(empty_ci_home)
(cd "$REPO_SCP" && SHAI_HOME="$CIHOME_SCP" "$CFG" ci add --name t --command c)
assert_eq "$(jq -r '.repos | keys[0]' "$CIHOME_SCP/ci.json")" "github.com/scp/repo" \
  "add: scp-style origin runs through the shared normalizer"

# --- ci add: --repo is normalized through the same function (the mis-keying guard) ---
# The key written into the file is asserted, not just the printed line: a private
# normalizer that printed the right line but wrote the raw URL would pass the print
# assertion and leave a dead entry. Mutation-checked: bypassing normalize_url for the
# --repo path (key="$override") turns all four assertions red.
NODIR=$(mktemp -d)
_CLEANUP_DIRS+=("$NODIR")
CIHOME=$(empty_ci_home)
OUT=$(cd "$NODIR" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo https://github.com/o/r.git --name lint --command 'make lint')
assert_contains "$OUT" "repo: github.com/o/r  (normalized from --repo)" \
  "add --repo: normalized key and provenance printed"
assert_contains "$OUT" 'added check "lint"' "add --repo: reports the added check"
assert_eq "$(jq -r '.repos | keys[0]' "$CIHOME/ci.json")" "github.com/o/r" \
  "add --repo: the normalized key is what lands in the file"
assert_eq "$(jq -r '.repos | has("https://github.com/o/r.git")' "$CIHOME/ci.json")" "false" \
  "add --repo: the un-normalized spelling is never a key"

# --- ci add: appends into an existing file, preserving unrelated entries ---
CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/other/repo":{"checks":{"t":{"command":"x"}}}}}')
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name lint --command 'make lint' --repo github.com/o/r)
assert_eq "$(jq -r '.repos | keys | length' "$CIHOME/ci.json")" "2" "add: a new repo entry lands beside the existing one"
assert_eq "$(jq -r '.repos["github.com/other/repo"].checks.t.command' "$CIHOME/ci.json")" "x" \
  "add: the other repo's checks untouched"
assert_eq "$(jq -r '.version' "$CIHOME/ci.json")" "1.0" "add: version preserved"

CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/o/r":{"checks":{"tests":{"command":"echo a"}}}}}')
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name lint --command 'make lint' --repo github.com/o/r)
assert_eq "$(jq -r '.repos["github.com/o/r"].checks.tests.command' "$CIHOME/ci.json")" "echo a" \
  "add: existing check preserved"
assert_eq "$(jq -r '.repos["github.com/o/r"].checks.lint.command' "$CIHOME/ci.json")" "make lint" \
  "add: second check added alongside the first"

# --- ci add: --env builds the per-check env map (values verbatim, = preserved) ---
CIHOME=$(empty_ci_home)
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name tests --command ./tests/run.sh --env FOO=bar --env 'BAZ=qux=quux')
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests.env.FOO' "$CIHOME/ci.json")" "bar" \
  "add: first --env pair stored"
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests.env.BAZ' "$CIHOME/ci.json")" "qux=quux" \
  "add: value containing = stored verbatim"
assert_eq "$(jq -r '.repos["github.com/ChristopherBilg/shai"].checks.tests.env | keys | length' "$CIHOME/ci.json")" "2" \
  "add: both --env pairs stored"

# --- ci add: value validation and the existing-name refusal write nothing ---
CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/o/r":{"checks":{"tests":{"command":"echo old"}}}}}')
SNAPSHOT=$(cat "$CIHOME/ci.json")
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo github.com/o/r --name tests --command new 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: existing check name is refused (remove + add covers edits)"
assert_contains "$OUT" 'error: check "tests" already exists for github.com/o/r' \
  "add: refusal names the check and the repo key (own error: prefix)"
assert_contains "$OUT" "shai-config ci remove tests" "add: refusal names the remove + add path"
assert_eq "$(cat "$CIHOME/ci.json")" "$SNAPSHOT" "add: refusal leaves the file byte-identical"

OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo github.com/o/r --name t --command c --timeout 0 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: --timeout 0 → exit 1"
assert_contains "$OUT" 'error: --timeout must be a positive integer in seconds (got "0")' \
  "add: --timeout 0 → own error: prefix"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo github.com/o/r --name t --command c --timeout xyz 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: non-integer --timeout → exit 1"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo github.com/o/r --name t --command c --env noequals 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: --env without = → exit 1"
assert_contains "$OUT" "error: --env expects K=V" "add: bad --env → own error: prefix"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --repo github.com/o/r --name t --command c --env K=A --env K=B 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: duplicate --env key → exit 1"
assert_contains "$OUT" 'error: duplicate --env key "K"' "add: duplicate --env → own error: prefix"
assert_eq "$(cat "$CIHOME/ci.json")" "$SNAPSHOT" "add: every rejected value left the file byte-identical"

# --- ci add/remove: corrupt ci.json aborts with exit 1, byte-identical ---
# The byte-identical assertions were mutation-checked: replacing the
# parse-before-write branch with an unconditional fresh
# {"version":"1.0","repos":{}} lets add/remove rewrite the corrupt file and turns
# them red; the temp-file-litter assertions fail alongside (the temp file is only
# ever created on a write path).
CIHOME=$(ci_home 'not json {')
SNAPSHOT=$(cat "$CIHOME/ci.json")
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name tests --command ./tests/run.sh 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: corrupt ci.json → exit 1"
assert_contains "$OUT" "error:" "add: corrupt ci.json → own error: prefix"
assert_contains "$OUT" "shai-doctor" "add: corrupt ci.json → shai-doctor pointer"
assert_eq "$(cat "$CIHOME/ci.json")" "$SNAPSHOT" "add: corrupt ci.json left byte-identical (mutation-checked)"
assert_eq "$(ls -A "$CIHOME")" "ci.json" "add: corrupt abort leaves no temp file behind"

OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove tests 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: corrupt ci.json → exit 1"
assert_contains "$OUT" "error:" "remove: corrupt ci.json → own error: prefix"
assert_contains "$OUT" "shai-doctor" "remove: corrupt ci.json → shai-doctor pointer"
assert_eq "$(cat "$CIHOME/ci.json")" "$SNAPSHOT" "remove: corrupt ci.json left byte-identical (mutation-checked)"
assert_eq "$(ls -A "$CIHOME")" "ci.json" "remove: corrupt abort leaves no temp file behind"

# --- ci add/remove: an existing file's mode survives the atomic rewrite ---
CIHOME=$(ci_home '{"version":"1.0","repos":{}}')
chmod 644 "$CIHOME/ci.json"
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci add --name t --command c --repo github.com/o/r)
assert_eq "$(stat -c '%a' "$CIHOME/ci.json")" "644" "add: existing 0644 mode preserved across the rewrite"
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove t --repo github.com/o/r)
assert_eq "$(stat -c '%a' "$CIHOME/ci.json")" "644" "remove: existing 0644 mode preserved across the rewrite"

# --- ci list: human rows and --json for the resolved repo key ---
CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/o/r":{"checks":{"tests":{"command":"./tests/run.sh","timeout":900},"lint":{"command":"make lint"}}}}}')
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci list --repo https://github.com/o/r.git) && rc=0 || rc=$?
assert_eq "$rc" "0" "list --repo: exits 0"
assert_contains "$OUT" "repo: github.com/o/r  (normalized from --repo)" \
  "list --repo: normalized key line with provenance"
assert_contains "$OUT" "  tests: ./tests/run.sh" "list: first check row"
assert_contains "$OUT" "  lint: make lint" "list: second check row"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci list --repo github.com/o/r --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.repo')" "github.com/o/r" "list --json: repo key"
assert_eq "$(printf '%s' "$OUT" | jq -r '.file')" "$CIHOME/ci.json" "list --json: file"
assert_eq "$(printf '%s' "$OUT" | jq -r '.checks.tests.command')" "./tests/run.sh" "list --json: check command preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.checks.tests.timeout')" "900" "list --json: timeout preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.checks | length')" "2" "list --json: both checks"

# --- ci list/remove: an absent repo key names the resolved key (exit 1) ---
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci list 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "list: repo key absent from the file → exit 1"
assert_contains "$OUT" 'error: repository "github.com/ChristopherBilg/shai" not found in' \
  "list: absent key names the resolved key (own error: prefix)"
assert_contains "$OUT" "$CIHOME/ci.json" "list: absent key names the file"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove tests 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: repo key absent → exit 1"
assert_contains "$OUT" 'error: repository "github.com/ChristopherBilg/shai" not found in' \
  "remove: absent key names the resolved key (own error: prefix)"
assert_eq "$(jq -r '.repos | keys | length' "$CIHOME/ci.json")" "1" "remove: absent key wrote nothing"

# --- ci list/remove: no ci.json at all (the ci tool's wording) ---
CIHOME=$(empty_ci_home)
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci list 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "list: no ci.json → exit 1"
assert_contains "$OUT" "error: no CI config found at" "list: missing file → own error: prefix (the ci tool's wording)"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove tests 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: no ci.json → exit 1"
assert_contains "$OUT" "error: no CI config found at" "remove: missing file → own error: prefix"

# --- no git remote and no --repo → exit 1 naming both fixes ---
OUT=$(cd "$NODIR" && SHAI_HOME="$CIHOME" "$CFG" ci add --name t --command c 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "add: not in a git repo and no --repo → exit 1"
assert_contains "$OUT" "error: not in a git repository or no 'origin' remote" \
  "add: no remote → the ci tool's wording (own error: prefix)"
assert_contains "$OUT" "pass --repo KEY to target another repository, or add an 'origin' remote" \
  "add: no remote names both fixes"
assert_eq "$(test -f "$CIHOME/ci.json" && echo exists || echo absent)" "absent" "add: no remote wrote nothing"
OUT=$(cd "$NODIR" && SHAI_HOME="$CIHOME" "$CFG" ci list 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "list: no git remote and no --repo → exit 1"
assert_contains "$OUT" "error: not in a git repository or no 'origin' remote" "list: no remote → own error: prefix"

# --- ci remove: drops one check, never the repo entry ---
# The empty-checks and repo-entry-kept assertions were mutation-checked: changing the
# rewrite to `del(.repos[$key])` makes both red (checks: {} becomes null, the key
# vanishes), the positive controls beside them stay green.
CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/o/r":{"checks":{"tests":{"command":"echo a"},"lint":{"command":"echo b"}}}}}')
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove tests --repo github.com/o/r)
assert_contains "$OUT" "repo: github.com/o/r  (normalized from --repo)" "remove: prints the resolved key and provenance"
assert_contains "$OUT" 'removed check "tests"' "remove: reports the removed check"
assert_eq "$(jq -r '.repos["github.com/o/r"].checks | has("tests")' "$CIHOME/ci.json")" "false" \
  "remove: the named check is gone"
assert_eq "$(jq -r '.repos["github.com/o/r"].checks.lint.command' "$CIHOME/ci.json")" "echo b" \
  "remove: the other check is kept"
assert_eq "$(jq -r '.repos | keys | length' "$CIHOME/ci.json")" "1" "remove: the repo entry itself is never removed"
(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove lint --repo github.com/o/r)
assert_eq "$(jq -r '.repos["github.com/o/r"].checks | length' "$CIHOME/ci.json")" "0" \
  "remove: the last check leaves checks: {} (mutation-checked)"
assert_eq "$(jq -r '.repos | has("github.com/o/r")' "$CIHOME/ci.json")" "true" \
  "remove: the emptied repo entry stays (a valid state the ci tool reports as none configured)"
assert_eq "$(jq empty "$CIHOME/ci.json" >/dev/null 2>&1 && echo ok)" "ok" "remove: file still valid JSON"
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci list --repo github.com/o/r) && rc=0 || rc=$?
assert_eq "$rc" "0" "list: empty checks map exits 0 (a valid state)"
assert_contains "$OUT" "  (none configured)" "list: empty checks map reports (none configured)"

# --- ci remove: unknown check lists the available names (exit 1) ---
CIHOME=$(ci_home '{"version":"1.0","repos":{"github.com/o/r":{"checks":{"tests":{"command":"echo a"},"lint":{"command":"echo b"}}}}}')
OUT=$(cd "$REPO" && SHAI_HOME="$CIHOME" "$CFG" ci remove nope --repo github.com/o/r 2>&1) && rc=0 || rc=$?
assert_eq "$rc" "1" "remove: unknown check → exit 1"
assert_contains "$OUT" 'error: no check "nope" for github.com/o/r' \
  "remove: unknown check names the check and repo (own error: prefix)"
assert_contains "$OUT" "available checks:" "remove: unknown check lists the available names"
assert_contains "$OUT" "  tests" "remove: available names list tests"
assert_contains "$OUT" "  lint" "remove: available names list lint"
assert_eq "$(jq -r '.repos["github.com/o/r"].checks | length' "$CIHOME/ci.json")" "2" \
  "remove: unknown check wrote nothing"

# --- round-trip with the real tool: a check written here is found by tools/ci/run.sh ---
REPO_RT=$(git_repo "https://github.com/o/r.git")
CIHOME=$(empty_ci_home)
(cd "$REPO_RT" && SHAI_HOME="$CIHOME" "$CFG" ci add --name smoke --command 'echo ok')
OUT=$(cd "$REPO_RT" && SHAI_HOME="$CIHOME" "$DIR/tools/ci/run.sh" '{"action":"list"}')
assert_contains "$OUT" "smoke: echo ok" "round-trip: the ci tool lists the check shai-config wrote"
OUT=$(cd "$REPO_RT" && SHAI_HOME="$CIHOME" "$DIR/tools/ci/run.sh" '{"action":"run","check":"smoke"}') && rc=0 || rc=$?
assert_eq "$rc" "0" "round-trip: the ci tool runs the check shai-config wrote"
assert_contains "$OUT" "exit_code: 0" "round-trip: the run succeeded"
assert_contains "$OUT" "ok" "round-trip: the check output is visible"

finish
