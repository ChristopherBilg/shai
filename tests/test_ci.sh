#!/bin/bash
# test_ci.sh — unit tests for tools/ci/run.sh
# Covers: tools/ci/run.sh — list/run actions, URL normalization, config lookup, cwd targeting,
#   timeout validation, malformed config shapes, error paths
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools/ci/run.sh"

TOOL="$DIR/tools/ci/run.sh"

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
# exit_code must lead the output: shai-dispatch truncates to the first 32000 bytes
assert_eq "${OUT%%$'\n'*}" "exit_code: 0" "run success: exit_code is the first line"

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
assert_eq "${OUT%%$'\n'*}" "exit_code: 1" "run fail: exit_code is the first line"

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

finish
