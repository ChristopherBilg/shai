#!/bin/bash
# test_doctor.sh — unit tests for shai-doctor
# Covers: shai-doctor — CLI tool detection, env var checks, tool-declared config files,
#   output format, exit codes
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-doctor"

# Helper: run shai-doctor in a subshell with a controlled command-v override.
# Usage: run_doctor [FAIL_TOOLS...] — tools listed here will appear missing.
run_doctor() {
  local fail_list=("$@")
  (
    # Override the 'command' builtin so check_tool's `command -v` is controlled.
    # shellcheck disable=SC2317  # invoked from inside the dynamically-sourced shai-doctor, not visible to static analysis
    command() {
      if [ "$1" = "-v" ]; then
        local t
        for t in "${fail_list[@]}"; do
          if [ "$2" = "$t" ]; then return 1; fi
        done
        # Every tool not explicitly failed is reported present — never fall through to the
        # real builtin here, or the host's actual tool availability (e.g. no systemd on
        # macOS / minimal CI containers) would leak into the test and break exact counts.
        return 0
      else
        builtin command "$@"
      fi
    }
    export -f command 2>/dev/null || true
    source "$DIR/shai-doctor" 2>&1
  )
}

# The doctor's behavior probe (Test 12's subject) shells out to run.sh, which wraps grep in
# `timeout 30s`. run_doctor's command-override makes `command -v timeout` always succeed, so the
# probe runs in every test — and it must not depend on the host's real `timeout` (absent on stock
# macOS), or the exact-count assertions in Tests 6 and 9 would pick up a spurious probe WARN.
# Stub `timeout` as a passthrough so the probe's shell-out is deterministic on every host; grep
# stays real, since ERE alternation works on every platform.
make_stub_bin
cat >"$STUB/timeout" <<'EOF'
#!/bin/bash
# passthrough: drop the duration argument and exec the wrapped command — the probe's 30s cap is
# not under test
shift
exec "$@"
EOF
chmod +x "$STUB/timeout"

# shai-doctor also checks the config files tools declare via capabilities.requires.files
# (today: the ci tool's $SHAI_HOME/ci.json), so pin SHAI_HOME to a fixture holding a valid
# config — otherwise the host's real ~/.shai would leak into the exact warning counts below.
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
# shellcheck disable=SC2031  # shellcheck follows run_doctor's `source "$DIR/shai-doctor"` into
#                           # lib/workflow.sh, whose wf_init assigns SHAI_HOME, and flags this
#                           # assignment as clobbered by the subshell. The doctor only reads
#                           # SHAI_HOME; the subshell env isolation is intentional (see above).
export SHAI_HOME="$FIX/home"
mkdir -p "$SHAI_HOME"
cat >"$SHAI_HOME/ci.json" <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": { "checks": { "test": { "command": "true" } } }
  }
}
JSON

# --- Test 1: all checks pass ---
export DEEPSEEK_API_KEY="test-key"
export JIRA_API_TOKEN="test-token"

OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: all pass → exit 0"
assert_contains "$OUT" "[OK]" "doctor: at least one OK in output"
if [[ "$OUT" == *"[FAIL]"* ]]; then
  echo -e "  ${RED}✗${NC} doctor: no FAIL markers when all present"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} doctor: no FAIL markers when all present"
fi

# --- Test 2: core tool missing (jq) → exit 1 + FAIL ---
OUT=$(run_doctor jq)
RC=$?
assert_eq "$RC" "1" "doctor: missing core tool → exit 1"
assert_contains "$OUT" "[FAIL]" "doctor: missing jq shows FAIL"
assert_contains "$OUT" "jq" "doctor: FAIL line names jq"
assert_contains "$OUT" "policy validation skipped" "doctor: policy section skipped when jq is missing"

# --- Test 3: conditional tool missing (gh) → exit 0 + WARN ---
OUT=$(run_doctor gh)
RC=$?
assert_eq "$RC" "0" "doctor: missing conditional tool → exit 0"
assert_contains "$OUT" "[WARN]" "doctor: missing gh shows WARN"

# --- Test 4: core env var missing (DEEPSEEK_API_KEY) → exit 1 + FAIL ---
(
  unset DEEPSEEK_API_KEY
  OUT=$(run_doctor)
  RC=$?
  assert_eq "$RC" "1" "doctor: missing DEEPSEEK_API_KEY → exit 1"
  assert_contains "$OUT" "[FAIL]" "doctor: missing API key shows FAIL"
  assert_contains "$OUT" "DEEPSEEK_API_KEY" "doctor: FAIL line names the var"
  exit "$FAILED"
) || FAILED=1

# --- Test 5: conditional env var missing (JIRA_API_TOKEN) → exit 0 + WARN ---
(
  unset JIRA_API_TOKEN
  OUT=$(run_doctor)
  RC=$?
  assert_eq "$RC" "0" "doctor: missing JIRA var → exit 0"
  assert_contains "$OUT" "[WARN]" "doctor: missing JIRA var shows WARN"
  assert_contains "$OUT" "JIRA_API_TOKEN" "doctor: WARN line names the var"
  exit "$FAILED"
) || FAILED=1

# --- Test 6: summary line accuracy ---
(
  unset JIRA_API_TOKEN
  # 'od' (not 'jq') stands in for the failing core tool here: jq gates the tool.json
  # dependency scan below, so failing jq would also suppress the gh/JIRA checks this
  # test relies on (see Test 7 for that scenario).
  # Warning count: gh (1) + the unset JIRA_API_TOKEN (1) = 2.
  OUT=$(run_doctor od gh)
  SUMMARY=$(printf '%s' "$OUT" | tail -n1)
  assert_eq "$SUMMARY" "1 error, 2 warnings" "doctor: summary line exact match"
  exit "$FAILED"
) || FAILED=1

# --- Test 7: jq missing → tool.json dependency scan skipped gracefully ---
(
  OUT=$(run_doctor jq)
  RC=$?
  assert_eq "$RC" "1" "doctor: missing jq → exit 1 from the core-tool FAIL alone"
  assert_contains "$OUT" "[FAIL]" "doctor: missing jq still reported as FAIL"
  if [[ "$OUT" == *"Tool-declared dependencies:"* ]]; then
    echo -e "  ${RED}✗${NC} doctor: missing jq skips the Tool-declared dependencies section (section still shown)"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} doctor: missing jq skips the Tool-declared dependencies section"
  fi
  exit "$FAILED"
) || FAILED=1

# --- Test 8: tool-declared config file present and valid → OK + covered repo keys ---
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: valid ci.json → exit 0"
assert_contains "$OUT" "Tool-declared files:" "doctor: prints the Tool-declared files section"
assert_contains "$OUT" '[OK]   $SHAI_HOME/ci.json' "doctor: valid ci.json reported OK"
assert_contains "$OUT" "$SHAI_HOME/ci.json" "doctor: resolves the declared path"
assert_contains "$OUT" "repos: github.com/owner/repo" "doctor: lists the covered repo keys"

# Tests 9-11 vary $SHAI_HOME rather than the environment, so they reassign the already-exported
# variable in place instead of wrapping in a subshell like tests 4-7 (an exported assignment
# inside a subshell only trips SC2030/SC2031 for no benefit). SHAI_HOME is restored at the end.

# --- Test 9: config file missing → WARN (degraded, not fatal) with a fix hint ---
SHAI_HOME="$FIX/empty"
mkdir -p "$SHAI_HOME"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: missing ci.json → exit 0 (degraded, not fatal)"
assert_contains "$OUT" '[WARN] $SHAI_HOME/ci.json' "doctor: missing ci.json shows WARN"
assert_contains "$OUT" "not found: $SHAI_HOME/ci.json" "doctor: names the resolved path"
assert_contains "$OUT" "ci.json.example" "doctor: missing ci.json points at the example file"
SUMMARY=$(printf '%s' "$OUT" | tail -n1)
assert_eq "$SUMMARY" "0 errors, 1 warning" "doctor: missing ci.json is the only warning"

# --- Test 10: config file present but malformed → WARN naming the parse failure ---
SHAI_HOME="$FIX/broken"
mkdir -p "$SHAI_HOME"
printf '{ "repos": { this is not valid json\n' >"$SHAI_HOME/ci.json"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: malformed ci.json → exit 0"
assert_contains "$OUT" '[WARN] $SHAI_HOME/ci.json' "doctor: malformed ci.json shows WARN"
assert_contains "$OUT" "not valid JSON" "doctor: malformed ci.json names the parse failure"

# --- Test 11: config file present but covering no repos ---
SHAI_HOME="$FIX/norepos"
mkdir -p "$SHAI_HOME"
printf '{ "version": "1.0", "repos": {} }\n' >"$SHAI_HOME/ci.json"
OUT=$(run_doctor)
assert_contains "$OUT" '[OK]   $SHAI_HOME/ci.json' "doctor: empty repos map still parses → OK"
assert_contains "$OUT" "no repos entries" "doctor: reports an empty repos map"

SHAI_HOME="$FIX/home"

# --- Test 12: stale search_files (no -E) surfaces as a WARN, never a silent pass (#246) ---
# The #136 -E fix makes `foo|bar` mean alternation; a stale install predating it silently
# searches for a literal pipe and returns zero matches for every alternation. shai-doctor
# probes the local run.sh with an alternation pattern on a two-file fixture and warns when
# both alternatives do not match, so a stale/broken search_files is visible instead of
# silently producing empty search results.
# (the $STUB bin set up at the top of this file already holds the timeout passthrough stub)
cat >"$STUB/grep" <<'EOF'
#!/bin/bash
# stale pre-#136 behavior: no -E, so "alpha|beta" is searched for as a literal pipe → no match
exit 1
EOF
chmod +x "$STUB/grep"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: stale search_files → exit 0 (WARN, not fatal)"
assert_contains "$OUT" "Tool behavior self-checks:" "doctor: prints the behavior self-check section"
assert_contains "$OUT" "[WARN] search_files alternation" "doctor: stale search_files shows WARN"
assert_contains "$OUT" "literal pipe" "doctor: stale search_files names the literal-pipe misread"
SUMMARY=$(printf '%s' "$OUT" | tail -n1)
assert_eq "$SUMMARY" "0 errors, 1 warning" "doctor: stale search_files is the only warning"

rm -f "$STUB/grep"

# A git stub makes the SHAI_SUGGEST_REPO auto-detection (wf_suggest_repo, sourced from
# lib/workflow.sh) resolve deterministically instead of depending on this checkout's origin.
cat >"$STUB/git" <<'STUBEOF'
#!/bin/bash
# stub git: pretend the -C dir is the top of a work tree whose origin is a GitHub repo
cwd=""
if [ "$1" = "-C" ]; then cwd="$2"; shift 2; fi
case "$1" in
  rev-parse) echo "$cwd" ;;
  remote) echo "https://github.com/Owner/Custom-Repo.git" ;;
esac
STUBEOF
chmod +x "$STUB/git"

# --- Test 13: Configuration section shows defaults when vars are unset ---
(
  unset SHAI_MODEL SHAI_MAX_CONTEXT_BYTES SHAI_UNIT_DIR SHAI_SUGGEST SHAI_SUGGEST_REPO 2>/dev/null || true
  OUT=$(run_doctor)
  assert_contains "$OUT" "Configuration:" "doctor: prints the Configuration section"
  assert_contains "$OUT" "[OK]   SHAI_MODEL" "doctor: SHAI_MODEL listed"
  assert_contains "$OUT" "deepseek-v4-pro (default)" "doctor: SHAI_MODEL shows default value"
  assert_contains "$OUT" "1300000 (default)" "doctor: SHAI_MAX_CONTEXT_BYTES shows default value"
  assert_contains "$OUT" "1 (default)" "doctor: SHAI_SUGGEST shows default value"
  assert_contains "$OUT" "(unset — auto-detected: Owner/Custom-Repo)" "doctor: SHAI_SUGGEST_REPO shows the auto-detected repo"
  exit "$FAILED"
) || FAILED=1
rm -f "$STUB/git"

# --- Test 14: Configuration section shows explicit values (no "(default)" tag) ---
(
  export SHAI_MODEL="custom-model"
  # Must be a value unique to the Configuration section — "owner/repo" would also match the
  # ci.json fixture's "repos: github.com/owner/repo" line in the Tool-declared files section.
  export SHAI_SUGGEST_REPO="Owner/Custom-Repo"
  OUT=$(run_doctor)
  assert_contains "$OUT" "custom-model" "doctor: explicit SHAI_MODEL shown"
  if [[ "$OUT" == *"custom-model (default)"* ]]; then
    echo -e "  ${RED}✗${NC} doctor: explicit SHAI_MODEL must not show (default)"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} doctor: explicit SHAI_MODEL does not show (default)"
  fi
  assert_contains "$OUT" "Owner/Custom-Repo" "doctor: explicit SHAI_SUGGEST_REPO shown"
  exit "$FAILED"
) || FAILED=1

# --- Test 15: SHAI_HOME shows the explicit value (test fixture sets it) ---
OUT=$(run_doctor)
assert_contains "$OUT" "[OK]   SHAI_HOME" "doctor: SHAI_HOME listed"
assert_contains "$OUT" "$SHAI_HOME" "doctor: SHAI_HOME shows the explicit path"
if [[ "$OUT" == *"$SHAI_HOME (default)"* ]]; then
  echo -e "  ${RED}✗${NC} doctor: explicit SHAI_HOME must not show (default)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} doctor: explicit SHAI_HOME does not show (default)"
fi

# --- Test 16: Configuration section never affects error/warning counts ---
(
  unset SHAI_MODEL SHAI_SUGGEST_REPO 2>/dev/null || true
  OUT=$(run_doctor)
  SUMMARY=$(printf '%s' "$OUT" | tail -n1)
  assert_eq "$SUMMARY" "0 errors, 0 warnings" "doctor: config section adds no errors or warnings"
  exit "$FAILED"
) || FAILED=1

# --- Test 17: valid policy.json → OK with rule count and default ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": [
    {"tool": "write_file", "action": "allow"},
    {"tool": "delete_file", "action": "deny"}
  ],
  "default": "prompt"
}
JSON
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: valid policy.json → exit 0"
assert_contains "$OUT" "Policy files:" "doctor: prints the Policy files section"
assert_contains "$OUT" '[OK]   $SHAI_HOME/policy.json' "doctor: valid policy.json reported OK"
assert_contains "$OUT" "2 rules, default: prompt" "doctor: shows rule count and default"
rm -f "$SHAI_HOME/policy.json"

# --- Test 18: valid policy.json with no default → shows "no default" ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": [
    {"tool": "gh", "action": "allow"}
  ]
}
JSON
OUT=$(run_doctor)
assert_contains "$OUT" "1 rule, no default" "doctor: shows singular rule count and no default"
rm -f "$SHAI_HOME/policy.json"

# --- Test 19: malformed policy.json → WARN ---
printf '{ "rules": [ this is not valid json\n' >"$SHAI_HOME/policy.json"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: malformed policy.json → exit 0 (WARN, not fatal)"
assert_contains "$OUT" '[WARN] $SHAI_HOME/policy.json' "doctor: malformed policy.json shows WARN"
assert_contains "$OUT" "not valid JSON" "doctor: malformed policy.json names the parse failure"
rm -f "$SHAI_HOME/policy.json"

# --- Test 20: policy.json with bad schema — .rules not an array → WARN ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": "not-an-array"
}
JSON
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: bad schema → exit 0"
assert_contains "$OUT" '[WARN] $SHAI_HOME/policy.json' "doctor: .rules not array shows WARN"
assert_contains "$OUT" "rules" "doctor: names the rules field in the warning"
rm -f "$SHAI_HOME/policy.json"

# --- Test 21: policy.json with bad schema — rule missing .tool → WARN ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": [
    {"action": "allow"}
  ]
}
JSON
OUT=$(run_doctor)
assert_contains "$OUT" "[WARN]" "doctor: rule missing .tool shows WARN"
assert_contains "$OUT" "missing or invalid .tool" "doctor: names the missing field"
rm -f "$SHAI_HOME/policy.json"

# --- Test 22: policy.json with bad schema — invalid .action value → WARN ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": [
    {"tool": "gh", "action": "block"}
  ]
}
JSON
OUT=$(run_doctor)
assert_contains "$OUT" "[WARN]" "doctor: invalid action value shows WARN"
assert_contains "$OUT" "block" "doctor: names the invalid action"
rm -f "$SHAI_HOME/policy.json"

# --- Test 23: policy.json with bad .default value → WARN ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
{
  "rules": [],
  "default": "reject"
}
JSON
OUT=$(run_doctor)
assert_contains "$OUT" "[WARN]" "doctor: invalid default value shows WARN"
assert_contains "$OUT" "reject" "doctor: names the invalid default"
rm -f "$SHAI_HOME/policy.json"

# --- Test 24: missing policy.json → no error, no warning ---
# (policy.json is optional — a missing file is the expected state before a user creates one)
rm -f "$SHAI_HOME/policy.json"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: missing policy.json → exit 0"
SUMMARY=$(printf '%s' "$OUT" | tail -n1)
assert_eq "$SUMMARY" "0 errors, 0 warnings" "doctor: missing policy.json adds no warnings"

# --- Test 25: SHAI_POLICY_OVERLAY validation — valid overlay → OK ---
OVERLAY="$FIX/overlay-policy.json"
cat >"$OVERLAY" <<'JSON'
{
  "rules": [
    {"tool": "gh", "action": "allow", "args": {"command": "pr *"}}
  ]
}
JSON
(
  # shellcheck disable=SC2030  # export inside subshell is intentional — isolates the overlay var
  export SHAI_POLICY_OVERLAY="$OVERLAY"
  OUT=$(run_doctor)
  assert_contains "$OUT" "[OK]" "doctor: valid overlay reported OK"
  assert_contains "$OUT" "overlay-policy.json" "doctor: names the overlay file"
  assert_contains "$OUT" "1 rule, no default" "doctor: overlay shows rule count"
  exit "$FAILED"
) || FAILED=1
rm -f "$OVERLAY"

# --- Test 26: SHAI_POLICY_OVERLAY set but file missing → no error (not required to exist) ---
(
  # shellcheck disable=SC2031  # SHAI_POLICY_OVERLAY subshell isolation is intentional (see Test 25)
  export SHAI_POLICY_OVERLAY="$FIX/nonexistent-overlay.json"
  OUT=$(run_doctor)
  RC=$?
  assert_eq "$RC" "0" "doctor: missing overlay → exit 0"
  SUMMARY=$(printf '%s' "$OUT" | tail -n1)
  assert_eq "$SUMMARY" "0 errors, 0 warnings" "doctor: missing overlay adds no warnings"
  exit "$FAILED"
) || FAILED=1

# --- Test 27: policy.json valid JSON but top-level array → WARN, not silently empty ---
cat >"$SHAI_HOME/policy.json" <<'JSON'
[
  {"tool": "gh", "action": "allow"}
]
JSON
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: top-level array policy → exit 0 (WARN, not fatal)"
assert_contains "$OUT" '[WARN] $SHAI_HOME/policy.json' "doctor: top-level array policy shows WARN"
assert_contains "$OUT" "must be a JSON object" "doctor: warning names the object requirement"
rm -f "$SHAI_HOME/policy.json"

# --- Test 28: policy.json valid JSON but top-level scalar → WARN, not silently empty ---
printf '42\n' >"$SHAI_HOME/policy.json"
OUT=$(run_doctor)
RC=$?
assert_eq "$RC" "0" "doctor: top-level scalar policy → exit 0 (WARN, not fatal)"
assert_contains "$OUT" '[WARN] $SHAI_HOME/policy.json' "doctor: top-level scalar policy shows WARN"
assert_contains "$OUT" "must be a JSON object" "doctor: scalar policy warning names the object requirement"
rm -f "$SHAI_HOME/policy.json"

finish
