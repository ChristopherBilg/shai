#!/bin/bash
# test_ci.sh — unit tests for tools/ci/run.sh
# Covers: tools/ci/run.sh — list/run actions, URL normalization, config lookup, cwd targeting,
#   timeout validation, environment isolation (SHAI_* and API-key scrubbing, per-check env map
#   with literal values and key validation), malformed config shapes, error paths, the shipped
#   ci.json.example
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools/ci/run.sh"

TOOL="$DIR/tools/ci/run.sh"

# The tool reports its own path via readlink -f (GNU) with a fallback to the invocation path
# (tools/ci/run.sh). Mirror that derivation here: on a checkout reached through a symlink the
# logical $DIR path and the canonical path differ, and comparing literally would fail the
# ci-tool assertions spuriously.
CI_TOOL_EXPECTED="$(readlink -f "$DIR/tools/ci/run.sh" 2>/dev/null || true)"
[ -n "$CI_TOOL_EXPECTED" ] || CI_TOOL_EXPECTED="$DIR/tools/ci/run.sh"

# --- setup: temp SHAI_HOME with ci.json ---
SHAI_HOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_HOME")
export SHAI_HOME

make_stub_bin

# Helper: write a git stub that returns a specific remote URL
write_remote_stub() {
  local url="$1"
  cat >"$STUB/git" <<STUBEOF
#!/bin/bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ]; then
  echo "$url"
  exit 0
fi
echo "stub git: \$*"
STUBEOF
  chmod +x "$STUB/git"
}

# Helper: write ci.json
write_ci_config() {
  cat >"$SHAI_HOME/ci.json"
}

# Helper: restore the shared multi-repo config used by most cases
write_default_config() {
  write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "test": { "command": "echo tests-passed" },
        "lint": { "command": "echo lint-ok" },
        "slow": { "command": "sleep 999", "timeout": 1 },
        "marker": { "command": "cat marker.txt" }
      }
    },
    "github.com/other/project": {
      "checks": {
        "build": { "command": "echo built" }
      }
    }
  }
}
JSON
}

write_default_config

# ===== list action =====
desc "list action"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}')
RC=$?
assert_eq "$RC" "0" "list: exit 0"
# the first line names the run.sh that orchestrated the listing (issue #157)
assert_eq "${OUT%%$'\n'*}" "ci-tool: $CI_TOOL_EXPECTED" "list: ci-tool line is the first line"
assert_contains "$OUT" "test" "list: shows test check"
assert_contains "$OUT" "lint" "list: shows lint check"
assert_contains "$OUT" "slow" "list: shows slow check"

# ===== run action (success) =====
desc "run action — passing check"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"test"}')
RC=$?
assert_eq "$RC" "0" "run success: exit 0"
assert_contains "$OUT" "tests-passed" "run success: command output present"
assert_contains "$OUT" "exit_code: 0" "run success: exit_code 0 reported"
# ci-tool must lead the output: the agent needs to see which run.sh orchestrated the run
# (issue #157), and exit_code right behind it stays inside the dispatch truncation head window.
assert_eq "${OUT%%$'\n'*}" "ci-tool: $CI_TOOL_EXPECTED" "run success: ci-tool line is the first line"
assert_eq "$(printf '%s\n' "$OUT" | sed -n '2p')" "exit_code: 0" "run success: exit_code is the second line"

# ===== run action (command fails) =====
desc "run action — failing check"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "fail": { "command": "echo failure-output; exit 1" }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"fail"}')
RC=$?
assert_eq "$RC" "0" "run fail: tool exits 0 (not is_error)"
assert_contains "$OUT" "failure-output" "run fail: command output present"
assert_contains "$OUT" "exit_code: 1" "run fail: exit_code 1 reported"
assert_eq "${OUT%%$'\n'*}" "ci-tool: $CI_TOOL_EXPECTED" "run fail: ci-tool line is the first line"
assert_eq "$(printf '%s\n' "$OUT" | sed -n '2p')" "exit_code: 1" "run fail: exit_code is the second line"

# ===== a check that exits 124 on its own is not a timeout =====
desc "run action — command exits 124"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "quick124": { "command": "echo fast-124; exit 124", "timeout": 30 }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"quick124"}')
RC=$?
assert_eq "$RC" "0" "exit 124: tool exits 0 (not reported as timeout)"
assert_contains "$OUT" "exit_code: 124" "exit 124: exit_code 124 reported"
if [[ "$OUT" == *"timed out"* ]]; then
  echo -e "  ${RED}✗${NC} exit 124: must not be reported as a timeout"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} exit 124: not reported as a timeout"
fi

write_default_config

# ===== run action (timeout) =====
desc "run action — timeout"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"slow"}' 2>&1) || true
assert_contains "$OUT" "timed out" "run timeout: error message"
assert_exit 1 "run timeout: exit 1" -- "$TOOL" '{"action":"run","check":"slow"}'

# ===== invalid timeout values =====
desc "invalid timeout values"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "bad": { "command": "echo hi", "timeout": "soon" },
        "zero": { "command": "echo hi", "timeout": 0 },
        "fractional": { "command": "echo hi", "timeout": 1.5 }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"bad"}' 2>&1) || true
assert_contains "$OUT" "invalid timeout" "timeout non-numeric: error message"
assert_exit 1 "timeout non-numeric: exit 1" -- "$TOOL" '{"action":"run","check":"bad"}'
OUT=$("$TOOL" '{"action":"run","check":"zero"}' 2>&1) || true
assert_contains "$OUT" "invalid timeout" "timeout 0: rejected instead of disabling the limit"
assert_exit 1 "timeout 0: exit 1" -- "$TOOL" '{"action":"run","check":"zero"}'
assert_exit 1 "timeout fractional: exit 1" -- "$TOOL" '{"action":"run","check":"fractional"}'

# ===== repo entry without a checks object =====
desc "repo entry without a valid checks object"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": { "command": "echo oops" },
    "github.com/owner/strchecks": { "checks": "not-an-object" },
    "github.com/owner/badcheck": { "checks": { "test": "echo oops" } }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "checks" "missing checks: mentions the checks key"
assert_exit 1 "missing checks: exit 1 (list)" -- "$TOOL" '{"action":"list"}'
assert_exit 1 "missing checks: exit 1 (run)" -- "$TOOL" '{"action":"run","check":"test"}'

write_remote_stub "https://github.com/owner/strchecks.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "checks" "non-object checks: mentions the checks key"
assert_exit 1 "non-object checks: exit 1" -- "$TOOL" '{"action":"list"}'

write_remote_stub "https://github.com/owner/badcheck.git"
OUT=$("$TOOL" '{"action":"run","check":"test"}' 2>&1) || true
assert_contains "$OUT" "command" "non-object check entry: mentions the command key"
assert_exit 1 "non-object check entry: exit 1" -- "$TOOL" '{"action":"run","check":"test"}'

write_default_config

# ===== missing ci.json =====
desc "missing ci.json"
rm "$SHAI_HOME/ci.json"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "ci.json" "missing config: mentions ci.json"
assert_exit 1 "missing config: exit 1" -- "$TOOL" '{"action":"list"}'

# ===== malformed ci.json =====
desc "malformed ci.json"
write_ci_config <<'JSON'
{ "version": "1.0", "repos": { this is not valid json
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "not valid JSON" "malformed config: mentions not valid JSON"
assert_exit 1 "malformed config: exit 1" -- "$TOOL" '{"action":"list"}'

write_default_config

# ===== unknown repo =====
desc "unknown repo"
write_remote_stub "https://github.com/unknown/thing.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "github.com/unknown/thing" "unknown repo: shows detected URL"
assert_exit 1 "unknown repo: exit 1" -- "$TOOL" '{"action":"list"}'

# ===== unknown check =====
desc "unknown check"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"nonexistent"}' 2>&1) || true
assert_contains "$OUT" "nonexistent" "unknown check: mentions requested check"
assert_contains "$OUT" "test" "unknown check: lists available checks"
assert_exit 1 "unknown check: exit 1" -- "$TOOL" '{"action":"run","check":"nonexistent"}'

# ===== missing check param =====
desc "missing check param"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run"}' 2>&1) || true
assert_contains "$OUT" "check" "missing check: mentions check param"
assert_exit 1 "missing check: exit 1" -- "$TOOL" '{"action":"run"}'

# ===== invalid action =====
desc "invalid action"
OUT=$("$TOOL" '{"action":"bogus"}' 2>&1) || true
assert_contains "$OUT" "list" "invalid action: mentions valid actions"
assert_exit 1 "invalid action: exit 1" -- "$TOOL" '{"action":"bogus"}'

# ===== cwd input =====
desc "cwd input"
CLONE="$(mktemp -d)"
_CLEANUP_DIRS+=("$CLONE")
echo "inside-the-clone" >"$CLONE/marker.txt"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" "{\"action\":\"run\",\"check\":\"marker\",\"cwd\":\"$CLONE\"}")
RC=$?
assert_eq "$RC" "0" "cwd: exit 0"
assert_contains "$OUT" "inside-the-clone" "cwd: check command runs in the given directory"
assert_contains "$OUT" "exit_code: 0" "cwd: exit_code reported"

OUT=$("$TOOL" '{"action":"list","cwd":"/nonexistent-shai-ci-dir"}' 2>&1) || true
assert_contains "$OUT" "not a directory" "cwd: rejects a non-directory path"
assert_exit 1 "cwd: exit 1 on a non-directory path" -- \
  "$TOOL" '{"action":"list","cwd":"/nonexistent-shai-ci-dir"}'

# ===== tool_dir override =====
# An explicit tool_dir execs that directory's ci/run.sh in place of the installed one, so a
# checkout's own tool can orchestrate its checks when dogfooding a change to tools/ci/run.sh
# (issue #157). The override is agent-invoked only and must never be derived from repo content.
desc "tool_dir override"
TOOLDIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$TOOLDIR")
mkdir -p "$TOOLDIR/ci"
cat >"$TOOLDIR/ci/run.sh" <<EOF
#!/bin/bash
printf 'ci-tool: $TOOLDIR/ci/run.sh\n'
printf 'exit_code: 0\n'
printf 'checkout-tool-ran\n'
EOF
chmod +x "$TOOLDIR/ci/run.sh"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" "{\"action\":\"run\",\"check\":\"test\",\"tool_dir\":\"$TOOLDIR\"}")
RC=$?
assert_eq "$RC" "0" "tool_dir: exit 0"
assert_contains "$OUT" "checkout-tool-ran" "tool_dir: the checkout's run.sh orchestrated the run"
assert_contains "$OUT" "ci-tool: $TOOLDIR/ci/run.sh" "tool_dir: ci-tool line names the checkout's run.sh"

# tool_dir pointing at the repo's own tools dir must not loop (tool_dir stripped before exec)
OUT=$("$TOOL" "{\"action\":\"list\",\"tool_dir\":\"$DIR/tools\"}")
RC=$?
assert_eq "$RC" "0" "tool_dir self: exit 0"
assert_eq "${OUT%%$'\n'*}" "ci-tool: $CI_TOOL_EXPECTED" "tool_dir self: ci-tool line is the first line"
assert_contains "$OUT" "Available CI checks for github.com/owner/repo:" "tool_dir self: list still works"

# a nonexistent tool_dir is a clean config error, not a silent pass
OUT=$("$TOOL" '{"action":"list","tool_dir":"/nonexistent-shai-tools"}' 2>&1) || true
assert_contains "$OUT" "not a directory" "tool_dir: rejects a non-directory path"
assert_exit 1 "tool_dir: exit 1 on a non-directory path" -- \
  "$TOOL" '{"action":"list","tool_dir":"/nonexistent-shai-tools"}'

# a tool_dir without ci/run.sh is a clean config error naming the looked-for file
EMPTYDIR="$(mktemp -d)"
_CLEANUP_DIRS+=("$EMPTYDIR")
OUT=$("$TOOL" "{\"action\":\"list\",\"tool_dir\":\"$EMPTYDIR\"}" 2>&1) || true
assert_contains "$OUT" "ci/run.sh" "tool_dir: missing ci/run.sh named in the error"
assert_exit 1 "tool_dir: exit 1 when ci/run.sh missing" -- \
  "$TOOL" "{\"action\":\"list\",\"tool_dir\":\"$EMPTYDIR\"}"

# ===== environment isolation =====
# The agent's own environment must not leak into the check: a workflow run exports SHAI_*
# variables, which includes the API key SHAI_API_KEY, and shai's own test suite reads those
# same variables (issue #87).
# A check must observe the checkout under test, not the agent that dispatched the tool.
desc "environment isolation — agent SHAI_* vars and API keys are scrubbed"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "envprobe": {
          "command": "echo span=${SHAI_SPAN_ID:-unset} run=${SHAI_RUN_ID:-unset} session=${SHAI_SESSION_ID:-unset} key=${SHAI_API_KEY:-unset}"
        },
        "envhome": {
          "command": "echo home=${HOME:-unset} path=${PATH:-unset} lang=${LANG:-unset}"
        },
        "envmap": {
          "command": "echo key=${SHAI_API_KEY:-unset} span=${SHAI_SPAN_ID:-unset} injected=${MY_CHECK_VAR:-unset}",
          "env": { "SHAI_API_KEY": "injected-key", "MY_CHECK_VAR": "present" }
        }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"

OUT=$(SHAI_SPAN_ID=span_9 SHAI_RUN_ID=run_9 SHAI_SESSION_ID=sess_9 \
  SHAI_API_KEY=agent-secret \
  "$TOOL" '{"action":"run","check":"envprobe"}' 2>&1)
RC=$?
assert_eq "$RC" "0" "env isolation: exit 0"
assert_contains "$OUT" "span=unset" "env isolation: SHAI_SPAN_ID scrubbed"
assert_contains "$OUT" "run=unset" "env isolation: SHAI_RUN_ID scrubbed"
assert_contains "$OUT" "session=unset" "env isolation: SHAI_SESSION_ID scrubbed"
assert_contains "$OUT" "key=unset" "env isolation: SHAI_API_KEY scrubbed"
if [[ "$OUT" == *"span_9"* || "$OUT" == *"run_9"* || "$OUT" == *"sess_9"* ||
  "$OUT" == *"agent-secret"* ]]; then
  echo -e "  ${RED}✗${NC} env isolation: agent values leaked into the check output"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} env isolation: agent values absent from check output"
fi

# PATH/HOME/LANG survive: env -i would break a check that needs a working shell
OUT=$("$TOOL" '{"action":"run","check":"envhome"}' 2>&1)
RC=$?
assert_eq "$RC" "0" "env isolation: PATH/HOME/LANG survive — exit 0"
assert_contains "$OUT" "home=$HOME" "env isolation: HOME survives"
assert_contains "$OUT" "lang=$LANG" "env isolation: LANG survives"
if [[ "$OUT" == *"path=unset"* || "$OUT" == *"home=unset"* || "$OUT" == *"lang=unset"* ]]; then
  echo -e "  ${RED}✗${NC} env isolation: PATH/HOME/LANG must survive (env -i is the wrong instrument)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} env isolation: PATH/HOME/LANG not unset"
fi

# a per-check "env" map re-injects a scrubbed variable and adds a new one
OUT=$(SHAI_API_KEY=agent-secret SHAI_SPAN_ID=span_9 \
  "$TOOL" '{"action":"run","check":"envmap"}' 2>&1)
RC=$?
assert_eq "$RC" "0" "env isolation: env map — exit 0"
assert_contains "$OUT" "key=injected-key" "env isolation: env map re-injects SHAI_API_KEY"
assert_contains "$OUT" "span=unset" "env isolation: env map does not un-scrub SHAI_*"
assert_contains "$OUT" "injected=present" "env isolation: env map adds a new variable"

# an "env" that is not an object is a config error, not a silent pass
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "badenv": { "command": "echo hi", "env": "not-an-object" }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"badenv"}' 2>&1) || true
assert_contains "$OUT" "invalid \"env\"" "env isolation: non-object env rejected"
assert_exit 1 "env isolation: non-object env exit 1" -- "$TOOL" '{"action":"run","check":"badenv"}'

# env-map values are passed literally: jq @tsv escapes tabs/newlines/backslashes and read
# takes those escapes literally, silently corrupting the value (review #156). A tab, a
# newline, a backslash, and an '=' inside a value must all survive byte-for-byte.
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "envliteral": {
          "command": "printf 'tab=<%s> nl=<%s> eq=<%s> empty=<%s>' \"$LITERAL_TAB\" \"$LITERAL_NL\" \"$LITERAL_EQ\" \"${LITERAL_EMPTY-unset}\"",
          "env": {
            "LITERAL_TAB": "a\tb\\c",
            "LITERAL_NL": "line1\nline2",
            "LITERAL_EQ": "x=y=z",
            "LITERAL_EMPTY": ""
          }
        }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"envliteral"}' 2>&1)
RC=$?
assert_eq "$RC" "0" "env literal: exit 0"
assert_contains "$OUT" $'tab=<a\tb\\c>' "env literal: tab and backslash in value passed literally"
assert_contains "$OUT" $'nl=<line1\nline2>' "env literal: newline in value passed literally"
assert_contains "$OUT" "eq=<x=y=z>" "env literal: '=' in value preserved"
assert_contains "$OUT" "empty=<>" "env literal: empty value passed through as set, not dropped"

# an invalid env-map key is a clean config error, not a confusing env(1) failure (review #156)
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "badkey": { "command": "echo hi", "env": { "FOO BAR": "x", "1BAD": "y", "": "z" } }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"badkey"}' 2>&1) || true
assert_contains "$OUT" "invalid \"env\" key" "env key validation: bogus key rejected with config error"
assert_exit 1 "env key validation: bad key exit 1" -- "$TOOL" '{"action":"run","check":"badkey"}'

write_default_config

# ===== URL normalization =====
desc "URL normalization"

# assert_normalizes <remote url> <label>: the remote must resolve to github.com/owner/repo
assert_normalizes() {
  local url="$1" label="$2" out rc
  write_remote_stub "$url"
  out=$("$TOOL" '{"action":"list"}' 2>&1)
  rc=$?
  assert_eq "$rc" "0" "normalize: $label — exit 0"
  assert_contains "$out" "Available CI checks for github.com/owner/repo:" \
    "normalize: $label — resolves to github.com/owner/repo"
}

assert_normalizes "https://github.com/owner/repo.git" "HTTPS with .git"
assert_normalizes "https://github.com/owner/repo" "HTTPS without .git"
assert_normalizes "git@github.com:owner/repo.git" "SSH with .git"
assert_normalizes "git@github.com:owner/repo" "SSH without .git"
assert_normalizes "ssh://git@github.com/owner/repo.git" "SSH with ssh:// prefix"
assert_normalizes "https://github.com/owner/repo/" "trailing slash"
assert_normalizes "https://github.com/owner/repo.git/" "trailing slash after .git"
assert_normalizes "https://user:s3cr3t@github.com/owner/repo.git" "embedded credentials"

# credentials must not leak into the lookup key that gets echoed back
write_remote_stub "https://user:s3cr3t@github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
if [[ "$OUT" == *"s3cr3t"* ]]; then
  echo -e "  ${RED}✗${NC} normalize: credentials stripped from the lookup key"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} normalize: credentials stripped from the lookup key"
fi

# ===== no git remote =====
desc "no git remote"
cat >"$STUB/git" <<'STUBEOF'
#!/bin/bash
echo "fatal: not a git repository" >&2
exit 128
STUBEOF
chmod +x "$STUB/git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "not in a git repository" "no remote: error message"
assert_exit 1 "no remote: exit 1" -- "$TOOL" '{"action":"list"}'

# ===== the shipped ci.json.example is usable as-is =====
# A new install is meant to copy this one file and have the tool work on this repo, so the
# example must parse and cover shai's own remote — not just look plausible.
desc "shipped ci.json.example"
EXAMPLE="$DIR/ci.json.example"
assert_eq "$([ -f "$EXAMPLE" ] && echo y)" "y" "example: ci.json.example exists at the repo root"
assert_exit 0 "example: is valid JSON" -- jq empty "$EXAMPLE"
cp "$EXAMPLE" "$SHAI_HOME/ci.json"
write_remote_stub "git@github.com:ChristopherBilg/shai.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "Available CI checks for github.com/ChristopherBilg/shai:" \
  "example: covers shai's own remote"
assert_contains "$OUT" "tests: ./tests/run.sh" "example: wires the test suite as a check"
assert_contains "$OUT" "conventions:" "example: wires the conventions check"
assert_contains "$OUT" "docs:" "example: wires the docs check"
# Every check must carry a runnable command, or `run` would fail on it.
assert_exit 0 "example: every check has a non-empty command string" -- jq -e '
  .repos | to_entries | length > 0 and all(.[];
    .value.checks | to_entries | length > 0 and all(.[];
      (.value.command | type == "string" and length > 0)
      and ((.value.timeout // 1) | type == "number" and . > 0 and floor == .)))
' "$EXAMPLE"
# The all aggregate must cover lint: a green all means lint ran. Without this, a future
# edit dropping "&& ./tests/lint.sh" from the all command would silently re-introduce
# the exact false green the example exists to prevent.
assert_exit 0 "example: all check command covers lint" -- jq -e '
  .repos | to_entries | length > 0 and all(.[];
    .value.checks | to_entries | any(.[];
      .key == "all" and (.value.command | contains("./tests/lint.sh"))))
' "$EXAMPLE"

finish
